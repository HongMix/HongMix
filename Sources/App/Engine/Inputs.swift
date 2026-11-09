import Foundation
import AVFoundation
import CoreVideo
import CoreGraphics
import AppKit
import CoreAudio

/// Inputs fed from the C core through mc_callbacks.
class CallbackInput: InputSource {
    func makeCallbacks() -> mc_callbacks {
        var cb = mc_callbacks()
        cb.user = Unmanaged.passUnretained(self).toOpaque()
        cb.on_video = { user, data, w, h, stride, pts in
            guard let user = user, let data = data else { return }
            let me = Unmanaged<CallbackInput>.fromOpaque(user).takeUnretainedValue()
            me.video.ingest(bgra: data, width: Int(w), height: Int(h), stride: Int(stride), ptsUs: Int64(pts))
        }
        cb.on_pixelbuffer = { user, pb, pts in
            guard let user = user, let pb = pb else { return }
            let me = Unmanaged<CallbackInput>.fromOpaque(user).takeUnretainedValue()
            let buffer = Unmanaged<CVPixelBuffer>.fromOpaque(pb).takeUnretainedValue()
            me.video.ingest(pixelBuffer: buffer, ptsUs: Int64(pts))
        }
        cb.on_video_drop = { user in
            guard let user = user else { return }
            Unmanaged<CallbackInput>.fromOpaque(user).takeUnretainedValue().video.countSourceDrop()
        }
        cb.on_audio = { user, data, frames in
            guard let user = user, let data = data else { return }
            let me = Unmanaged<CallbackInput>.fromOpaque(user).takeUnretainedValue()
            me.noteAudioFrame()
            me.audio.write(data, frames: Int(frames))
        }
        cb.on_audio_presence = { user, present in
            guard let user = user else { return }
            Unmanaged<CallbackInput>.fromOpaque(user).takeUnretainedValue().noteAudioTrack(present != 0)
        }
        cb.on_status = { user, state, msg in
            guard let user = user else { return }
            let me = Unmanaged<CallbackInput>.fromOpaque(user).takeUnretainedValue()
            let text = msg.map { String(cString: $0) } ?? ""
            me.postStatus(state, text)
        }
        return cb
    }
}

// MARK: - FFmpeg (files, SRT, RTMP, UDP, HLS)

final class FFmpegInput: CallbackInput {
    private var handle: OpaquePointer?
    private let handleLock = NSLock()

    override var supportsTransport: Bool { kind == .media }

    // MARK: List input (vMix "List"): several files played one after another
    @Published var playlist: [String] = [] { didSet { if playlist != oldValue { applyTransport() } } }
    @Published private(set) var playlistIndex = 0
    var isList: Bool { playlist.count > 1 }
    private let listQueue = DispatchQueue(label: "list.switch", qos: .userInitiated)
    private var queuedListIndex: Int?

    override init(config: InputConfig) {
        super.init(config: config)
        playlist = config.playlist
        playlistIndex = max(0, min(config.playlistIndex, max(0, config.playlist.count - 1)))
        if playlist.indices.contains(playlistIndex) { self.config.url = playlist[playlistIndex] }
        conformObserver = NotificationCenter.default.addObserver(forName: .hongMixRateConformChanged, object: nil,
                                                                 queue: .main) { [weak self] _ in self?.applyTransport() }
    }
    private var conformObserver: NSObjectProtocol?

    override func currentConfig() -> InputConfig {
        var c = super.currentConfig()
        c.playlist = playlist
        c.playlistIndex = playlistIndex
        return c
    }

