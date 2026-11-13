import Foundation
import CoreMedia
import CoreVideo
import VideoToolbox
import QuartzCore

/// Input Settings › Position › "AI upscaling": a low-resolution source (720p camera, SD capture, small
/// clip) is enlarged with Apple's real-time super-resolution model (VideoToolbox
/// `VTLowLatencySuperResolutionScaler`, Neural Engine / GPU, macOS 26+) before it is placed in the
/// output, instead of being stretched with plain linear filtering.
///
/// Like background removal, the render thread never waits: it hands over the newest source frame and
/// uses the newest finished result (one frame late at most while the model keeps up).
final class Upscaler {
    enum State: Equatable { case starting, running, notNeeded, unsupported, failed }

    private let queue = DispatchQueue(label: "hongmix.upscale", qos: .userInteractive)
    private let lock = NSLock()
    private var busy = false
    private var lastSrc: CVPixelBuffer?
    private var lastOut: CVPixelBuffer?
    /// source size `lastOut` was made from — a result from an older resolution is never shown
    private var lastOutSize = (0, 0)
    /// after a failure: no new attempt before this time (back-off 2 s, 4 s … 30 s), then retry
    private var retryAt: CFTimeInterval = 0
    private var failures = 0
    private var stateStore: State = .starting
    private var msStore: Double = 0
    private var factorStore: Float = 0
    private var sizeStore = (0, 0)

    // processing queue only
    private var processor: AnyObject?
    private var configKey = (0, 0, Float(0))
    private var srcPool: CVPixelBufferPool?
    private var dstPool: CVPixelBufferPool?
    private var bgraPool: CVPixelBufferPool?
    private var xfer: VTPixelTransferSession?
    private var runs = 0
    private var sessionRuns = 0   // frames done by the current model session (first ones load the model)
    private var tick: Int64 = 0

    static var isSupported: Bool {
        if #available(macOS 26.0, *) { return VTLowLatencySuperResolutionScalerConfiguration.isSupported }
        return false
    }

    var state: State { lock.lock(); defer { lock.unlock() }; return stateStore }
    /// Average processing time per frame (ms), after the model has loaded.
    var averageMs: Double { lock.lock(); defer { lock.unlock() }; return msStore }
    var factor: Float { lock.lock(); defer { lock.unlock() }; return factorStore }
    var sourceSize: (Int, Int) { lock.lock(); defer { lock.unlock() }; return sizeStore }

    deinit {
        if #available(macOS 26.0, *), let p = processor as? VTFrameProcessor { p.endSession() }
        if let t = xfer { VTPixelTransferSessionInvalidate(t) }
    }

    /// Render thread. Returns the newest upscaled frame (BGRA, opaque), or nil = use the source as is.
    /// `process` false: the input isn't on air — keep the model loaded but don't spend time on it.
    func frame(for src: CVPixelBuffer, outW: Int, outH: Int, process: Bool) -> CVPixelBuffer? {
        guard Self.isSupported else { setState(.unsupported); return nil }
        let w = CVPixelBufferGetWidth(src), h = CVPixelBufferGetHeight(src)
        let need = min(Float(outW) / Float(max(1, w)), Float(outH) / Float(max(1, h)))
        lock.lock(); defer { lock.unlock() }
        if sizeStore != (w, h) {
            // resolution changed: earlier verdicts (unsupported / failed) were about the old size
            sizeStore = (w, h)
            if stateStore == .unsupported || stateStore == .failed { stateStore = .starting }
            failures = 0; retryAt = 0
        }
        // already as large as the output (or nearly): nothing to gain
        if need < 1.15 { stateStore = .notNeeded; lastOut = nil; return nil }
        if stateStore == .unsupported { return nil }
        if stateStore == .notNeeded { stateStore = .starting }
        // off air: show the plain live source (input tiles, MultiView, buses) — never a frozen result
        guard process else { lastOut = nil; return nil }
        let waiting = stateStore == .failed && CACurrentMediaTime() < retryAt
        if !waiting, src !== lastSrc, !busy {
            busy = true
            lastSrc = src
            queue.async { [weak self] in self?.run(src, need: need) }
        }
        // a result from a different source size (resolution change) is never shown
        if stateStore != .failed, let o = lastOut, lastOutSize == (w, h) { return o }
        return nil
    }

