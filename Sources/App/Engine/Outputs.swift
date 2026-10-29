import Foundation
import CoreVideo

enum OutputKind: String, Codable, CaseIterable {
    case stream, record, ndi, decklink

    var label: String {
        switch self {
        case .stream: return L("스트리밍 (RTMP/SRT)")
        case .record: return L("녹화")
        case .ndi: return L("NDI 출력")
        case .decklink: return L("DeckLink 출력")
        }
    }

    var symbol: String {
        switch self {
        case .stream: return "dot.radiowaves.up.forward"
        case .record: return "record.circle"
        case .ndi: return "network"
        case .decklink: return "cable.connector"
        }
    }
}

enum StreamProtocol: String, Codable, CaseIterable {
    case rtmp, srt, custom

    var label: String {
        switch self {
        case .rtmp: return "RTMP/RTMPS"
        case .srt: return "SRT"
        case .custom: return L("직접 입력 URL")
        }
    }
}

struct OutputConfig: Codable, Identifiable, Equatable {
    var id = UUID()
    var kind: OutputKind
    var name: String

    // streaming
    var proto: StreamProtocol = .rtmp
    var rtmpServer: String = "rtmp://a.rtmp.youtube.com/live2"
    var streamKey: String = ""
    var srtHost: String = ""
    var srtPort: Int = 9000
    var srtMode: String = "caller"     // caller | listener
    var srtLatencyMs: Int = 200
    var srtPassphrase: String = ""
    var srtStreamID: String = ""
    var customURL: String = ""

    // encoding (stream + record)
    var videoCodec: String = "h264"    // h264 | hevc | prores
    var videoKbps: Int = 6000
    var audioKbps: Int = 160
    var keyintSeconds: Double = 2
    var hardwareEncoder: Bool = true

    // recording
    var recordFolder: String = "~/Movies/BraceletMix"
    var recordContainer: String = "mov"  // mov | mp4 | ts
    var splitMinutes: Int = 0             // "New file every" (0 = off)

    // NDI
    var ndiName: String = "HongMix Program"

    // DeckLink
    var deckLinkIndex: Int = 0

    // routing
    var bus: Int = 1                     // video: Output 1…4
    var audioBus: String = "M"           // audio: M or A…G
    var rtmpUsername: String = ""
    var rtmpPassword: String = ""
    /// Broadcast delay (stream/record): seconds the encoded output is held back (0 = live)
    var delaySeconds: Int = 0
    /// Multitrack recording: extra audio tracks after track 1 (e.g. "AB" = track 2 Bus A, track 3 Bus B; "M" allowed)
    var extraAudioBuses: String = ""
    /// Return feed to the field (runs on its own — not started/stopped by the Stream button)
    var returnFeed = false

    var extraBusIndices: [Int] {
        extraAudioBuses.uppercased().compactMap { AudioBus.index(String($0)) }.prefix(8).map { $0 }
    }

    static func defaultConfig(kind: OutputKind) -> OutputConfig {
        switch kind {
        case .stream: return OutputConfig(kind: .stream, name: L("스트림"))
        case .record: return OutputConfig(kind: .record, name: L("녹화"), videoKbps: 30000)
        case .ndi: return OutputConfig(kind: .ndi, name: "NDI")
        case .decklink: return OutputConfig(kind: .decklink, name: "DeckLink")
        }
    }