    /// Jump to item `index` of the list (0-based). Keeps showing the last frame until the new file is up.
    func selectItem(_ index: Int, play: Bool = true) {
        guard playlist.indices.contains(index) else { return }
        playlistIndex = index
        config.url = playlist[index]
        let old: OpaquePointer?
        handleLock.lock(); old = handle; handle = nil; handleLock.unlock()
        position = 0
        listQueue.async { [weak self] in
            if let h = old { mc_input_close(h) }
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.audio.clear()
                self.start()
                if play && !self.playing { self.playing = true }
            }
        }
    }

    func nextItem() {
        guard !playlist.isEmpty else { return }
        let n = playlistIndex + 1
        if n < playlist.count { selectItem(n) } else if looping { selectItem(0) }
    }

    func previousItem() {
        guard !playlist.isEmpty else { return }
        selectItem(playlistIndex > 0 ? playlistIndex - 1 : (looping ? playlist.count - 1 : 0))
    }

    func addItems(_ paths: [String]) {
        if playlist.isEmpty && !config.url.isEmpty { playlist = [config.url] }
        playlist.append(contentsOf: paths)
        if playlist.count == paths.count { selectItem(0, play: playing) }
    }

    func removeItem(_ index: Int) {
        guard playlist.indices.contains(index) else { return }
        playlist.remove(at: index)
        if playlist.isEmpty { return }
        if index == playlistIndex { selectItem(min(index, playlist.count - 1), play: playing) }
        else if index < playlistIndex { playlistIndex -= 1 }
    }

    func moveItem(from: Int, to: Int) {
        guard playlist.indices.contains(from), to >= 0, to <= playlist.count, from != to else { return }
        let cur = playlist[playlistIndex]
        let item = playlist.remove(at: from)
        playlist.insert(item, at: to > from ? to - 1 : to)
        playlistIndex = playlist.firstIndex(of: cur) ?? 0
    }

    func shuffleList() {
        guard isList else { return }
        let cur = playlist[playlistIndex]
        playlist.shuffle()
        playlistIndex = playlist.firstIndex(of: cur) ?? 0
    }

    /// Live SRT link statistics (nil when this input isn't a connected SRT session).
    func srtStats() -> SRTStats? {
        var st = mc_srt_stats()
        var ok: Int32 = 0
        withHandle { h in ok = mc_input_srt_stats(h, &st) }
        return ok != 0 ? SRTStats(st) : nil
    }

    /// Decoder that is actually delivering frames, not merely the requested hardware preference.
    func videoDecodeModeName() -> String {
        var mode: Int32 = 0
        withHandle { h in mode = Int32(mc_input_video_decode_mode(h)) }
        switch mode {
        case 1: return "VideoToolbox"
        case 2: return "Software"
        default: return "Pending"
        }
    }

    /// File audio waiting in the timestamp-paced FFmpeg release queue.
    func audioQueueDiagnostics() -> mc_input_audio_queue_stats? {
        var stats = mc_input_audio_queue_stats()
        var ok: Int32 = 0
        withHandle { h in ok = mc_input_get_audio_queue_stats(h, &stats) }
        return ok != 0 ? stats : nil
    }

    func resetAudioQueueDiagnostics() {
        withHandle { h in mc_input_reset_audio_queue_stats(h) }
    }

    private func withHandle(_ body: (OpaquePointer) -> Void) {
        handleLock.lock()
        if let h = handle { body(h) }
        handleLock.unlock()
    }

    override func applyTransport() {
        let paused = !playing, loop = looping && !isList, rate = self.rate * conformFactor
        let mi = markIn >= 0 ? Int64(markIn * 1_000_000) : -1
        let mo = markOut > 0 ? Int64(markOut * 1_000_000) : -1
        if paused { audio.clear() }
        withHandle { h in
            mc_input_set_paused(h, paused ? 1 : 0)
            mc_input_set_loop(h, loop ? 1 : 0)
            mc_input_set_marks(h, mi, mo)
            mc_input_set_rate(h, rate)
        }
    }

    /// Declared stream rate (e.g. 30 for an SRT feed) — shown in the format label like vMix, instead of
    /// the arrival rate, which wobbles while the jitter buffer settles.
    func pollNominalRate() {
        var f = 0.0
        withHandle { h in f = mc_input_nominal_fps(h) }
        if video.nominalFPS != f {
            video.nominalFPS = f
            if kind == .media { applyTransport() }   // re-evaluate 60 ↔ 59.94 conform for the new file
        }
    }

    static let rateConformKey = "fileRateConform"

    /// vMix-style frame-rate conform for files: a 60.00 fps file in a 59.94 program (or 59.94 in 60)
    /// otherwise drops (or repeats) one frame every ~17 s. Playing it 0.1 % slower/faster makes every
    /// source frame land on exactly one program frame. Audio is resampled to match (inaudible).
    var conformFactor: Double {
        guard kind == .media,
              UserDefaults.standard.object(forKey: Self.rateConformKey) as? Bool ?? true else { return 1 }
        let src = video.nominalFPS, prog = VideoSlot.programFPS
        guard src > 1, prog > 1 else { return 1 }
        let ntsc = 1000.0 / 1001.0
        // try both directions and integer multiples (60 → 59.94, 30 → 29.97/59.94, 50 ↔ 50 is untouched)
        for factor in [ntsc, 1 / ntsc] {
            let conformed = src * factor
            let ratio = prog / conformed
            let k = ratio.rounded()
            if k >= 1, abs(ratio - k) < 0.0002 { return factor }
            let inv = (conformed / prog).rounded()
            if inv >= 1, abs(conformed / prog - inv) < 0.0002 { return factor }
        }
        return 1
    }

    override func pollPosition() {
        guard supportsTransport else { return }
        var pos: Int64 = 0, dur: Int64 = 0
        var finished: Int32 = 0
        withHandle { h in mc_input_get_position(h, &pos, &dur, &finished) }
        let p = Double(pos) / 1_000_000, d = Double(dur) / 1_000_000
        // Gapless list hand-off: let the existing FFmpeg thread know the next URL before EOF. It keeps
        // the same callbacks and audio ring, so opening the next demuxer does not pay a thread/UI restart.
        // Mixed 4K/1080p and 44.1/48 kHz lists need enough time to open the next demuxer, create
        // VideoToolbox/audio converters and warm the disk cache before the on-air hand-off.
        if isList, playing, d > 0, d - p < 5.0, queuedListIndex == nil {
            let next = playlistIndex + 1 < playlist.count ? playlistIndex + 1 : (looping ? 0 : -1)
            if next >= 0 {
                queuedListIndex = next
                playlist[next].withCString { path in withHandle { mc_input_queue_next($0, path) } }
            }
        }
        if let queued = queuedListIndex, p < 0.5, position > 1.0 {
            playlistIndex = queued
            config.url = playlist[queued]
            queuedListIndex = nil
        }
        if abs(position - p) > 0.05 { position = p }
        if duration != d { duration = d }
        if finished != 0 && playing && queuedListIndex == nil {
            if isList && (playlistIndex + 1 < playlist.count || looping) {
                nextItem()            // List input: next file
            } else {
                playing = false
                emit(.completion)
            }
        }
    }

    override func seek(seconds: Double) {
        let us = Int64(max(0, seconds) * 1_000_000)
        audio.clear() // discard pre-seek PCM; the C scheduler restarts from the requested media PTS
        withHandle { h in mc_input_seek(h, us) }
    }

    override func start() {
        guard handle == nil else { return }
        let url = config.url
        guard !url.isEmpty else {
            postStatus(Int32(MC_STATE_ERROR), L("URL/파일이 비어 있음"))
            return
        }
        var cfg = mc_input_config()
        cfg.loop = looping ? 1 : 0
        cfg.realtime = -1
        cfg.low_latency = config.lowLatency ? 1 : 0
        cfg.hwaccel = config.hardwareDecode ? 1 : 0
        cfg.timeout_ms = 5000
        let cb = makeCallbacks()
        let h = url.withCString { ptr -> OpaquePointer? in
            cfg.url = ptr
            return mc_input_open(&cfg, cb)
        }
        handleLock.lock()
        handle = h
        handleLock.unlock()
        if h == nil { postStatus(Int32(MC_STATE_ERROR), L("입력을 시작할 수 없음")) }
        applyTransport()
    }

    override func stop() {
        handleLock.lock()
        let h = handle
        handle = nil
        handleLock.unlock()
        if let h = h { mc_input_close(h) }
        video.clear()
        audio.clear()
    }

    override func restart() {
        withHandle { h in mc_input_restart(h) }
        if supportsTransport && !playing { playing = true }
    }
}

