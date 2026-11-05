import Foundation
import CoreVideo
import QuartzCore
import VideoToolbox
import CoreGraphics
import CoreText

/// Program/output video format.
struct VideoFormat: Codable, Hashable, Identifiable {
    var id: String
    var name: String
    var width: Int
    var height: Int
    var fpsNum: Int
    var fpsDen: Int

    var frameDuration: Double { Double(fpsDen) / Double(fpsNum) }
    var fps: Double { Double(fpsNum) / Double(fpsDen) }

    static let presets: [VideoFormat] = [
        VideoFormat(id: "1080p2997", name: "1080p 29.97", width: 1920, height: 1080, fpsNum: 30000, fpsDen: 1001),
        VideoFormat(id: "1080p30", name: "1080p 30", width: 1920, height: 1080, fpsNum: 30, fpsDen: 1),
        VideoFormat(id: "1080p25", name: "1080p 25", width: 1920, height: 1080, fpsNum: 25, fpsDen: 1),
        VideoFormat(id: "1080p50", name: "1080p 50", width: 1920, height: 1080, fpsNum: 50, fpsDen: 1),
        VideoFormat(id: "1080p5994", name: "1080p 59.94", width: 1920, height: 1080, fpsNum: 60000, fpsDen: 1001),
        VideoFormat(id: "1080p60", name: "1080p 60", width: 1920, height: 1080, fpsNum: 60, fpsDen: 1),
        VideoFormat(id: "720p5994", name: "720p 59.94", width: 1280, height: 720, fpsNum: 60000, fpsDen: 1001),
        VideoFormat(id: "2160p2997", name: "2160p 29.97", width: 3840, height: 2160, fpsNum: 30000, fpsDen: 1001),
        VideoFormat(id: "2160p30", name: "2160p 30", width: 3840, height: 2160, fpsNum: 30, fpsDen: 1),
    ]

    static let defaultFormat = presets[0]

    static func preset(id: String) -> VideoFormat {
        presets.first(where: { $0.id == id }) ?? defaultFormat
    }
}

/// Creates IOSurface-backed, Metal-compatible BGRA pixel buffer pools.
enum PixelBufferFactory {
    static func makePool(width: Int, height: Int, minimumCount: Int = 3) -> CVPixelBufferPool? {
        let pixelAttrs: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: width,
            kCVPixelBufferHeightKey as String: height,
            kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any](),
            kCVPixelBufferMetalCompatibilityKey as String: true,
            kCVPixelBufferCGImageCompatibilityKey as String: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey as String: true,
        ]
        let poolAttrs: [String: Any] = [kCVPixelBufferPoolMinimumBufferCountKey as String: minimumCount]
        var pool: CVPixelBufferPool?
        let r = CVPixelBufferPoolCreate(kCFAllocatorDefault, poolAttrs as CFDictionary, pixelAttrs as CFDictionary, &pool)
        return r == kCVReturnSuccess ? pool : nil
    }

    static func makeBuffer(pool: CVPixelBufferPool) -> CVPixelBuffer? {
        var pb: CVPixelBuffer?
        let r = CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &pb)
        return r == kCVReturnSuccess ? pb : nil
    }
}

/// Holds the most recent frame of a source ("frame sync": the mixer always takes the newest frame).
final class VideoSlot {
    private let lock = NSLock()
    private let monitorLock = NSLock()
    private let monitorQueue = DispatchQueue(label: "hongmix.monitor-proxy", qos: .userInitiated)
    private var buffer: CVPixelBuffer?
    private var pool: CVPixelBufferPool?
    private var poolWidth = 0
    private var poolHeight = 0
    private var frames: UInt64 = 0
    private var lastTime: CFTimeInterval = 0
    // Low-resolution frame used only by input thumbnails. Program/Preview keep `buffer` untouched.
    private var monitorBuffer: CVPixelBuffer?
    private var monitorPool: CVPixelBufferPool?
    private var monitorPoolSize = (0, 0)
    private var monitorTransfer: VTPixelTransferSession?
    private var monitorLastSchedule: CFTimeInterval = 0
    private var monitorJobPending = false
    private var monitorGeneration: UInt64 = 0
    private var monitorConsumers = 0