    /// The FFmpeg URL for stream outputs.
    func streamURL() -> String {
        switch proto {
        case .rtmp:
            var server = rtmpServer.trimmingCharacters(in: .whitespacesAndNewlines)
            if !rtmpUsername.isEmpty, let schemeEnd = server.range(of: "://") {
                let user = rtmpUsername.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? rtmpUsername
                let pass = rtmpPassword.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? rtmpPassword
                server.insert(contentsOf: "\(user):\(pass)@", at: schemeEnd.upperBound)
            }
            let key = streamKey.trimmingCharacters(in: .whitespacesAndNewlines)
            if key.isEmpty { return server }
            if server.hasSuffix("/") { server.removeLast() }
            return server + "/" + key
        case .srt:
            let host = srtHost.isEmpty ? (srtMode == "listener" ? "0.0.0.0" : "127.0.0.1") : srtHost
            var url = "srt://\(host):\(srtPort)?mode=\(srtMode)&latency=\(srtLatencyMs * 1000)&pkt_size=1316"
            if !srtPassphrase.isEmpty {
                url += "&passphrase=" + (srtPassphrase.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? "")
            }
            if !srtStreamID.isEmpty {
                url += "&streamid=" + (srtStreamID.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? "")
            }
            return url
        case .custom:
            return customURL.trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }
}

extension OutputConfig {
    // Tolerant decoding: older project files may miss newer keys.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try c.decode(OutputKind.self, forKey: .kind)
        var d = OutputConfig.defaultConfig(kind: kind)
        d.id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? d.id
        d.name = try c.decodeIfPresent(String.self, forKey: .name) ?? d.name
        d.proto = try c.decodeIfPresent(StreamProtocol.self, forKey: .proto) ?? d.proto
        d.rtmpServer = try c.decodeIfPresent(String.self, forKey: .rtmpServer) ?? d.rtmpServer
        d.streamKey = try c.decodeIfPresent(String.self, forKey: .streamKey) ?? d.streamKey
        d.srtHost = try c.decodeIfPresent(String.self, forKey: .srtHost) ?? d.srtHost
        d.srtPort = try c.decodeIfPresent(Int.self, forKey: .srtPort) ?? d.srtPort
        d.srtMode = try c.decodeIfPresent(String.self, forKey: .srtMode) ?? d.srtMode
        d.srtLatencyMs = try c.decodeIfPresent(Int.self, forKey: .srtLatencyMs) ?? d.srtLatencyMs
        d.srtPassphrase = try c.decodeIfPresent(String.self, forKey: .srtPassphrase) ?? d.srtPassphrase
        d.srtStreamID = try c.decodeIfPresent(String.self, forKey: .srtStreamID) ?? d.srtStreamID
        d.customURL = try c.decodeIfPresent(String.self, forKey: .customURL) ?? d.customURL
        d.videoCodec = try c.decodeIfPresent(String.self, forKey: .videoCodec) ?? d.videoCodec
        d.videoKbps = try c.decodeIfPresent(Int.self, forKey: .videoKbps) ?? d.videoKbps
        d.audioKbps = try c.decodeIfPresent(Int.self, forKey: .audioKbps) ?? d.audioKbps
        d.keyintSeconds = try c.decodeIfPresent(Double.self, forKey: .keyintSeconds) ?? d.keyintSeconds
        d.hardwareEncoder = try c.decodeIfPresent(Bool.self, forKey: .hardwareEncoder) ?? d.hardwareEncoder
        d.recordFolder = try c.decodeIfPresent(String.self, forKey: .recordFolder) ?? d.recordFolder
        d.recordContainer = try c.decodeIfPresent(String.self, forKey: .recordContainer) ?? d.recordContainer
        d.ndiName = try c.decodeIfPresent(String.self, forKey: .ndiName) ?? d.ndiName
        d.deckLinkIndex = try c.decodeIfPresent(Int.self, forKey: .deckLinkIndex) ?? d.deckLinkIndex
        d.bus = c.value(.bus, d.bus)
        d.splitMinutes = c.value(.splitMinutes, d.splitMinutes)
        d.audioBus = c.value(.audioBus, d.audioBus)
        d.rtmpUsername = c.value(.rtmpUsername, d.rtmpUsername)
        d.rtmpPassword = c.value(.rtmpPassword, d.rtmpPassword)
        d.delaySeconds = c.value(.delaySeconds, d.delaySeconds)
        d.extraAudioBuses = c.value(.extraAudioBuses, d.extraAudioBuses)
        d.returnFeed = c.value(.returnFeed, d.returnFeed)
        self = d
    }
}