// MARK: - NDI

final class NDIInput: CallbackInput {
    private var handle: OpaquePointer?
    private let tallyLock = NSLock()

    override var alphaPremultiplied: Bool { false }

    override func start() {
        guard handle == nil else { return }
        guard mc_ndi_available() != 0 else {
            postStatus(Int32(MC_STATE_ERROR), L("NDI 런타임이 설치되어 있지 않음"))
            return
        }
        handle = mc_ndi_recv_open(config.ndiSource, config.ndiLowBandwidth ? 1 : 0, makeCallbacks())
        if handle == nil { postStatus(Int32(MC_STATE_ERROR), L("NDI 수신을 시작할 수 없음")) }
    }

    override func stop() {
        tallyLock.lock()
        let h = handle
        handle = nil
        tallyLock.unlock()
        if let h = h { mc_ndi_recv_close(h) }
        video.clear()
        audio.clear()
    }

    override func setTally(program: Bool, preview: Bool) {
        tallyLock.lock()
        if let h = handle { mc_ndi_recv_set_tally(h, program ? 1 : 0, preview ? 1 : 0) }
        tallyLock.unlock()
    }

    override var linkAlive: Bool {
        tallyLock.lock()
        defer { tallyLock.unlock() }
        return handle.map { mc_ndi_recv_link($0) != 0 } ?? false
    }
}

// MARK: - DeckLink

final class DeckLinkInput: CallbackInput {
    private var handle: OpaquePointer?