    // Frame-arrival history for the frame-rate label and the Statistics window (vMix "Video" column).
    private var arrivals = [CFTimeInterval](repeating: 0, count: 128)
    private var arrivalIndex = 0
    private var lateFrames = 0          // gaps longer than 1.5 frame periods (≈ vMix "Source Dropped")
    private var lastWidth = 0, lastHeight = 0
    private var latestPTSUs: Int64 = -1
    private var lastPTSStepUs: Int64 = 0
    private var lastStoredSequence: UInt64 = 0
    private var lastProgramSequence: UInt64 = 0
    private var repeatedProgramTicks: UInt64 = 0
    // Sample the age of the frame actually consumed by Program. Keep a rolling window so
    // a single old frame can be diagnosed without carrying a stale lifetime maximum forever.
    private var programFrameAgeTimes = [CFTimeInterval](repeating: 0, count: 256)
    private var programFrameAgesMs = [Double](repeating: 0, count: 256)
    private var programFrameAgeIndex = 0
    private var programFrameAgeCount = 0
    /// Sources rendered on demand (web pages, titles, images): they only produce a frame when something
    /// changes, and the mixer re-uses the last one every program frame — so, like vMix, their rate is the
    /// program rate rather than the (variable) update rate.
    var followsProgramRate = false
    /// Declared rate of the source stream (0 = unknown → use the measured rate for the label).
    var nominalFPS: Double = 0
    /// Current program frame rate (set by the engine).
    static var programFPS: Double = 29.97

    func store(_ pb: CVPixelBuffer, ptsUs: Int64 = -1) {
        let now = CACurrentMediaTime()
        lock.lock()
        if !followsProgramRate, lastTime > 0, arrivalIndex >= 2 {
            let avg = averageInterval()
            if avg > 0, now - lastTime > avg * 1.5, now - lastTime < 1 { lateFrames += 1 }
        }
        buffer = pb
        frames &+= 1
        lastStoredSequence &+= 1
        if ptsUs >= 0 {
            if latestPTSUs >= 0 { lastPTSStepUs = ptsUs - latestPTSUs }
            latestPTSUs = ptsUs
        }
        lastTime = now
        arrivals[arrivalIndex % arrivals.count] = now
        arrivalIndex += 1
        lastWidth = CVPixelBufferGetWidth(pb)
        lastHeight = CVPixelBufferGetHeight(pb)
        lock.unlock()
        scheduleMonitorProxy(pb)
    }

    /// Called by the program render thread for inputs actually contributing to the on-air frame.
    /// This measures source-frame reuse and age at consumption, separately from decode arrival.
    func markProgramFrameUse() {
        let now = CACurrentMediaTime()
        lock.lock()
        if lastStoredSequence > 0 {
            if lastProgramSequence == lastStoredSequence { repeatedProgramTicks &+= 1 }
            lastProgramSequence = lastStoredSequence
            // Static/event-driven inputs (titles, graphics, browser pages) intentionally reuse
            // frames and have no meaningful frame age. Their update rate is reported separately.
            if !followsProgramRate {
                programFrameAgeTimes[programFrameAgeIndex] = now
                programFrameAgesMs[programFrameAgeIndex] = max(0, now - lastTime) * 1000
                programFrameAgeIndex = (programFrameAgeIndex + 1) % programFrameAgeTimes.count
                programFrameAgeCount = min(programFrameAgeCount + 1, programFrameAgeTimes.count)
            }
        }
        lock.unlock()
    }