    private func setState(_ s: State) { lock.lock(); stateStore = s; lock.unlock() }

    private func run(_ src: CVPixelBuffer, need: Float) {
        let t0 = CACurrentMediaTime()
        var out: CVPixelBuffer?
        var newState: State = .running
        if #available(macOS 26.0, *) {
            switch upscale(src, need: need) {
            case .success(let o): out = o
            case .failure(let e): newState = e.state
            }
        } else {
            newState = .unsupported
        }
        let ms = (CACurrentMediaTime() - t0) * 1000
        let w = CVPixelBufferGetWidth(src), h = CVPixelBufferGetHeight(src)
        lock.lock()
        busy = false
        if let out { lastOut = out; lastOutSize = (w, h) }
        if stateStore != .notNeeded { stateStore = newState }
        if out != nil {
            runs += 1
            failures = 0
            // the first runs include loading the model — not counted
            if runs > 3 { msStore = msStore == 0 ? ms : msStore * 0.9 + ms * 0.1 }
        } else if newState == .failed {
            // keep showing the plain source; try again later instead of giving up for good
            failures += 1
            lastOut = nil
            retryAt = CACurrentMediaTime() + min(30, 2 * pow(2, Double(min(failures - 1, 4))))
        }
        lock.unlock()
    }

    /// Completion flag shared with VideoToolbox's callback thread.
    private final class Done: @unchecked Sendable {
        private let l = NSLock(); private var v = false
        var failed: Bool { get { l.lock(); defer { l.unlock() }; return v } set { l.lock(); v = newValue; l.unlock() } }
    }

    @available(macOS 26.0, *)
    private func upscale(_ src: CVPixelBuffer, need: Float) -> Result<CVPixelBuffer, StateError> {
        let w = CVPixelBufferGetWidth(src), h = CVPixelBufferGetHeight(src)
        if configKey.0 != w || configKey.1 != h || processor == nil {
            switch setup(w, h, need: need) {
            case .ok: break
            case .unsupported: return .failure(StateError(state: .unsupported))
            case .failed: return .failure(StateError(state: .failed))
            }
        }
        guard let p = processor as? VTFrameProcessor, let xfer,
              let s = make(srcPool), let d = make(dstPool), let o = make(bgraPool) else { return .failure(StateError(state: .failed)) }
        // The model works in 420v; tag both YUV buffers BT.709 so every conversion uses the same matrix
        // (untagged buffers are read as BT.601 — greens and yellows shift).
        Self.tag709(s); Self.tag709(d)
        guard VTPixelTransferSessionTransferImage(xfer, from: src, to: s) == noErr else { return .failure(StateError(state: .failed)) }
        tick += 1
        let pts = CMTime(value: tick, timescale: 600)
        guard let fs = VTFrameProcessorFrame(buffer: s, presentationTimeStamp: pts),
              let fd = VTFrameProcessorFrame(buffer: d, presentationTimeStamp: pts) else { return .failure(StateError(state: .failed)) }
        let prm = VTLowLatencySuperResolutionScalerParameters(sourceFrame: fs, destinationFrame: fd)
        let sem = DispatchSemaphore(value: 0)
        let done = Done()
        p.process(parameters: prm) { _, err in done.failed = err != nil; sem.signal() }
        // the first frames also load the model — allow longer than a steady-state frame
        let limit: Double = sessionRuns < 3 ? 8 : 1
        if sem.wait(timeout: .now() + limit) == .timedOut {
            // the session may be stuck: start a fresh one on the next attempt
            p.endSession(); processor = nil
            return .failure(StateError(state: .failed))
        }
        if done.failed { return .failure(StateError(state: .failed)) }
        guard VTPixelTransferSessionTransferImage(xfer, from: d, to: o) == noErr else { return .failure(StateError(state: .failed)) }
        sessionRuns += 1
        return .success(o)
    }

    struct StateError: Error { let state: State }

    private enum SetupResult { case ok, unsupported, failed }

    @available(macOS 26.0, *)
    private func setup(_ w: Int, _ h: Int, need: Float) -> SetupResult {
        if let p = processor as? VTFrameProcessor { p.endSession() }
        processor = nil
        let factors = VTLowLatencySuperResolutionScalerConfiguration.supportedScaleFactors(frameWidth: w, frameHeight: h)
            .sorted()
        guard !factors.isEmpty else { return .unsupported }   // the model has no factor for this size
        // smallest factor that reaches the output size, else the largest available
        let f = factors.first { $0 >= need * 0.97 } ?? factors.last!
        let cfg = VTLowLatencySuperResolutionScalerConfiguration(frameWidth: w, frameHeight: h, scaleFactor: f)
        guard let fmt = cfg.supportedPixelFormats.first else { return .unsupported }
        let p = VTFrameProcessor()
        do { try p.startSession(configuration: cfg) } catch { return .failed }
        let dw = Int((Float(w) * f).rounded()), dh = Int((Float(h) * f).rounded())
        func pool(_ base: [String: Any], _ pw: Int, _ ph: Int, _ pf: OSType) -> CVPixelBufferPool? {
            var a = base
            a[kCVPixelBufferPixelFormatTypeKey as String] = pf
            a[kCVPixelBufferWidthKey as String] = pw
            a[kCVPixelBufferHeightKey as String] = ph
            a[kCVPixelBufferIOSurfacePropertiesKey as String] = [String: Any]()
            a[kCVPixelBufferMetalCompatibilityKey as String] = true
            var pl: CVPixelBufferPool?
            CVPixelBufferPoolCreate(nil, [kCVPixelBufferPoolMinimumBufferCountKey as String: 4] as CFDictionary, a as CFDictionary, &pl)
            return pl
        }
        srcPool = pool(cfg.sourcePixelBufferAttributes, w, h, fmt)
        dstPool = pool(cfg.destinationPixelBufferAttributes, dw, dh, fmt)
        bgraPool = pool([:], dw, dh, kCVPixelFormatType_32BGRA)
        if xfer == nil {
            var t: VTPixelTransferSession?
            VTPixelTransferSessionCreate(allocator: nil, pixelTransferSessionOut: &t)
            if let t { VTSessionSetProperty(t, key: kVTPixelTransferPropertyKey_RealTime, value: kCFBooleanTrue) }
            xfer = t
        }
        guard srcPool != nil, dstPool != nil, bgraPool != nil, xfer != nil else { p.endSession(); return .failed }
        processor = p
        sessionRuns = 0
        configKey = (w, h, f)
        lock.lock(); factorStore = f; lock.unlock()
        return .ok
    }

    private static func tag709(_ pb: CVPixelBuffer) {
        CVBufferSetAttachment(pb, kCVImageBufferYCbCrMatrixKey, kCVImageBufferYCbCrMatrix_ITU_R_709_2, .shouldPropagate)
        CVBufferSetAttachment(pb, kCVImageBufferColorPrimariesKey, kCVImageBufferColorPrimaries_ITU_R_709_2, .shouldPropagate)
        CVBufferSetAttachment(pb, kCVImageBufferTransferFunctionKey, kCVImageBufferTransferFunction_ITU_R_709_2, .shouldPropagate)
    }

    private func make(_ pool: CVPixelBufferPool?) -> CVPixelBuffer? {
        guard let pool else { return nil }
        var pb: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(nil, pool, &pb)
        return pb
    }
}