    override func start() {
        guard handle == nil else { return }
        var err = [CChar](repeating: 0, count: 256)
        handle = mc_decklink_in_open(Int32(config.deckLinkIndex), makeCallbacks(), &err, Int32(err.count))
        if handle == nil { postStatus(Int32(MC_STATE_ERROR), String(cString: err)) }
    }

    override func stop() {
        if let h = handle {
            handle = nil
            mc_decklink_in_close(h)
        }
        video.clear()
        audio.clear()
    }
}

// MARK: - Color / bars

final class ColorInput: InputSource {
    /// Transparent / semi-transparent colours are drawn premultiplied.
    override var alphaPremultiplied: Bool { true }

    override func start() {
        let w = 1920, h = 1080
        guard let pool = PixelBufferFactory.makePool(width: w, height: h, minimumCount: 1),
              let pb = PixelBufferFactory.makeBuffer(pool: pool) else { return }
        CVPixelBufferLockBaseAddress(pb, [])
        if let base = CVPixelBufferGetBaseAddress(pb) {
            let stride = CVPixelBufferGetBytesPerRow(pb)
            let p = base.assumingMemoryBound(to: UInt8.self)
            let spec = config.color.lowercased()
            let alpha = ColorInput.alpha(spec)
            for y in 0..<h {
                let row = p + y * stride
                for x in 0..<w {
                    let (r, g, b) = ColorInput.pixel(spec: spec, x: x, y: y, w: w, h: h)
                    // premultiplied BGRA
                    row[x * 4] = UInt8(Int(b) * Int(alpha) / 255)
                    row[x * 4 + 1] = UInt8(Int(g) * Int(alpha) / 255)
                    row[x * 4 + 2] = UInt8(Int(r) * Int(alpha) / 255)
                    row[x * 4 + 3] = alpha
                }
            }
        }
        CVPixelBufferUnlockBaseAddress(pb, [])
        video.store(pb)
        let spec = config.color.lowercased()
        postStatus(Int32(MC_STATE_RUNNING), spec == "bars" ? L("SMPTE 컬러바") : (spec == "transparent" ? L("투명") : config.color))
    }

    static func alpha(_ spec: String) -> UInt8 {
        if spec == "transparent" { return 0 }
        var hex = spec
        if hex.hasPrefix("#") { hex.removeFirst() }
        if hex.count == 8, let v = UInt32(hex, radix: 16) { return UInt8(v & 0xFF) }
        return 255
    }

    private var spec: String { config.color.lowercased() }

    static func pixel(spec: String, x: Int, y: Int, w: Int, h: Int) -> (UInt8, UInt8, UInt8) {
        switch spec {
        case "black": return (0, 0, 0)
        case "white": return (235, 235, 235)
        case "bars":
            // 75% SMPTE-style bars on top 2/3, pluge-like strip below
            if y < h * 2 / 3 {
                let bars: [(UInt8, UInt8, UInt8)] = [(191, 191, 191), (191, 191, 0), (0, 191, 191), (0, 191, 0),
                                                     (191, 0, 191), (191, 0, 0), (0, 0, 191)]
                return bars[min(6, x * 7 / w)]
            } else if y < h * 3 / 4 {
                let bars: [(UInt8, UInt8, UInt8)] = [(0, 0, 191), (19, 19, 19), (191, 0, 191), (19, 19, 19),
                                                     (0, 191, 191), (19, 19, 19), (191, 191, 191)]
                return bars[min(6, x * 7 / w)]
            } else {
                let seg = x * 6 / w
                switch seg {
                case 0: return (0, 33, 76)
                case 1: return (235, 235, 235)
                case 2: return (50, 0, 106)
                default: return (16, 16, 16)
                }
            }
        default:
            var hex = spec
            if hex.hasPrefix("#") { hex.removeFirst() }
            if hex.count == 6, let v = UInt32(hex, radix: 16) {
                return (UInt8((v >> 16) & 0xFF), UInt8((v >> 8) & 0xFF), UInt8(v & 0xFF))
            }
            if hex.count == 8, let v = UInt32(hex, radix: 16) {
                return (UInt8((v >> 24) & 0xFF), UInt8((v >> 16) & 0xFF), UInt8((v >> 8) & 0xFF))
            }
            return (0, 0, 0)
        }
    }

    override func stop() {}
}

// MARK: - Still image (PNG with alpha works as an overlay / lower third)

final class ImageInput: InputSource {
    override var alphaPremultiplied: Bool { true }