    /// 480x270 monitor proxy at 6 fps; the full-resolution frame remains the source for the
    /// switcher and Program output. Scaling is done by VideoToolbox asynchronously. This is an
    /// operator-grid preview only, so spending half the conversion/Metal work is preferable to
    /// refreshing tiny thumbnails at a rate that is hard to distinguish visually.
    private func scheduleMonitorProxy(_ source: CVPixelBuffer) {
        let width = CVPixelBufferGetWidth(source), height = CVPixelBufferGetHeight(source)
        // Browser, title, still and generated graphic sources are BGRA and may carry alpha.
        // VTPixelTransferSession's BGRA downscale can return a black/empty proxy on some macOS
        // versions even though the full-resolution frame renders correctly in Preview/Program.
        // Keep that frame as the thumbnail source and let the monitor's Metal sampler scale it.
        // Decoded NV12 video still uses the inexpensive 480x270 proxy below.
        let format = CVPixelBufferGetPixelFormatType(source)
        guard format != kCVPixelFormatType_32BGRA, width > 480 || height > 270 else {
            monitorLock.lock(); monitorGeneration &+= 1; monitorBuffer = source; monitorLock.unlock()
            return
        }
        let now = CACurrentMediaTime()
        monitorLock.lock()
        guard monitorConsumers > 0, !monitorJobPending, now - monitorLastSchedule >= 1.0 / 6.0 else {
            monitorLock.unlock(); return
        }
        monitorJobPending = true
        monitorLastSchedule = now
        let generation = monitorGeneration
        monitorLock.unlock()

        monitorQueue.async { [weak self] in
            guard let self else { return }
            let scale = min(480 / Double(width), 270 / Double(height))
            let outW = max(2, Int((Double(width) * scale / 2).rounded()) * 2)
            let outH = max(2, Int((Double(height) * scale / 2).rounded()) * 2)
            if self.monitorTransfer == nil {
                var session: VTPixelTransferSession?
                if VTPixelTransferSessionCreate(allocator: kCFAllocatorDefault, pixelTransferSessionOut: &session) == noErr,
                   let session {
                    VTSessionSetProperty(session, key: kVTPixelTransferPropertyKey_RealTime, value: kCFBooleanTrue)
                    VTSessionSetProperty(session, key: kVTPixelTransferPropertyKey_ScalingMode, value: kVTScalingMode_Normal)
                    self.monitorTransfer = session
                }
            }
            if self.monitorPool == nil || self.monitorPoolSize.0 != outW || self.monitorPoolSize.1 != outH {
                self.monitorPool = PixelBufferFactory.makePool(width: outW, height: outH, minimumCount: 3)
                self.monitorPoolSize = (outW, outH)
            }
            var result: CVPixelBuffer?
            if let session = self.monitorTransfer, let pool = self.monitorPool,
               let dst = PixelBufferFactory.makeBuffer(pool: pool),
               VTPixelTransferSessionTransferImage(session, from: source, to: dst) == noErr {
                CVBufferPropagateAttachments(source, dst)
                result = dst
            }
            self.monitorLock.lock()
            if self.monitorGeneration == generation, let result { self.monitorBuffer = result }
            self.monitorJobPending = false
            self.monitorLock.unlock()
        }
    }

    func monitorLatest() -> CVPixelBuffer? {
        monitorLock.lock()
        let proxy = monitorBuffer
        monitorLock.unlock()
        return proxy ?? latest()
    }

    /// Only generate scaled input-grid frames while a tile is actually visible in a window.
    /// Program and Preview use `latest()` and are not governed by this demand counter.
    func setMonitorDemand(_ active: Bool) {
        monitorLock.lock()
        if active {
            monitorConsumers += 1
            if monitorConsumers == 1 { monitorLastSchedule = 0 }
        } else {
            monitorConsumers = max(0, monitorConsumers - 1)
            if monitorConsumers == 0 {
                monitorGeneration &+= 1
                monitorBuffer = nil
            }
        }
        monitorLock.unlock()
    }

    /// lock held
    private func averageInterval(window: CFTimeInterval = 2) -> Double {
        let n = min(arrivalIndex, arrivals.count)
        guard n >= 2 else { return 0 }
        let newest = arrivals[(arrivalIndex - 1) % arrivals.count]
        var oldest = newest
        var count = 0
        for k in 1..<n {
            let t = arrivals[(arrivalIndex - 1 - k) % arrivals.count]
            if newest - t > window { break }
            oldest = t
            count = k
        }
        return count > 0 ? (newest - oldest) / Double(count) : 0
    }