/// One running (or idle) output destination.
final class OutputChannel: ObservableObject, Identifiable {
    let id: UUID
    @Published var config: OutputConfig {
        didSet { syncRouting() }
    }
    @Published private(set) var running = false
    @Published private(set) var state: Int32 = Int32(MC_STATE_IDLE)
    @Published private(set) var message: String = ""
    @Published private(set) var statsText: String = ""
    @Published private(set) var lastFile: String = ""
    /// Latest encoder bitrate (not published — read by the health history every second).
    private(set) var lastKbps: Double = 0
    /// Broadcast delay currently held back (ms), from the encoder thread.
    @Published private(set) var delayBufferedMs: Int = 0
    @Published private(set) var delayDumped = false

    /// Throw the delayed part away and go live (profanity/accident button).
    func dumpDelay() {
        lock.lock(); let f = ffOut; lock.unlock()
        if let f = f { mc_output_dump_delay(f); delayDumped = true }
    }

    private let lock = NSLock()
    private var ffOut: OpaquePointer?
    private var ndiOut: OpaquePointer?
    private var dlOut: OpaquePointer?
    private var format = VideoFormat.defaultFormat
    private var startedAt = Date()

    init(config: OutputConfig) {
        self.id = config.id
        self.config = config
        syncRouting()
    }

    var isActiveForTally: Bool { running }

    /// Thread-safe: an encoder/sender is attached (render thread uses this to decide what to render).
    var hasHandle: Bool {
        lock.lock()
        defer { lock.unlock() }
        return ffOut != nil || ndiOut != nil || dlOut != nil
    }

    /// Render-thread copy of the routing (updated from the main thread).
    private var routingStore: (bus: Int, audioBus: Int, extra: [Int]) = (1, 0, [])
    var routing: (bus: Int, audioBus: Int, extra: [Int]) {
        lock.lock()
        defer { lock.unlock() }
        return routingStore
    }

    func syncRouting() {
        let r = (max(1, min(4, config.bus)), AudioBus.index(config.audioBus) ?? 0,
                 config.kind == .record ? config.extraBusIndices : [])
        lock.lock()
        routingStore = r
        lock.unlock()
    }

    /// Starts the output. Returns an error message on failure.
    @discardableResult
    func start(format: VideoFormat) -> String? {
        if running { return nil }
        self.format = format
        syncRouting()
        let c = config
        switch c.kind {
        case .stream, .record:
            var url: String
            var container: String? = nil
            if c.kind == .stream {
                url = c.streamURL()
                if url.isEmpty { return fail(L("스트림 주소가 비어 있음")) }
            } else {
                let folder = (c.recordFolder as NSString).expandingTildeInPath
                do {
                    try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
                } catch {
                    return fail(Lf("녹화 폴더를 만들 수 없음: %@", "\(folder)"))
                }
                let df = DateFormatter()
                df.dateFormat = "yyyyMMdd_HHmmss"
                var ext = c.recordContainer
                if c.videoCodec == "prores" { ext = "mov" }
                url = (folder as NSString).appendingPathComponent("HongMix_\(df.string(from: Date())).\(ext)")
                container = ext == "ts" ? "mpegts" : (ext == "mp4" ? "mp4" : "mov")
                lastFile = url
            }
            var cfg = mc_output_config()
            cfg.width = Int32(format.width)
            cfg.height = Int32(format.height)
            cfg.fps_num = Int32(format.fpsNum)
            cfg.fps_den = Int32(format.fpsDen)
            cfg.video_kbps = Int32(c.videoKbps)
            cfg.audio_kbps = Int32(c.audioKbps)
            cfg.keyint_frames = Int32(max(1.0, (c.keyintSeconds * format.fps).rounded()))
            cfg.reconnect = c.kind == .stream ? 1 : 0
            cfg.hardware = c.hardwareEncoder ? 1 : 0
            cfg.pixelbuffer_input = 1
            cfg.delay_ms = Int32(max(0, min(3600, c.delaySeconds)) * 1000)
            cfg.extra_audio_tracks = c.kind == .record ? Int32(c.extraBusIndices.count) : 0
            let uPtr = strdup(url)
            let fPtr: UnsafeMutablePointer<CChar>? = container != nil ? strdup(container!) : nil
            let vPtr = strdup(c.videoCodec)
            defer {
                free(uPtr)
                free(fPtr)
                free(vPtr)
            }
            cfg.url = UnsafePointer(uPtr)
            cfg.format = UnsafePointer(fPtr)
            cfg.video_codec = UnsafePointer(vPtr)
            let user = Unmanaged.passUnretained(self).toOpaque()
            let handle = mc_output_open(&cfg, { user, state, msg in
                guard let user = user else { return }
                let me = Unmanaged<OutputChannel>.fromOpaque(user).takeUnretainedValue()
                let text = msg.map { String(cString: $0) } ?? ""
                DispatchQueue.main.async {
                    guard me.running else { return }  // ignore late messages after stop()
                    me.state = state
                    me.message = text
                }
            }, user)
            guard let h = handle else { return fail(L("출력을 시작할 수 없음")) }
            lock.lock()
            ffOut = h
            lock.unlock()
        case .ndi:
            guard mc_ndi_available() != 0 else { return fail(L("NDI 런타임이 설치되어 있지 않음")) }
            guard let h = mc_ndi_send_open(c.ndiName, Int32(format.fpsNum), Int32(format.fpsDen)) else {
                return fail(L("NDI 송신기를 만들 수 없음"))
            }
            lock.lock()
            ndiOut = h
            lock.unlock()
            state = Int32(MC_STATE_RUNNING)
            message = Lf("NDI 송출 중: %@", "\(c.ndiName)")
        case .decklink:
            var err = [CChar](repeating: 0, count: 256)
            guard let h = mc_decklink_out_open(Int32(c.deckLinkIndex), Int32(format.width), Int32(format.height),
                                               Int32(format.fpsNum), Int32(format.fpsDen), &err, Int32(err.count)) else {
                return fail(String(cString: err))
            }
            lock.lock()
            dlOut = h
            lock.unlock()
            state = Int32(MC_STATE_RUNNING)
            message = L("DeckLink 출력 중")
        }
        running = true
        delayDumped = false
        startedAt = Date()
        return nil
    }

