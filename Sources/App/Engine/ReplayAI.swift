import Foundation
import CoreVideo
import CoreMedia
import CoreImage
import VideoToolbox
import Metal
import QuartzCore

// MARK: - Replay: per-Mac capabilities, slow-motion smoothing and AI frame interpolation
//
// Every Apple Silicon generation differs: base M1 has no ProRes engine, and the ML frame-rate
// converter (VTFrameRateConversion) runs from ~20 ms/frame (M1 Max, 1080p, 3 phases per call)
// to real time on newer chips. Capabilities are detected/measured once per Mac + OS build, and the
// replay engine picks the best path:
//   • real-time AI interpolation during playback, when this Mac is fast enough,
//   • otherwise GPU frame blending live (≈0.5 ms) + AI-rendered clips in the background.

enum ReplayCaps {
    static let chip: String = {
        var size = 0
        sysctlbyname("machdep.cpu.brand_string", nil, &size, nil, 0)
        var buf = [CChar](repeating: 0, count: max(1, size))
        sysctlbyname("machdep.cpu.brand_string", &buf, &size, nil, 0)
        return String(cString: buf)
    }()

    /// Hardware ProRes encoder (M1 Pro/Max/Ultra, M2 and later). Without it VideoToolbox encodes
    /// ProRes on the CPU, which is not suitable for 4 cameras.
    static let proResHardware: Bool = {
        var list: CFArray?
        guard VTCopyVideoEncoderList(nil, &list) == noErr, let items = list as? [NSDictionary] else { return false }
        return items.contains { d in
            let name = (d[kVTVideoEncoderList_DisplayName] as? String ?? "").lowercased()
            let hw = (d[kVTVideoEncoderList_IsHardwareAccelerated] as? NSNumber)?.boolValue ?? false
            return hw && name.contains("prores")
        }
    }()

    static var aiSupported: Bool {
        if #available(macOS 15.4, *) { return VTFrameRateConversionConfiguration.isSupported }
        return false
    }

    private static func costKey(_ w: Int, _ h: Int) -> String {
        let os = ProcessInfo.processInfo.operatingSystemVersionString
        return "replayAICostMs|\(chip)|\(os)|\(w)x\(h)"
    }

    /// Measured cost of one AI-interpolated frame on this Mac (ms), or nil if not measured yet.
    static func aiCostMs(width: Int, height: Int) -> Double? {
        let v = UserDefaults.standard.double(forKey: costKey(width, height))
        return v > 0 ? v : nil
    }

    static func storeAICost(_ ms: Double, width: Int, height: Int) {
        UserDefaults.standard.set(ms, forKey: costKey(width, height))
    }

    /// Real time = one interpolation per program frame with room left for decoding and blending.
    static func aiRealtime(width: Int, height: Int, fps: Double) -> Bool {
        guard let c = aiCostMs(width: width, height: height) else { return false }
        return c < 1000 / max(1, fps) * 0.55
    }
}

/// GPU cross-fade between two frames (no colour management: exact video values, ≈0.5 ms at 1080p).
final class FrameBlender {
    private let ctx: CIContext = {
        let opts: [CIContextOption: Any] = [.workingColorSpace: NSNull(), .outputColorSpace: NSNull(), .cacheIntermediates: false]
        if let dev = MTLCreateSystemDefaultDevice() { return CIContext(mtlDevice: dev, options: opts) }
        return CIContext(options: opts)
    }()

    func blend(_ a: CVPixelBuffer, _ b: CVPixelBuffer, phase: Double, into dst: CVPixelBuffer) -> Bool {
        guard let f = CIFilter(name: "CIDissolveTransition") else { return false }
        f.setValue(CIImage(cvPixelBuffer: a), forKey: kCIInputImageKey)
        f.setValue(CIImage(cvPixelBuffer: b), forKey: kCIInputTargetImageKey)
        f.setValue(max(0, min(1, phase)), forKey: kCIInputTimeKey)
        guard let out = f.outputImage else { return false }
        ctx.render(out, to: dst)
        return true
    }
}

/// VideoToolbox ML frame-rate converter for BGRA frames of one size. Not thread-safe: one owner queue.
final class AIInterpolator {
    let width: Int, height: Int
    private let processor: AnyObject
    private let config: AnyObject
    private var halfPool: CVPixelBufferPool?
    private var outPool: CVPixelBufferPool?
    private var xfer: VTPixelTransferSession?
    private var tick: Int64 = 0