    struct Stats {
        var fps: Double            // measured over the last ~2 s, 0 = no live video
        var width: Int
        var height: Int
        var intervalsMs: [Double]  // newest last
        var maxGapMs: Double = 0   // maximum source-frame arrival interval in the rolling 2 s window
        var late: Int
        var updateFPS: Double = 0   // measured arrival rate (on-demand sources: how often it changed)
        var jitterMs: Double = 0    // std-dev of frame intervals over the last ~2 s (cadence evenness)
        var latestPTSUs: Int64 = -1
        var lastPTSStepMs: Double = 0
        var repeatedProgramTicks: UInt64 = 0
        var maxProgramFrameAgeMs: Double = 0
    }

    var stats: Stats {
        lock.lock()
        defer { lock.unlock() }
        let now = CACurrentMediaTime()
        let live = lastTime > 0 && now - lastTime < 2
        let avg = averageInterval()
        var iv: [Double] = []
        let n = min(arrivalIndex, arrivals.count)
        if n >= 2 {
            for k in stride(from: min(4, n - 1), through: 1, by: -1) {
                let a = arrivals[(arrivalIndex - 1 - k) % arrivals.count]
                let b = arrivals[(arrivalIndex - k) % arrivals.count]
                iv.append((b - a) * 1000)
            }
        }
        let measured = live && avg > 0 ? 1 / avg : 0
        var jitter = 0.0
        var maxGap = 0.0
        if live && n >= 4 {
            let newest = arrivals[(arrivalIndex - 1) % arrivals.count]
            var sum = 0.0, sum2 = 0.0, c = 0.0
            for k in 1..<n {
                let b = arrivals[(arrivalIndex - k) % arrivals.count]
                let a = arrivals[(arrivalIndex - 1 - k) % arrivals.count]
                if newest - a > 2 { break }
                let d = (b - a) * 1000
                sum += d; sum2 += d * d; c += 1
            }
            if c >= 3 { jitter = (max(0, sum2 / c - (sum / c) * (sum / c))).squareRoot() }
        }
        if live && n >= 2 {
            let newestArrival = arrivals[(arrivalIndex - 1) % arrivals.count]
            for offset in 0..<(n - 1) {
                let newer = arrivals[(arrivalIndex - 1 - offset) % arrivals.count]
                let older = arrivals[(arrivalIndex - 2 - offset) % arrivals.count]
                if newestArrival - older > 2 { break }
                maxGap = max(maxGap, (newer - older) * 1000)
            }
        }
        var maxProgramFrameAge = 0.0
        if !followsProgramRate {
            for offset in 0..<programFrameAgeCount {
                let index = (programFrameAgeIndex - 1 - offset + programFrameAgeTimes.count) % programFrameAgeTimes.count
                if now - programFrameAgeTimes[index] > 2 { break }
                maxProgramFrameAge = max(maxProgramFrameAge, programFrameAgesMs[index])
            }
        }
        if followsProgramRate && frames > 0 {
            return Stats(fps: VideoSlot.programFPS, width: lastWidth, height: lastHeight,
                         intervalsMs: iv, maxGapMs: maxGap, late: 0, updateFPS: measured, jitterMs: jitter,
                         latestPTSUs: latestPTSUs, lastPTSStepMs: Double(lastPTSStepUs) / 1000,
                         repeatedProgramTicks: repeatedProgramTicks, maxProgramFrameAgeMs: 0)
        }
        // a live stream that declares its rate: label it with that (vMix shows the source format),
        // unless delivery is clearly far off (then the measured rate is the useful truth)
        let shown = nominalFPS > 0 && measured > 0 && abs(measured - nominalFPS) / nominalFPS < 0.1 ? nominalFPS : measured
        return Stats(fps: shown, width: lastWidth, height: lastHeight,
                     intervalsMs: iv, maxGapMs: maxGap, late: lateFrames, updateFPS: measured, jitterMs: jitter,
                     latestPTSUs: latestPTSUs, lastPTSStepMs: Double(lastPTSStepUs) / 1000,
                     repeatedProgramTicks: repeatedProgramTicks, maxProgramFrameAgeMs: maxProgramFrameAge)
    }