    private func fail(_ msg: String) -> String {
        state = Int32(MC_STATE_ERROR)
        message = msg
        return msg
    }

    func stop(waitForClose: Bool = false) {
        lock.lock()
        let f = ffOut, n = ndiOut, d = dlOut
        ffOut = nil
        ndiOut = nil
        dlOut = nil
        lock.unlock()
        // Closing can take a moment (flush + trailer); do it off the main thread for streams,
        // but synchronously enough that the handles are gone before we report "stopped".
        if let f = f, waitForClose {
            mc_output_close(f)
        } else if let f = f {
            DispatchQueue.global(qos: .userInitiated).async {
                mc_output_close(f)
                _ = self  // keep the callback target alive until the worker has exited
            }
        }
        if let n = n { mc_ndi_send_close(n) }
        if let d = d { mc_decklink_out_close(d) }
        running = false
        state = Int32(MC_STATE_STOPPED)
        message = config.kind == .record && !lastFile.isEmpty ? Lf("저장됨: %@", "\((lastFile as NSString).lastPathComponent)") : L("중지됨")
        statsText = ""
    }

    /// Render thread: push one program frame. Encoders get the IOSurface itself (zero copy);
    /// only NDI / DeckLink read the pixels on the CPU.
    func pushVideo(_ frame: CVPixelBuffer, width: Int, height: Int, tick: Int64) {
        lock.lock()
        if let f = ffOut {
            mc_output_push_pixelbuffer(f, Unmanaged.passUnretained(frame).toOpaque(), tick)
        }
        if ndiOut != nil || dlOut != nil {
            CVPixelBufferLockBaseAddress(frame, .readOnly)
            if let raw = CVPixelBufferGetBaseAddress(frame) {
                let base = UnsafePointer(raw.assumingMemoryBound(to: UInt8.self))
                let stride = CVPixelBufferGetBytesPerRow(frame)
                if let n = ndiOut { mc_ndi_send_video(n, base, Int32(width), Int32(height), Int32(stride)) }
                if let d = dlOut { mc_decklink_out_video(d, base, Int32(stride)) }
            }
            CVPixelBufferUnlockBaseAddress(frame, .readOnly)
        }
        lock.unlock()
    }