    override func start() {
        let path = (config.imagePath as NSString).expandingTildeInPath
        guard let image = NSImage(contentsOfFile: path),
              let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            postStatus(Int32(MC_STATE_ERROR), L("이미지를 열 수 없음"))
            return
        }
        let w = cg.width, h = cg.height
        guard let pool = PixelBufferFactory.makePool(width: w, height: h, minimumCount: 1),
              let pb = PixelBufferFactory.makeBuffer(pool: pool) else { return }
        CVPixelBufferLockBaseAddress(pb, [])
        if let base = CVPixelBufferGetBaseAddress(pb) {
            memset(base, 0, CVPixelBufferGetBytesPerRow(pb) * h)
            let info = CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
            if let ctx = CGContext(data: base, width: w, height: h, bitsPerComponent: 8,
                                   bytesPerRow: CVPixelBufferGetBytesPerRow(pb),
                                   space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: info) {
                ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
            }
        }
        CVPixelBufferUnlockBaseAddress(pb, [])
        video.store(pb)
        postStatus(Int32(MC_STATE_RUNNING), "\(w)×\(h)")
    }

    override func stop() {}
}

// MARK: - Camera / UVC / capture devices via AVFoundation

/// AVFoundation delegates must be NSObjects; forwards samples to the owning CameraInput.
private final class CaptureDelegate: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate,
    AVCaptureAudioDataOutputSampleBufferDelegate {
    weak var owner: CameraInput?

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        owner?.handle(output: output, sampleBuffer: sampleBuffer)
    }

    /// Frames AVFoundation discarded because we were late (vMix "Source Dropped").
    func captureOutput(_ output: AVCaptureOutput, didDrop sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        owner?.video.countSourceDrop()
    }
}

final class CameraInput: InputSource {
    override init(config: InputConfig) {
        super.init(config: config)
        video.useNativeMonitorFrame = true
    }

    /// Like vMix's capture format selection: pick a ≤1080p format that runs at the program rate
    /// (or the closest lower one, e.g. 30 for 59.94) and lock the frame duration, so the camera
    /// doesn't slow down in low light (that causes periodic repeated frames = judder).
    static func lockFrameRate(_ dev: AVCaptureDevice, programFPS: Double) {
        let wanted = programFPS > 50 ? [programFPS, programFPS / 2] : [programFPS]
        var best: (AVCaptureDevice.Format, AVFrameRateRange, Double)?
        for want in wanted {
            for f in dev.formats {
                let d = CMVideoFormatDescriptionGetDimensions(f.formatDescription)
                guard d.width <= 1920, d.height <= 1080, d.width > d.height else { continue }
                for r in f.videoSupportedFrameRateRanges where r.maxFrameRate + 0.01 >= want && r.minFrameRate - 0.01 <= want {
                    let area = Double(d.width) * Double(d.height)
                    if best == nil || area > Double(CMVideoFormatDescriptionGetDimensions(best!.0.formatDescription).width) *
                        Double(CMVideoFormatDescriptionGetDimensions(best!.0.formatDescription).height) {
                        best = (f, r, want)
                    }
                }
            }
            if best != nil { break }
        }
        guard let (fmt, range, fps) = best, (try? dev.lockForConfiguration()) != nil else { return }
        dev.activeFormat = fmt
        // exact NTSC rates use 1001 timescales (29.97 = 1001/30000)
        let ntsc = abs(fps - fps.rounded()) > 0.01
        let dur = ntsc ? CMTime(value: 1001, timescale: CMTimeScale((fps * 1001).rounded()))
                       : CMTime(value: 1, timescale: CMTimeScale(fps.rounded()))
        // cameras usually only run exactly at their range maximum (e.g. 30 for a 29.97 program)
        let clamped = abs(range.maxFrameRate - fps) < 0.2 ? range.minFrameDuration
                                                          : max(range.minFrameDuration, min(range.maxFrameDuration, dur))
        dev.activeVideoMinFrameDuration = clamped
        dev.activeVideoMaxFrameDuration = clamped
        dev.unlockForConfiguration()
    }

    /// One selectable capture format: resolution + frame rate.
    struct FormatOption: Hashable {
        let width: Int32, height: Int32
        let fps: Double
        var value: String { "\(width)x\(height)@\(CameraInput.fpsString(fps))" }
        var label: String { "\(width)×\(height) · \(CameraInput.fpsString(fps)) fps" }
    }

    static func fpsString(_ f: Double) -> String {
        abs(f - f.rounded()) < 0.01 ? String(Int(f.rounded())) : String(format: "%.2f", f)
    }