    func resetStats() {
        lock.lock()
        lateFrames = 0
        sourceDrops = 0
        repeatedProgramTicks = 0
        arrivals = [CFTimeInterval](repeating: 0, count: arrivals.count)
        arrivalIndex = 0
        lastPTSStepUs = 0
        latestPTSUs = -1
        programFrameAgeTimes = [CFTimeInterval](repeating: 0, count: programFrameAgeTimes.count)
        programFrameAgesMs = [Double](repeating: 0, count: programFrameAgesMs.count)
        programFrameAgeIndex = 0
        programFrameAgeCount = 0
        lock.unlock()
    }

    private var sourceDrops = 0
    func countSourceDrop() {
        lock.lock()
        sourceDrops += 1
        lock.unlock()
    }
    var sourceDropped: Int {
        lock.lock()
        defer { lock.unlock() }
        return sourceDrops
    }

    /// "1080p59.94" style label, snapped to broadcast rates when close.
    /// `ntsc`: prefer 29.97/59.94-style rates when the measurement can't tell them apart from 30/60
    /// (they differ by only 0.1 %; arrival times jitter more than that).
    static func formatLabel(_ s: Stats, ntsc: Bool = true) -> String? {
        guard s.fps > 0.5, s.height > 0 else { return nil }
        let standard: [(Double, String)] = [(23.976, "23.98"), (24, "24"), (25, "25"), (29.97, "29.97"), (30, "30"),
                                            (48, "48"), (50, "50"), (59.94, "59.94"), (60, "60"), (100, "100"),
                                            (119.88, "119.88"), (120, "120")]
        var rate = String(format: "%.2f", s.fps)
        let close = standard.filter { abs($0.0 - s.fps) / $0.0 < 0.015 }
        if let exact = standard.first(where: { abs($0.0 - s.fps) < 0.0015 * $0.0 / 30 }) {
            rate = exact.1          // declared stream rate (exact) — no NTSC guessing
        } else if !close.isEmpty {
            let isNTSC: (Double) -> Bool = { $0 != $0.rounded() }   // 23.976, 29.97, 59.94, 119.88
            let family = close.filter { isNTSC($0.0) == ntsc }
            let pool = family.isEmpty ? close : family
            rate = pool.min(by: { abs($0.0 - s.fps) < abs($1.0 - s.fps) })!.1
        } else if s.fps < 10 {
            rate = String(format: "%.1f", s.fps)
        }
        return "\(s.height)p\(rate)"
    }

    /// Shown instead of the (frozen) last frame while the input has lost its signal.
    var substitute: CVPixelBuffer? {
        get { lock.lock(); defer { lock.unlock() }; return _substitute }
        set { lock.lock(); _substitute = newValue; lock.unlock() }
    }
    private var _substitute: CVPixelBuffer?

    func latest() -> CVPixelBuffer? {
        lock.lock()
        defer { lock.unlock() }
        return _substitute ?? buffer
    }

    var frameCount: UInt64 {
        lock.lock()
        defer { lock.unlock() }
        return frames
    }

    /// Seconds since the last frame arrived (infinity if never).
    var age: CFTimeInterval {
        lock.lock()
        defer { lock.unlock() }
        return lastTime == 0 ? .infinity : CACurrentMediaTime() - lastTime
    }

    var size: (Int, Int)? {
        guard let pb = latest() else { return nil }
        return (CVPixelBufferGetWidth(pb), CVPixelBufferGetHeight(pb))
    }

    func clear() {
        lock.lock()
        buffer = nil
        lock.unlock()
        monitorLock.lock()
        monitorGeneration &+= 1
        monitorBuffer = nil
        monitorLock.unlock()
    }