    /// Starting a session loads the ML model (≈10 s the first time on a Mac, then cached by macOS).
    /// Create it off the main and player threads.
    init?(width: Int, height: Int) {
        guard #available(macOS 15.4, *), VTFrameRateConversionConfiguration.isSupported,
              let cfg = VTFrameRateConversionConfiguration(frameWidth: width, frameHeight: height, usePrecomputedFlow: false,
                                                           qualityPrioritization: .normal, revision: .revision1),
              let fmt = cfg.supportedPixelFormats.first else { return nil }
        let p = VTFrameProcessor()
        do { try p.startSession(configuration: cfg) } catch { return nil }
        self.width = width; self.height = height
        processor = p; config = cfg
        func pool(_ base: [String: Any]) -> CVPixelBufferPool? {
            var a = base
            a[kCVPixelBufferPixelFormatTypeKey as String] = fmt
            a[kCVPixelBufferWidthKey as String] = width
            a[kCVPixelBufferHeightKey as String] = height
            a[kCVPixelBufferIOSurfacePropertiesKey as String] = [String: Any]()
            var pl: CVPixelBufferPool?
            CVPixelBufferPoolCreate(nil, [kCVPixelBufferPoolMinimumBufferCountKey as String: 5] as CFDictionary, a as CFDictionary, &pl)
            return pl
        }
        halfPool = pool(cfg.sourcePixelBufferAttributes)
        outPool = pool(cfg.destinationPixelBufferAttributes)
        var t: VTPixelTransferSession?
        VTPixelTransferSessionCreate(allocator: nil, pixelTransferSessionOut: &t)
        if let t = t { VTSessionSetProperty(t, key: kVTPixelTransferPropertyKey_RealTime, value: kCFBooleanTrue) }
        xfer = t
        guard halfPool != nil, outPool != nil, xfer != nil else { return nil }
    }

    deinit {
        if #available(macOS 15.4, *), let p = processor as? VTFrameProcessor { p.endSession() }
        if let t = xfer { VTPixelTransferSessionInvalidate(t) }
    }

    private func make(_ pool: CVPixelBufferPool?) -> CVPixelBuffer? {
        guard let pool = pool else { return nil }
        var pb: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(nil, pool, &pb)
        return pb
    }

    /// Frames between `a` (phase 0) and `b` (phase 1), written into BGRA buffers from `bgraPool`.
    func interpolate(_ a: CVPixelBuffer, _ b: CVPixelBuffer, phases: [Float], bgraPool: CVPixelBufferPool) -> [CVPixelBuffer]? {
        guard #available(macOS 15.4, *), let p = processor as? VTFrameProcessor, let xfer = xfer, !phases.isEmpty,
              let ha = make(halfPool), let hb = make(halfPool) else { return nil }
        guard VTPixelTransferSessionTransferImage(xfer, from: a, to: ha) == noErr,
              VTPixelTransferSessionTransferImage(xfer, from: b, to: hb) == noErr else { return nil }
        let outs = phases.compactMap { _ in make(outPool) }
        guard outs.count == phases.count else { return nil }
        tick += 1
        let base = tick * 8
        guard let fa = VTFrameProcessorFrame(buffer: ha, presentationTimeStamp: CMTime(value: base, timescale: 8000)),
              let fb = VTFrameProcessorFrame(buffer: hb, presentationTimeStamp: CMTime(value: base + 8, timescale: 8000)) else { return nil }
        let dst = outs.enumerated().compactMap { k, o in
            VTFrameProcessorFrame(buffer: o, presentationTimeStamp: CMTime(value: base + 1 + CMTimeValue(k), timescale: 8000))
        }
        guard dst.count == outs.count,
              let prm = VTFrameRateConversionParameters(sourceFrame: fa, nextFrame: fb, opticalFlow: nil, interpolationPhase: phases,
                                                        submissionMode: .random, destinationFrames: dst) else { return nil }
        let sem = DispatchSemaphore(value: 0)
        var failed = false
        p.process(parameters: prm) { _, err in failed = err != nil; sem.signal() }
        if sem.wait(timeout: .now() + 2) == .timedOut || failed { return nil }
        var result: [CVPixelBuffer] = []
        for o in outs {
            var pb: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(nil, bgraPool, &pb)
            guard let d = pb, VTPixelTransferSessionTransferImage(xfer, from: o, to: d) == noErr else { return nil }
            result.append(d)
        }
        return result
    }

    /// Times a few interpolations on synthetic frames and stores the per-frame cost for this Mac.
    @discardableResult
    func measure(bgraPool: CVPixelBufferPool) -> Double? {
        guard let a = PixelBufferFactory.makeBuffer(pool: bgraPool), let b = PixelBufferFactory.makeBuffer(pool: bgraPool) else { return nil }
        var times: [Double] = []
        for i in 0..<6 {
            let t = CACurrentMediaTime()
            guard interpolate(a, b, phases: [0.5], bgraPool: bgraPool) != nil else { return nil }
            if i > 0 { times.append((CACurrentMediaTime() - t) * 1000) }
        }
        let ms = times.sorted()[times.count / 2]
        ReplayCaps.storeAICost(ms, width: width, height: height)
        return ms
    }
}