    /// Render thread: push the master audio for this tick.
    func pushAudio(_ samples: UnsafePointer<Float>, extra: [UnsafePointer<Float>?] = [], frames: Int) {
        lock.lock()
        if let f = ffOut {
            if extra.isEmpty { mc_output_push_audio(f, samples, Int32(frames)) } else {
                extra.withUnsafeBufferPointer { b in
                    mc_output_push_audio_tracks(f, samples, b.baseAddress, Int32(b.count), Int32(frames))
                }
            }
        }
        if let n = ndiOut { mc_ndi_send_audio(n, samples, Int32(frames)) }
        if let d = dlOut { mc_decklink_out_audio(d, samples, Int32(frames)) }
        lock.unlock()
    }

    /// Main thread, ~1 Hz.
    func srtStats() -> SRTStats? {
        lock.lock()
        defer { lock.unlock() }
        guard let f = ffOut else { return nil }
        var st = mc_srt_stats()
        return mc_output_srt_stats(f, &st) != 0 ? SRTStats(st) : nil
    }

    func refreshStats() {
        guard running else { return }
        if config.kind == .record && config.splitMinutes > 0 &&
            Date().timeIntervalSince(startedAt) >= Double(config.splitMinutes) * 60 {
            // "New file every N minutes": close this file and continue in a new one
            stop()
            start(format: format)
            return
        }
        lock.lock()
        let f = ffOut, n = ndiOut
        var st = mc_output_stats()
        if let f = f { mc_output_get_stats(f, &st) }
        let conns = n.map { mc_ndi_send_connections($0) } ?? 0
        lock.unlock()
        if f != nil {
            let enc = withUnsafePointer(to: &st.encoder) {
                $0.withMemoryRebound(to: CChar.self, capacity: 48) { String(cString: $0) }
            }
            let mb = Double(st.bytes_written) / 1_000_000
            lastKbps = st.kbps
            if delayBufferedMs != Int(st.delay_buffered_ms) { delayBufferedMs = Int(st.delay_buffered_ms) }
            statsText = String(format: L("%@ · %.0f kbps · %.1f MB · 드롭 %lld"), enc, st.kbps, mb, st.frames_dropped)
        } else if n != nil {
            statsText = Lf("연결된 수신기 %@", "\(conns)")
        }
    }
}


/// Swift view of `mc_srt_stats` (vMix SRT statistics window).
struct SRTStats {
    var connected: Bool
    var isSender: Bool
    var rttMs: Double
    var bandwidthMbps: Double
    var rateMbps: Double
    var packets: Int64
    var lost: Int64
    var retransmitted: Int64
    var dropped: Int64
    var lossPercent: Double
    var bufferMs: Int
    var latencyMs: Int
    var peer: String
    var mode: String

    init(_ s: mc_srt_stats) {
        connected = s.connected != 0
        isSender = s.is_sender != 0
        rttMs = s.rtt_ms
        bandwidthMbps = s.bandwidth_mbps
        rateMbps = s.rate_mbps
        packets = s.pkts
        lost = s.lost
        retransmitted = s.retransmitted
        dropped = s.dropped
        lossPercent = s.loss_percent
        bufferMs = Int(s.buffer_ms)
        latencyMs = Int(s.latency_ms)
        var p = s.peer
        peer = withUnsafePointer(to: &p) { $0.withMemoryRebound(to: CChar.self, capacity: 64) { String(cString: $0) } }
        var m = s.mode
        mode = withUnsafePointer(to: &m) { $0.withMemoryRebound(to: CChar.self, capacity: 16) { String(cString: $0) } }
    }

    /// Simple health rating for the UI: rtt/loss/drops vs the configured latency.
    var health: Int {   // 0 good, 1 warning, 2 bad
        if dropped > 0 && lossPercent > 1 { return 2 }
        if Double(latencyMs) > 0 && rttMs * 4 > Double(latencyMs) { return 1 }   // SRT wants latency ≥ 4×RTT
        if lossPercent > 0.5 { return 1 }
        return 0
    }
}