    private var transfer: VTPixelTransferSession?

    /// Hardware-decoded frame (NV12 IOSurface from VideoToolbox) → pooled BGRA IOSurface, converted on the
    /// GPU by VTPixelTransferSession. No CPU copy, no CPU colour conversion. Called on the decoder thread.
    func ingest(pixelBuffer src: CVPixelBuffer, ptsUs: Int64 = -1) {
        let width = CVPixelBufferGetWidth(src), height = CVPixelBufferGetHeight(src)
        guard width > 0, height > 0 else { return }
        let fmt = CVPixelBufferGetPixelFormatType(src)
        // BGRA or NV12 IOSurfaces go straight to the GPU (the shaders read NV12 natively):
        // no per-frame conversion, however many inputs are open.
        if CVPixelBufferGetIOSurface(src) != nil &&
            (fmt == kCVPixelFormatType_32BGRA || fmt == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange ||
             fmt == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange) {
            if fmt != kCVPixelFormatType_32BGRA && CVBufferCopyAttachment(src, kCVImageBufferYCbCrMatrixKey, nil) == nil {
                CVBufferSetAttachment(src, kCVImageBufferYCbCrMatrixKey,
                                      height >= 720 ? kCVImageBufferYCbCrMatrix_ITU_R_709_2 : kCVImageBufferYCbCrMatrix_ITU_R_601_4,
                                      .shouldPropagate)
            }
            store(src, ptsUs: ptsUs)
            return
        }
        if transfer == nil {
            var t: VTPixelTransferSession?
            guard VTPixelTransferSessionCreate(allocator: kCFAllocatorDefault, pixelTransferSessionOut: &t) == noErr,
                  let t = t else { return }
            VTSessionSetProperty(t, key: kVTPixelTransferPropertyKey_RealTime, value: kCFBooleanTrue)
            transfer = t
        }
        if pool == nil || poolWidth != width || poolHeight != height {
            pool = PixelBufferFactory.makePool(width: width, height: height, minimumCount: 4)
            poolWidth = width
            poolHeight = height
        }
        // Streams often carry no colour tags: assume BT.709 for HD, BT.601 for SD (same rule as the CPU path).
        if CVBufferCopyAttachment(src, kCVImageBufferYCbCrMatrixKey, nil) == nil {
            CVBufferSetAttachment(src, kCVImageBufferYCbCrMatrixKey,
                                  height >= 720 ? kCVImageBufferYCbCrMatrix_ITU_R_709_2 : kCVImageBufferYCbCrMatrix_ITU_R_601_4,
                                  .shouldPropagate)
        }
        guard let pool = pool, let t = transfer, let dst = PixelBufferFactory.makeBuffer(pool: pool) else { return }
        if VTPixelTransferSessionTransferImage(t, from: src, to: dst) == noErr {
            store(dst, ptsUs: ptsUs)
        }
    }

    deinit {
        if let t = transfer { VTPixelTransferSessionInvalidate(t) }
        if let t = monitorTransfer { VTPixelTransferSessionInvalidate(t) }
    }

    /// Copies a BGRA frame from C memory into a pooled pixel buffer. Called on the producer thread.
    func ingest(bgra: UnsafePointer<UInt8>, width: Int, height: Int, stride: Int, ptsUs: Int64 = -1) {
        guard width > 0, height > 0 else { return }
        if pool == nil || poolWidth != width || poolHeight != height {
            pool = PixelBufferFactory.makePool(width: width, height: height)
            poolWidth = width
            poolHeight = height
        }
        guard let pool = pool, let pb = PixelBufferFactory.makeBuffer(pool: pool) else { return }
        CVPixelBufferLockBaseAddress(pb, [])
        if let dst = CVPixelBufferGetBaseAddress(pb) {
            let dstStride = CVPixelBufferGetBytesPerRow(pb)
            let rowBytes = width * 4
            if dstStride == stride {
                memcpy(dst, bgra, stride * height)
            } else {
                for y in 0..<height {
                    memcpy(dst + y * dstStride, bgra + y * stride, rowBytes)
                }
            }
        }
        CVPixelBufferUnlockBaseAddress(pb, [])
        store(pb, ptsUs: ptsUs)
    }
}