    /// Formats the device offers (vMix-style list), biggest first, then fastest.
    static func formatOptions(_ deviceID: String) -> [FormatOption] {
        guard let dev = videoDevices().first(where: { $0.uniqueID == deviceID }) ?? AVCaptureDevice.default(for: .video) else { return [] }
        // NTSC rates (59.94/29.97) only where the device really runs them — many webcams only do whole
        // numbers and turn a 29.97 request into 29 fps.
        let common: [Double] = [120, 60, 50, 30, 25, 24, 15]
        var set = Set<FormatOption>()
        for f in dev.formats {
            let d = CMVideoFormatDescriptionGetDimensions(f.formatDescription)
            // landscape video formats only (phones/Center Stage also list portrait and square crops)
            guard d.width >= 320, d.width <= 4096, d.width > d.height else { continue }
            for r in f.videoSupportedFrameRateRanges {
                set.insert(FormatOption(width: d.width, height: d.height, fps: (r.maxFrameRate * 100).rounded() / 100))
                for c in common where c < r.maxFrameRate - 0.01 && c >= max(10, r.minFrameRate) - 0.01 {
                    set.insert(FormatOption(width: d.width, height: d.height, fps: c))
                }
            }
        }
        return set.sorted { a, b in
            let aa = Int(a.width) * Int(a.height), bb = Int(b.width) * Int(b.height)
            return aa != bb ? aa > bb : a.fps > b.fps
        }
    }

    /// Applies a manually chosen format ("1920x1080@29.97"). Returns false if the device can't do it.
    static func applyFormat(_ dev: AVCaptureDevice, _ value: String) -> Bool {
        let parts = value.split(separator: "@")
        guard parts.count == 2, let fps = Double(parts[1]) else { return false }
        let wh = parts[0].split(separator: "x")
        guard wh.count == 2, let w = Int32(wh[0]), let h = Int32(wh[1]) else { return false }
        for f in dev.formats {
            let d = CMVideoFormatDescriptionGetDimensions(f.formatDescription)
            guard d.width == w, d.height == h else { continue }
            for r in f.videoSupportedFrameRateRanges where r.maxFrameRate + 0.01 >= fps && r.minFrameRate - 0.01 <= fps {
                guard (try? dev.lockForConfiguration()) != nil else { return false }
                dev.activeFormat = f
                let ntsc = abs(fps - fps.rounded()) > 0.01
                let dur = abs(r.maxFrameRate - fps) < 0.1 ? r.minFrameDuration
                    : (ntsc ? CMTime(value: 1001, timescale: CMTimeScale((fps * 1001).rounded()))
                            : CMTime(value: 1, timescale: CMTimeScale(fps.rounded())))
                dev.activeVideoMinFrameDuration = dur
                dev.activeVideoMaxFrameDuration = dur
                dev.unlockForConfiguration()
                return true
            }
        }
        return false
    }

    private func applyCaptureFormat(_ dev: AVCaptureDevice) {
        if config.cameraFormat.isEmpty || !CameraInput.applyFormat(dev, config.cameraFormat) {
            CameraInput.lockFrameRate(dev, programFPS: VideoSlot.programFPS)
        }
    }

    private var session: AVCaptureSession?            // queue
    private let delegate = CaptureDelegate()
    private let queue = DispatchQueue(label: "camera.capture", qos: .userInteractive)
    /// Device watching: reopen when the camera / capture card / its audio device is plugged back in,
    /// unplugged, or the session fails — before, the input stayed dead until it was re-added.
    private let watch = CaptureDeviceWatch()
    private var active = false
    private var reopenPending = false                  // queue
    private var deviceLabel = ""
    private let audioQueue = DispatchQueue(label: "camera.audio", qos: .userInteractive)
    private var audioScratch = [Float]()

    static func videoDevices() -> [AVCaptureDevice] {
        AVCaptureDevice.DiscoverySession(deviceTypes: [.builtInWideAngleCamera, .external, .continuityCamera],
                                         mediaType: .video, position: .unspecified).devices
    }

    static func audioDevices() -> [AVCaptureDevice] {
        AVCaptureDevice.DiscoverySession(deviceTypes: [.microphone, .external],
                                         mediaType: .audio, position: .unspecified).devices
    }