/// Thread-safe interleaved stereo float ring buffer (48 kHz).
final class AudioRing {
    private let lock = NSLock()
    private let capacity: Int  // frames
    private let data: UnsafeMutablePointer<Float>
    private var readPos = 0
    private var count = 0
    private var written: Int64 = 0
    private var readFrames: Int64 = 0
    private var shortReads: Int64 = 0
    private var minAvailableAtRead: Int?
    private var clearGeneration: UInt64 = 0

    init(seconds: Double = 2.0) {
        capacity = Int(48000 * seconds)
        data = UnsafeMutablePointer<Float>.allocate(capacity: capacity * 2)
        data.initialize(repeating: 0, count: capacity * 2)
    }

    deinit {
        data.deallocate()
    }

    var available: Int {
        lock.lock()
        defer { lock.unlock() }
        return count
    }

    /// Snapshot used by the audio mixer to notice a pause/seek clear and re-prime safely.
    var mixSnapshot: (available: Int, generation: UInt64) {
        lock.lock()
        defer { lock.unlock() }
        return (count, clearGeneration)
    }

    func write(_ src: UnsafePointer<Float>, frames: Int) {
        guard frames > 0 else { return }
        lock.lock()
        var n = frames
        var s = src
        if n > capacity {
            s = s + (n - capacity) * 2
            n = capacity
        }
        if count + n > capacity {
            let over = count + n - capacity
            readPos = (readPos + over) % capacity
            count -= over
        }
        var w = (readPos + count) % capacity
        for i in 0..<n {
            data[w * 2] = s[i * 2]
            data[w * 2 + 1] = s[i * 2 + 1]
            w += 1
            if w == capacity { w = 0 }
        }
        count += n
        written += Int64(n)
        lock.unlock()
    }

    @discardableResult
    func read(into dst: UnsafeMutablePointer<Float>, frames: Int) -> Int {
        lock.lock()
        minAvailableAtRead = min(minAvailableAtRead ?? count, count)
        let n = min(frames, count)
        var r = readPos
        for i in 0..<n {
            dst[i * 2] = data[r * 2]
            dst[i * 2 + 1] = data[r * 2 + 1]
            r += 1
            if r == capacity { r = 0 }
        }
        readPos = r
        count -= n
        readFrames += Int64(n)
        if n < frames { shortReads += 1 }
        lock.unlock()
        return n
    }

    func skip(frames: Int) {
        lock.lock()
        let n = min(frames, count)
        readPos = (readPos + n) % capacity
        count -= n
        lock.unlock()
    }

    func clear() {
        lock.lock()
        readPos = 0
        count = 0
        clearGeneration &+= 1
        lock.unlock()
    }

    var diagnostics: (available: Int, written: Int64, read: Int64, shortReads: Int64, minReadAvailable: Int?) {
        lock.lock(); defer { lock.unlock() }
        return (count, written, readFrames, shortReads, minAvailableAtRead)
    }

    func resetDiagnostics() {
        lock.lock(); shortReads = 0; minAvailableAtRead = nil; lock.unlock()
    }
}

/// SPSC queue dedicated to CoreAudio render callbacks. Unlike AudioRing (which allows
/// occasional UI/transport clears), this ring uses C11 atomics so the realtime reader never
/// waits on a mutex. Its lifecycle guarantees one mixer writer and one CoreAudio reader.
final class RealtimeAudioRing {
    private let handle: OpaquePointer

    init(seconds: Double = 3.0) {
        let frames = max(2, Int((48000 * seconds).rounded()))
        guard let ring = mc_audio_ring_create(Int32(frames)) else {
            fatalError("Could not allocate realtime audio ring")
        }
        handle = ring
    }

    deinit { mc_audio_ring_destroy(handle) }

    var available: Int { Int(mc_audio_ring_available(handle)) }