    /// Best-effort pairing for cameras which publish video and audio as separate
    /// AVFoundation devices.  A built-in FaceTime camera belongs with the Mac's
    /// default microphone; Continuity Camera and USB capture devices are paired
    /// by model/name.  Returning nil is safer than silently using an unrelated mic.
    static func matchedAudioDevice(for video: AVCaptureDevice) -> AVCaptureDevice? {
        let devices = audioDevices()
        guard !devices.isEmpty else { return nil }

        if video.deviceType == .builtInWideAngleCamera {
            let builtIn = Int32(bitPattern: kAudioDeviceTransportTypeBuiltIn)
            return devices.first(where: { $0.transportType == builtIn })
                ?? devices.first(where: {
                    let n = $0.localizedName.lowercased()
                    return n.contains("macbook") || n.contains("built-in") || n.contains("내장")
                })
        }

        let normalized: (String) -> String = { name in
            let folded = name.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            let words = folded.components(separatedBy: CharacterSet.alphanumerics.inverted)
            let generic: Set<String> = ["camera", "video", "audio", "microphone", "mic", "카메라", "마이크", "데스크뷰", "deskview"]
            return words.filter { !$0.isEmpty && !generic.contains($0) }.joined(separator: " ")
        }

        let videoName = normalized(video.localizedName)
        var best: (device: AVCaptureDevice, score: Int)?
        for audio in devices {
            let audioName = normalized(audio.localizedName)
            var score = 0
            if !video.modelID.isEmpty && video.modelID == audio.modelID { score += 100 }
            if !videoName.isEmpty && videoName == audioName { score += 80 }
            if !videoName.isEmpty && !audioName.isEmpty,
               videoName.contains(audioName) || audioName.contains(videoName) { score += 50 }

            let videoWords = Set(videoName.split(separator: " ").map(String.init))
            let audioWords = Set(audioName.split(separator: " ").map(String.init))
            score += videoWords.intersection(audioWords).count * 15

            if best == nil || score > best!.score { best = (audio, score) }
        }
        return (best?.score ?? 0) >= 30 ? best?.device : nil
    }

    override func start() {
        guard queue.sync(execute: { session == nil }) else { return }
        active = true
        deviceLabel = name
        watch.start(ids: { [weak self] in
            guard let self = self else { return [] }
            return [self.config.cameraID, self.config.audioDeviceID].filter { !$0.isEmpty }
        }, onChange: { [weak self] in self?.reopen(after: 0.5) })
        AVCaptureDevice.requestAccess(for: .video) { granted in
            guard granted else {
                self.postStatus(Int32(MC_STATE_ERROR), L("카메라 권한이 거부됨 (시스템 설정 > 개인정보 보호)"))
                return
            }
            if self.config.audioDeviceID.isEmpty {
                self.queue.async { self.configureSession() }
            } else {
                AVCaptureDevice.requestAccess(for: .audio) { _ in
                    self.queue.async { self.configureSession() }
                }
            }
        }
    }

    /// Rebuild the session on the capture queue (coalesced).
    private func reopen(after delay: Double) {
        queue.async {
            guard self.active, !self.reopenPending else { return }
            self.reopenPending = true
            self.queue.asyncAfter(deadline: .now() + delay) {
                self.reopenPending = false
                guard self.active else { return }
                if let s = self.session {
                    s.stopRunning()
                    self.session = nil
                }
                self.configureSession()
            }
        }
    }

    private func configureSession() {
        guard active, session == nil else { return }
        delegate.owner = self
        let s = AVCaptureSession()
        s.beginConfiguration()
        // A chosen device that isn't connected must NOT fall back to the default camera (that put the
        // MacBook's FaceTime camera on air when a capture card was missing). Only an input that never
        // picked a device uses the default one.
        let device = config.cameraID.isEmpty
            ? AVCaptureDevice.default(for: .video)
            : CameraInput.videoDevices().first(where: { $0.uniqueID == config.cameraID })
        guard let dev = device else {
            s.commitConfiguration()
            postStatus(Int32(MC_STATE_ERROR), Lf("장치가 연결되지 않음: %@ — 연결되면 자동으로 다시 엽니다", deviceLabel))
            return
        }
        guard let input = try? AVCaptureDeviceInput(device: dev), s.canAddInput(input) else {
            s.commitConfiguration()
            postStatus(Int32(MC_STATE_ERROR), L("카메라를 열 수 없음 — 다시 시도 중"))
            reopen(after: 3)
            return
        }
        s.addInput(input)
        applyCaptureFormat(dev)
        let out = AVCaptureVideoDataOutput()
        // The camera's native YUV (no conversion; the mixer reads NV12 directly). Fall back to BGRA if unsupported.
        let native = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        let fmt = out.availableVideoPixelFormatTypes.contains(native) ? native : kCVPixelFormatType_32BGRA
        out.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: fmt,
                             kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any]()]
        out.alwaysDiscardsLateVideoFrames = true
        out.setSampleBufferDelegate(delegate, queue: queue)
        if s.canAddOutput(out) { s.addOutput(out) }

        var matchedAudioName: String?
        if !config.audioDeviceID.isEmpty,
           let adev = CameraInput.audioDevices().first(where: { $0.uniqueID == config.audioDeviceID }),
           let ain = try? AVCaptureDeviceInput(device: adev), s.canAddInput(ain) {
            s.addInput(ain)
            let aout = AVCaptureAudioDataOutput()
            aout.audioSettings = [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVSampleRateKey: 48000,
                AVNumberOfChannelsKey: 2,
                AVLinearPCMBitDepthKey: 32,
                AVLinearPCMIsFloatKey: true,
                AVLinearPCMIsNonInterleaved: false,
                AVLinearPCMIsBigEndianKey: false,
            ]
            aout.setSampleBufferDelegate(delegate, queue: audioQueue)
            if s.canAddOutput(aout) {
                s.addOutput(aout)
                matchedAudioName = adev.localizedName
                noteAudioTrack(true)
            }
        }
        s.commitConfiguration()
        s.startRunning()
        // the session may re-apply its own frame rate when it starts: lock it again
        applyCaptureFormat(dev)
        session = s
        watch.watch(session: s) { [weak self] in
            self?.postStatus(Int32(MC_STATE_ERROR), L("카메라 세션 오류 — 다시 여는 중"))
            self?.reopen(after: 1)
        }
        let d = CMVideoFormatDescriptionGetDimensions(dev.activeFormat.formatDescription)
        let fps = dev.activeVideoMinFrameDuration.seconds > 0 ? 1 / dev.activeVideoMinFrameDuration.seconds : 0
        let audioStatus = matchedAudioName.map { Lf(" · 오디오: %@", $0) } ?? L(" · 오디오 없음")
        postStatus(Int32(MC_STATE_RUNNING), String(format: L("%@ · %d×%d %.2f fps 고정"), dev.localizedName, d.width, d.height, fps)
                   + (config.cameraFormat.isEmpty ? L(" (자동)") : "") + audioStatus)
    }

    override func stop() {
        active = false
        watch.stop()
        queue.sync {
            session?.stopRunning()
            session = nil
        }
        video.clear()
        audio.clear()
    }

    fileprivate func handle(output: AVCaptureOutput, sampleBuffer: CMSampleBuffer) {
        if output is AVCaptureVideoDataOutput {
            if let pb = CMSampleBufferGetImageBuffer(sampleBuffer) { video.store(pb) }
            return
        }
        guard let block = CMSampleBufferGetDataBuffer(sampleBuffer) else { return }
        let frames = CMSampleBufferGetNumSamples(sampleBuffer)
        guard frames > 0 else { return }
        let bytes = CMBlockBufferGetDataLength(block)
        let floats = bytes / MemoryLayout<Float>.size
        if audioScratch.count < floats { audioScratch = [Float](repeating: 0, count: floats) }
        audioScratch.withUnsafeMutableBytes { raw in
            guard let base = raw.baseAddress else { return }
            if CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: bytes, destination: base) == kCMBlockBufferNoErr {
                let n = min(frames, floats / 2)
                audio.write(base.assumingMemoryBound(to: Float.self), frames: n)
                noteAudioFrame()
            }
        }
    }
}

/// Watches the capture devices of one input (connect / disconnect) and its session's runtime errors.
final class CaptureDeviceWatch {
    private let lock = NSLock()
    private var tokens: [NSObjectProtocol] = []
    private var sessionToken: NSObjectProtocol?

    func start(ids: @escaping () -> [String], onChange: @escaping () -> Void) {
        lock.lock(); defer { lock.unlock() }
        guard tokens.isEmpty else { return }
        let handler: (Notification) -> Void = { n in
            guard let d = n.object as? AVCaptureDevice, ids().contains(d.uniqueID) else { return }
            onChange()
        }
        let nc = NotificationCenter.default
        for name in [AVCaptureDevice.wasConnectedNotification, AVCaptureDevice.wasDisconnectedNotification] {
            tokens.append(nc.addObserver(forName: name, object: nil, queue: nil, using: handler))
        }
    }

    func watch(session: AVCaptureSession?, onError: @escaping () -> Void) {
        lock.lock(); defer { lock.unlock() }
        if let t = sessionToken { NotificationCenter.default.removeObserver(t) }
        sessionToken = session.map {
            NotificationCenter.default.addObserver(forName: AVCaptureSession.runtimeErrorNotification, object: $0,
                                                   queue: nil) { _ in onError() }
        }
    }

    func stop() {
        lock.lock(); defer { lock.unlock() }
        tokens.forEach { NotificationCenter.default.removeObserver($0) }
        tokens = []
        if let t = sessionToken { NotificationCenter.default.removeObserver(t) }
        sessionToken = nil
    }
}