    @discardableResult
    func write(_ src: UnsafePointer<Float>, frames: Int) -> Int {
        Int(mc_audio_ring_write(handle, src, Int32(clamping: frames)))
    }

    @discardableResult
    func read(into dst: UnsafeMutablePointer<Float>, frames: Int) -> Int {
        Int(mc_audio_ring_read(handle, dst, Int32(clamping: frames)))
    }

    @discardableResult
    func skip(frames: Int) -> Int {
        Int(mc_audio_ring_skip(handle, Int32(clamping: frames)))
    }

    func clear() { mc_audio_ring_clear(handle) }

    var diagnostics: (shortReads: UInt64, shortFrames: UInt64, primingSilenceFrames: UInt64, availableFrames: Int) {
        (mc_audio_ring_short_reads(handle), mc_audio_ring_short_frames(handle),
         mc_audio_ring_priming_silence_frames(handle), available)
    }

    func notePrimingSilence(frames: Int) {
        mc_audio_ring_note_priming_silence(handle, UInt64(max(0, frames)))
    }

    func resetDiagnostics() { mc_audio_ring_reset_diagnostics(handle) }
}


/// Pre-rendered slates for signal loss (made once, shared).
enum Slates {
    static let black: CVPixelBuffer? = make(width: 64, height: 36) { _, _, _ in }

    static let noSignal: CVPixelBuffer? = make(width: 1920, height: 1080) { ctx, w, h in
        // SMPTE-style bars + "NO SIGNAL"
        let bars: [(CGFloat, CGFloat, CGFloat)] = [(0.75, 0.75, 0.75), (0.75, 0.75, 0), (0, 0.75, 0.75), (0, 0.75, 0),
                                                   (0.75, 0, 0.75), (0.75, 0, 0), (0, 0, 0.75)]
        let bw = CGFloat(w) / CGFloat(bars.count)
        for (i, c) in bars.enumerated() {
            ctx.setFillColor(CGColor(red: c.0, green: c.1, blue: c.2, alpha: 1))
            ctx.fill(CGRect(x: CGFloat(i) * bw, y: CGFloat(h) * 0.25, width: bw + 1, height: CGFloat(h) * 0.75))
        }
        ctx.setFillColor(CGColor(gray: 0.08, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: CGFloat(w), height: CGFloat(h) * 0.25))
        let box = CGRect(x: CGFloat(w) * 0.25, y: CGFloat(h) * 0.42, width: CGFloat(w) * 0.5, height: CGFloat(h) * 0.16)
        ctx.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 0.85))
        ctx.fill(box)
        let font = CTFontCreateWithName("Helvetica-Bold" as CFString, CGFloat(h) * 0.09, nil)
        let attrs: [NSAttributedString.Key: Any] = [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(gray: 1, alpha: 1),
        ]
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: "NO SIGNAL", attributes: attrs))
        let b = CTLineGetBoundsWithOptions(line, [])
        ctx.textPosition = CGPoint(x: box.midX - b.width / 2, y: box.midY - b.height / 2 - b.minY)
        CTLineDraw(line, ctx)
    }

    private static func make(width: Int, height: Int, draw: (CGContext, Int, Int) -> Void) -> CVPixelBuffer? {
        guard let pool = PixelBufferFactory.makePool(width: width, height: height, minimumCount: 1),
              let pb = PixelBufferFactory.makeBuffer(pool: pool) else { return nil }
        CVPixelBufferLockBaseAddress(pb, [])
        defer { CVPixelBufferUnlockBaseAddress(pb, []) }
        guard let base = CVPixelBufferGetBaseAddress(pb) else { return nil }
        memset(base, 0, CVPixelBufferGetBytesPerRow(pb) * height)
        let info = CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        guard let ctx = CGContext(data: base, width: width, height: height, bitsPerComponent: 8,
                                  bytesPerRow: CVPixelBufferGetBytesPerRow(pb), space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: info) else { return nil }
        ctx.setFillColor(CGColor(gray: 0, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        draw(ctx, width, height)
        return pb
    }
}
