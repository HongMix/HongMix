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
    var recordFolder: String = "~/Movies/HongMix"
    var recordContainer: String = "mov"  // mov | mp4 | ts
    var splitMinutes: Int = 0             // "New file every" (0 = off)

    // NDI
    var ndiName: String = "HongMix Program"

    // DeckLink
    var deckLinkIndex: Int = 0
    /// Fill & Key through the card's external keyer (fill SDI A + key SDI B)
    var deckLinkKey = false
    /// "none", "straight", or "premultiplied".  deckLinkKey is retained for old project files.
    var deckLinkAlphaMode: String = "none"

    // routing
    var bus: Int = 1                     // video: Output 1…4
    var audioBus: String = "M"           // audio: M or A…G
    var rtmpUsername: String = ""
    var rtmpPassword: String = ""
    /// Broadcast delay (stream/record): seconds the encoded output is held back (0 = live)
    var delaySeconds: Int = 0
    /// Where the delay is held: "auto" (RAM up to 1 min, disk above), "memory", "disk"
    var delayStorage: String = "auto"
    /// Disk buffer folder for the delay ("" = ~/Library/Caches/HongMix/DelayBuffer)
    var delayFolder: String = ""
    /// Multitrack recording: extra audio tracks after track 1 (e.g. "AB" = track 2 Bus A, track 3 Bus B; "M" allowed)
    var extraAudioBuses: String = ""
    /// Return feed to the field (runs on its own — not started/stopped by the Stream button)
    var returnFeed = false
    /// Backup recording: the same encoded packets also go to a file of the same name in this folder
    /// (meant for a second disk; no second encode). "" = off.
    var backupFolder: String = ""
    /// Continue recording on another disk (spillFolder, else backupFolder) when the record disk fills or fails.
    var spillToBackupWhenFull = false
    /// Where to continue when the record disk is full ("" = the backup folder).
    var spillFolder: String = ""

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
        d.recordFolder = DefaultsMigration.modernize(try c.decodeIfPresent(String.self, forKey: .recordFolder) ?? d.recordFolder)
        d.recordContainer = try c.decodeIfPresent(String.self, forKey: .recordContainer) ?? d.recordContainer
        d.ndiName = try c.decodeIfPresent(String.self, forKey: .ndiName) ?? d.ndiName
        d.deckLinkIndex = try c.decodeIfPresent(Int.self, forKey: .deckLinkIndex) ?? d.deckLinkIndex
        d.deckLinkKey = c.value(.deckLinkKey, d.deckLinkKey)
        d.deckLinkAlphaMode = c.value(.deckLinkAlphaMode,
                                      d.deckLinkKey ? "premultiplied" : d.deckLinkAlphaMode)
        d.bus = c.value(.bus, d.bus)
        d.splitMinutes = c.value(.splitMinutes, d.splitMinutes)
        d.audioBus = c.value(.audioBus, d.audioBus)
        d.rtmpUsername = c.value(.rtmpUsername, d.rtmpUsername)
        d.rtmpPassword = c.value(.rtmpPassword, d.rtmpPassword)
        d.delaySeconds = c.value(.delaySeconds, d.delaySeconds)
        d.delayStorage = c.value(.delayStorage, d.delayStorage)
        d.delayFolder = c.value(.delayFolder, d.delayFolder)
        d.extraAudioBuses = c.value(.extraAudioBuses, d.extraAudioBuses)
        d.returnFeed = c.value(.returnFeed, d.returnFeed)
        d.backupFolder = c.value(.backupFolder, d.backupFolder)
        d.spillToBackupWhenFull = c.value(.spillToBackupWhenFull, d.spillToBackupWhenFull)
        d.spillFolder = c.value(.spillFolder, d.spillFolder)
        self = d
    }
}

// MARK: - Broadcast delay storage (RAM / disk)
extension OutputConfig {
    static let maxDelaySeconds = 6 * 3600

    static var defaultDelayFolder: String {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?.path
            ?? (NSHomeDirectory() as NSString).appendingPathComponent("Library/Caches")
        return (caches as NSString).appendingPathComponent("HongMix/DelayBuffer")
    }

    var delayFolderPath: String {
        ((delayFolder.isEmpty ? OutputConfig.defaultDelayFolder : delayFolder) as NSString).expandingTildeInPath
    }

    var effectiveDelaySeconds: Int { max(0, min(OutputConfig.maxDelaySeconds, delaySeconds)) }

    /// The delay goes to disk ("auto": anything longer than a minute).
    var delayUsesDisk: Bool {
        guard effectiveDelaySeconds > 0 else { return false }
        switch delayStorage {
        case "memory": return false
        case "disk": return true
        default: return effectiveDelaySeconds > 60
        }
    }

    /// Bytes per second of the encoded output (video + all audio tracks).
    func encodedBytesPerSecond(format: VideoFormat) -> Double {
        var videoBits = Double(videoKbps) * 1000
        if videoCodec == "prores" {   // ProRes 422 ≈ 147 Mbit/s at 1080p29.97 → scale by pixels × fps
            videoBits = 147_000_000 * Double(format.width * format.height) / (1920 * 1080) * format.fps / 29.97
        }
        let tracks = 1 + (kind == .record ? extraBusIndices.count : 0)
        return (videoBits + Double(audioKbps * 1000 * tracks)) / 8
    }

    /// Space the delay needs (10 % container/burst margin).
    func delayBytesNeeded(format: VideoFormat) -> Int64 {
        Int64(encodedBytesPerSecond(format: format) * Double(effectiveDelaySeconds) * 1.1)
    }

    /// Free space on the volume holding `path` (walks up to the nearest existing folder).
    static func freeSpace(at path: String) -> Int64? {
        var p = path
        let fm = FileManager.default
        while !fm.fileExists(atPath: p), p != "/" { p = (p as NSString).deletingLastPathComponent }
        let v = try? URL(fileURLWithPath: p).resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey,
                                                                      .volumeAvailableCapacityKey])
        if let x = v?.volumeAvailableCapacityForImportantUsage, x > 0 { return x }
        return v?.volumeAvailableCapacity.map(Int64.init)
    }

    static func bytesText(_ b: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: b, countStyle: .file)
    }

    /// One-line summary for the settings screen: storage, space needed, free space, hours that would fit.
    func delaySummary(format: VideoFormat) -> String {
        let need = delayBytesNeeded(format: format)
        guard delayUsesDisk else {
            return Lf("메모리에 보관 · 약 %@ 사용", OutputConfig.bytesText(need))
        }
        let free = OutputConfig.freeSpace(at: delayFolderPath) ?? 0
        let perHour = encodedBytesPerSecond(format: format) * 3600 * 1.1
        let hours = perHour > 0 ? Double(free) / perHour : 0
        var text = Lf("디스크에 보관 · 필요 %@ · 남은 공간 %@ (이 비트레이트로 최대 약 %@시간)",
                      OutputConfig.bytesText(need), OutputConfig.bytesText(free), String(format: "%.1f", hours))
        if free < need + OutputConfig.delayDiskReserve { text += " — " + L("공간 부족!") }
        return text
    }

    /// Free space we never use (keeps macOS and recordings alive).
    static let delayDiskReserve: Int64 = 2_000_000_000

    /// Removes disk buffers left behind by a previous run that did not stop cleanly.
    static func cleanupStaleDelayBuffers(in folder: String) {
        let fm = FileManager.default
        let mine = "HongMix-delay-\(ProcessInfo.processInfo.processIdentifier)-"
        guard let items = try? fm.contentsOfDirectory(atPath: folder) else { return }
        for it in items where it.hasPrefix("HongMix-delay-") && !it.hasPrefix(mine) {
            try? fm.removeItem(atPath: (folder as NSString).appendingPathComponent(it))
        }
    }
}

// MARK: - Recording safety (backup recording, continue on another disk, disk time left)
extension OutputConfig {
    /// Free space kept when continuing on another disk: below this the recording moves to the spill disk.
    static let recordDiskReserve: Int64 = 2_000_000_000

    var backupFolderPath: String? {
        let f = backupFolder.trimmingCharacters(in: .whitespacesAndNewlines)
        return kind == .record && !f.isEmpty ? (f as NSString).expandingTildeInPath : nil
    }

    /// Folder the recording continues in when its disk is full (nil = off).
    var spillFolderPath: String? {
        guard kind == .record, spillToBackupWhenFull else { return nil }
        let f = spillFolder.trimmingCharacters(in: .whitespacesAndNewlines)
        if !f.isEmpty { return (f as NSString).expandingTildeInPath }
        return backupFolderPath
    }

    /// Estimated bytes/s before a measurement exists (ProRes profiles scaled from ProRes 422).
    func estimatedRecordBytesPerSecond(format: VideoFormat) -> Double {
        guard videoCodec.hasPrefix("prores"), videoCodec != "prores" else { return encodedBytesPerSecond(format: format) }
        var c = self
        c.videoCodec = "prores"
        let scale: Double = videoCodec == "prores_proxy" ? 0.31 : videoCodec == "prores_lt" ? 0.69 : videoCodec == "prores_hq" ? 1.5 : 1
        return c.encodedBytesPerSecond(format: format) * scale
    }
}

/// Disk helpers for the recording-safety estimate (real free space, not "purgeable" space: a recording
/// fails when the volume is really full).
enum RecordDisk {
    /// Nearest existing folder for a file or folder path.
    static func existingFolder(_ path: String) -> String {
        var p = path
        var isDir: ObjCBool = false
        let fm = FileManager.default
        if fm.fileExists(atPath: p, isDirectory: &isDir), isDir.boolValue { return p }
        p = (p as NSString).deletingLastPathComponent
        while !p.isEmpty, p != "/", !fm.fileExists(atPath: p) { p = (p as NSString).deletingLastPathComponent }
        return p.isEmpty ? "/" : p
    }

    static func freeBytes(_ path: String) -> Int64? {
        var st = statfs()
        guard statfs(existingFolder(path), &st) == 0 else { return nil }
        return Int64(st.f_bavail) * Int64(st.f_bsize)
    }

    static func volumeID(_ path: String) -> UInt64? {
        var sb = stat()
        guard stat(existingFolder(path), &sb) == 0 else { return nil }
        return UInt64(bitPattern: Int64(sb.st_dev))
    }

    static func sameVolume(_ a: String, _ b: String) -> Bool {
        guard let x = volumeID(a), let y = volumeID(b) else { return false }
        return x == y
    }

    /// "38분" / "1시간 12분"
    static func durationText(_ seconds: Double) -> String {
        let m = max(0, Int(seconds / 60))
        if m >= 60 { return Lf("%@시간 %@분", "\(m / 60)", "\(m % 60)") }
        return Lf("%@분", "\(m)")
    }
}

/// Measured write rate over the last ~30 s (bytes/s), from bytes_written samples.
struct WriteRateMeter {
    private var samples: [(t: Double, bytes: Int64)] = []

    mutating func reset() { samples.removeAll() }

    mutating func add(_ bytes: Int64, at t: Double = ProcessInfo.processInfo.systemUptime) {
        if let last = samples.last, bytes < last.bytes { samples.removeAll() }   // counter restarted
        samples.append((t, bytes))
        while let f = samples.first, t - f.t > 31 { samples.removeFirst() }
    }

    /// nil until ~5 s have been measured.
    var bytesPerSecond: Double? {
        guard let f = samples.first, let l = samples.last, l.t - f.t >= 5, l.bytes > f.bytes else { return nil }
        return Double(l.bytes - f.bytes) / (l.t - f.t)
    }
}

/// One second of a network output, for the stream monitor popover (bars per second, orange where drops happened).
struct StreamSample {
    var time: Date
    var kbps: Double
    var framesDropped: Int      // frames dropped during this second
    var queueDepth: Int         // encoder input queue (of 8)
    var connected: Bool
    var rttMs: Double?          // SRT only
    var lossPercent: Double?
    var retransmitted: Int?     // packets retransmitted during this second
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
    /// The delay is currently held on disk / bytes on disk.
    @Published private(set) var delayOnDisk = false
    @Published private(set) var delayDiskBytes: Int64 = 0
    private static var cleanedDelayFolders = Set<String>()

    // Recording safety (record outputs)
    /// Backup (mirror) file being written now ("" = none).
    @Published private(set) var backupFile: String = ""
    /// 0 = no backup recording, 1 = writing, 2 = failed/stopped (the main recording goes on).
    @Published private(set) var backupState = 0
    /// The record disk failed; the recording continues in the backup file.
    @Published private(set) var mainDiskFailed = false
    /// Times the recording continued on another disk because the record disk was full.
    @Published private(set) var spillCount = 0
    /// Recording time left on the record disk (incl. the spill disk), nil = unknown / not recording.
    @Published private(set) var remainingSeconds: Double?
    /// Recording time left on the backup disk while backing up.
    @Published private(set) var backupRemainingSeconds: Double?
    /// Measured (else estimated) bytes/s written to the recording.
    private(set) var writeBytesPerSecond: Double = 0
    private var writeRate = WriteRateMeter()
    private var lastWarningSeq: Int32 = 0
    /// Safety events from the encoder (backup failed, continued on another disk…), drained by RecordingSafety.
    var pendingSafetyMessages: [String] = []

    // Stream monitor (network outputs)
    static let historySeconds = 60
    /// Last 60 s, one sample per second (oldest first).
    @Published private(set) var history: [StreamSample] = []
    /// Reconnects since the output was started.
    @Published private(set) var reconnectCount = 0
    /// When the current connection came up (nil while not connected).
    @Published private(set) var connectedSince: Date?
    private var wasConnected = false
    private var lostConnection = false
    private var lastDroppedTotal: Int64 = 0
    private var lastRetrans: Int64?
    /// Time since the output was started.
    var uptime: TimeInterval? { running ? Date().timeIntervalSince(startedAt) : nil }

    /// Status callback (main thread): counts reconnects of network outputs.
    private func noteState(_ s: Int32) {
        guard config.kind == .stream else { return }
        if s == Int32(MC_STATE_RUNNING) {
            if lostConnection { reconnectCount += 1 }
            lostConnection = false
            wasConnected = true
            connectedSince = Date()
        } else if s == Int32(MC_STATE_CONNECTING) || s == Int32(MC_STATE_ERROR) {
            if wasConnected { lostConnection = true }
            connectedSince = nil
        }
    }

    /// Throw the delayed part away and go live (profanity/accident button).
    func dumpDelay() {
        lock.lock(); let f = ffOut; lock.unlock()
        if let f = f { mc_output_dump_delay(f); delayDumped = true }
    }

    private let lock = NSLock()
    private var ffOut: OpaquePointer?
    /// Status-callback context of ffOut (released after mc_output_close returns).
    private var ffBox: Unmanaged<OutputStatusBox>?
    /// Bumped on every start/stop. A status callback carries the generation it was opened with, so a
    /// late "중지됨" from a closing encoder can never overwrite the state of the one that replaced it.
    private var generation = 0
    private var ndiOut: OpaquePointer?
    private var dlOut: OpaquePointer?
    private var format = VideoFormat.defaultFormat
    private var startedAt = Date()
    /// When the current recording file began (splits start a new file but keep the output running).
    private var fileStartedAt = Date()
    /// When this output started (nil while stopped) — for the bar's elapsed time.
    /// A failed recording stops its timer, so a dead REC doesn't look like it is still counting.
    var liveSince: Date? {
        guard running else { return nil }
        if config.kind == .record && state == Int32(MC_STATE_ERROR) { return nil }
        return startedAt
    }

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
                switch nextRecordFile() {
                case .failure(let e): return fail(e.message)
                case .success(let r):
                    url = r.path
                    container = r.container
                }
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
            cfg.delay_ms = Int32(c.effectiveDelaySeconds * 1000)
            var delayDir: UnsafeMutablePointer<CChar>? = nil
            if c.delayUsesDisk {
                let folder = c.delayFolderPath
                do {
                    try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
                } catch {
                    return fail(Lf("딜레이 버퍼 폴더를 만들 수 없음: %@", folder))
                }
                if !OutputChannel.cleanedDelayFolders.contains(folder) {
                    OutputConfig.cleanupStaleDelayBuffers(in: folder)
                    OutputChannel.cleanedDelayFolders.insert(folder)
                }
                let need = c.delayBytesNeeded(format: format)
                if let free = OutputConfig.freeSpace(at: folder), free < need + OutputConfig.delayDiskReserve {
                    return fail(Lf("딜레이용 디스크 공간 부족: 필요 %@ + 여유 %@, 남은 공간 %@. 딜레이를 줄이거나 다른 디스크를 고르세요.",
                                   OutputConfig.bytesText(need), OutputConfig.bytesText(OutputConfig.delayDiskReserve),
                                   OutputConfig.bytesText(free)))
                }
                delayDir = strdup(folder)
            }
            defer { free(delayDir) }
            cfg.delay_dir = UnsafePointer(delayDir)
            cfg.extra_audio_tracks = c.kind == .record ? Int32(c.extraBusIndices.count) : 0
            // Recording safety: backup file on a second disk + continue on another disk when full.
            let mirrorPtr: UnsafeMutablePointer<CChar>? = c.backupFolderPath.map { strdup($0) }
            let spillPtr: UnsafeMutablePointer<CChar>? = c.spillFolderPath.map { strdup($0) }
            defer { free(mirrorPtr); free(spillPtr) }
            cfg.mirror_dir = UnsafePointer(mirrorPtr)
            cfg.spill_dir = UnsafePointer(spillPtr)
            cfg.spill_reserve_bytes = spillPtr != nil ? OutputConfig.recordDiskReserve : 0
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
            generation += 1
            let box = Unmanaged.passRetained(OutputStatusBox(channel: self, generation: generation))
            let handle = mc_output_open(&cfg, { user, state, msg in
                guard let user = user else { return }
                let b = Unmanaged<OutputStatusBox>.fromOpaque(user).takeUnretainedValue()
                let text = msg.map { String(cString: $0) } ?? ""
                DispatchQueue.main.async {
                    // ignore late messages after stop() and from an earlier start (split / restart)
                    guard let me = b.channel, me.running, me.generation == b.generation else { return }
                    me.state = state
                    me.message = L(text)
                    me.noteState(state)
                }
            }, box.toOpaque())
            guard let h = handle else {
                box.release()
                return fail(L("출력을 시작할 수 없음"))
            }
            lock.lock()
            ffOut = h
            ffBox = box
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
            let keyOutput = c.deckLinkAlphaMode != "none" || c.deckLinkKey
            var err = [CChar](repeating: 0, count: 256)
            guard let h = mc_decklink_out_open(Int32(c.deckLinkIndex), Int32(format.width), Int32(format.height),
                                               Int32(format.fpsNum), Int32(format.fpsDen), keyOutput ? 1 : 0,
                                               &err, Int32(err.count)) else {
                return fail(String(cString: err))
            }
            lock.lock()
            dlOut = h
            lock.unlock()
            state = Int32(MC_STATE_RUNNING)
            if keyOutput {
                let shape = c.deckLinkAlphaMode == "straight" ? "Straight" : "Premultiplied"
                message = Lf("DeckLink Fill & Key 출력 중 · %@", shape)
            } else {
                message = L("DeckLink 출력 중")
            }
        }
        running = true
        delayDumped = false
        startedAt = Date()
        fileStartedAt = startedAt
        resetSafetyAndMonitor()
        return nil
    }

    private func resetSafetyAndMonitor() {
        backupFile = ""
        backupState = 0
        mainDiskFailed = false
        spillCount = 0
        remainingSeconds = nil
        backupRemainingSeconds = nil
        writeBytesPerSecond = 0
        writeRate.reset()
        lastWarningSeq = 0
        history = []
        reconnectCount = 0
        connectedSince = nil
        wasConnected = false
        lostConnection = false
        lastDroppedTotal = 0
        lastRetrans = nil
    }

    struct RecordFileError: Error { let message: String }

    /// Path + muxer for a new recording file ("HongMix_<date>_<time>.<ext>" in the record folder).
    private func nextRecordFile() -> Result<(path: String, container: String), RecordFileError> {
        let c = config
        let folder = (c.recordFolder as NSString).expandingTildeInPath
        do {
            try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        } catch {
            return .failure(RecordFileError(message: Lf("녹화 폴더를 만들 수 없음: %@", "\(folder)")))
        }
        let df = DateFormatter()
        df.dateFormat = "yyyyMMdd_HHmmss"
        var ext = c.recordContainer
        if c.videoCodec == "prores" { ext = "mov" }
        var path = (folder as NSString).appendingPathComponent("HongMix_\(df.string(from: Date())).\(ext)")
        var n = 2
        while FileManager.default.fileExists(atPath: path) {   // never overwrite (split within the same second)
            path = (folder as NSString).appendingPathComponent("HongMix_\(df.string(from: Date()))_\(n).\(ext)")
            n += 1
        }
        return .success((path, ext == "ts" ? "mpegts" : (ext == "mp4" ? "mp4" : "mov")))
    }

    private func fail(_ msg: String) -> String {
        state = Int32(MC_STATE_ERROR)
        message = msg
        return msg
    }

    func stop(waitForClose: Bool = false) {
        lock.lock()
        let f = ffOut, n = ndiOut, d = dlOut, box = ffBox
        ffOut = nil
        ffBox = nil
        ndiOut = nil
        dlOut = nil
        lock.unlock()
        generation += 1   // callbacks still queued from this encoder are now stale
        // Closing can take a moment (flush + trailer); do it off the main thread for streams,
        // but synchronously enough that the handles are gone before we report "stopped".
        if let f = f, waitForClose {
            mc_output_close(f)
            box?.release()
        } else if let f = f {
            DispatchQueue.global(qos: .userInitiated).async {
                mc_output_close(f)   // joins the output thread → no more callbacks
                box?.release()
            }
        } else {
            box?.release()
        }
        if let n = n { mc_ndi_send_close(n) }
        if let d = d { mc_decklink_out_close(d) }
        running = false
        remainingSeconds = nil
        backupRemainingSeconds = nil
        connectedSince = nil
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
            Date().timeIntervalSince(fileStartedAt) >= Double(config.splitMinutes) * 60 {
            // "New file every N minutes": the encoder switches files on its next frame (forced keyframe)
            // without stopping — no lost frames or audio at the boundary. Restart only if it can't.
            lock.lock(); let f = ffOut; lock.unlock()
            if let f = f, case .success(let r) = nextRecordFile(), mc_output_split(f, r.path) == 0 {
                fileStartedAt = Date()
            } else {
                stop()
                start(format: format)
                return
            }
        }
        lock.lock()
        let f = ffOut, n = ndiOut
        var st = mc_output_stats()
        var cur = [CChar](repeating: 0, count: 1024)
        var bak = [CChar](repeating: 0, count: 1024)
        var warn = [CChar](repeating: 0, count: 256)
        if let f = f {
            mc_output_get_stats(f, &st)
            if config.kind == .record {
                mc_output_current_file(f, &cur, Int32(cur.count))
                mc_output_backup_file(f, &bak, Int32(bak.count))
                if st.warning_seq != lastWarningSeq { mc_output_last_warning(f, &warn, Int32(warn.count)) }
            }
        }
        let conns = n.map { mc_ndi_send_connections($0) } ?? 0
        var dl = mc_dl_out_stats()
        let d = dlOut
        if let d = d { mc_decklink_out_stats(d, &dl) }
        lock.unlock()
        if f != nil {
            if config.kind == .record, cur[0] != 0 {   // follows the split once the new file is open
                let path = String(cString: cur)
                if path != lastFile { lastFile = path }
            }
            let enc = withUnsafePointer(to: &st.encoder) {
                $0.withMemoryRebound(to: CChar.self, capacity: 48) { String(cString: $0) }
            }
            let mb = Double(st.bytes_written) / 1_000_000
            lastKbps = st.kbps
            if delayBufferedMs != Int(st.delay_buffered_ms) { delayBufferedMs = Int(st.delay_buffered_ms) }
            if delayOnDisk != (st.delay_on_disk != 0) { delayOnDisk = st.delay_on_disk != 0 }
            if delayDiskBytes != st.delay_disk_bytes { delayDiskBytes = st.delay_disk_bytes }
            statsText = String(format: L("%@ · %.0f kbps · %.1f MB · 드롭 %lld · 대기 %d/8"),
                               enc, st.kbps, mb, st.frames_dropped, st.queue_depth)
            if config.kind == .record {
                updateRecordSafety(st, backup: String(cString: bak),
                                   warning: st.warning_seq != lastWarningSeq ? String(cString: warn) : nil)
            } else if config.kind == .stream {
                appendStreamSample(st)
            }
        } else if n != nil {
            statsText = Lf("연결된 수신기 %@", "\(conns)")
        } else if d != nil {
            // card audio clock lock: buffered level vs target, and how often it had to correct
            statsText = Lf("오디오 버퍼 %@/%@ · 보정 −%@ +%@ · 재동기 %@", "\(dl.buffered_audio)", "\(dl.target_audio)",
                           "\(dl.samples_dropped)", "\(dl.samples_inserted)", "\(dl.resyncs)")
        }
    }
}

extension OutputChannel {
    /// Once a second (refreshStats): backup/spill state, write rate and recording time left.
    fileprivate func updateRecordSafety(_ st: mc_output_stats, backup: String, warning: String?) {
        if backupFile != backup { backupFile = backup }
        if backupState != Int(st.mirror_state) { backupState = Int(st.mirror_state) }
        if mainDiskFailed != (st.main_failed != 0) { mainDiskFailed = st.main_failed != 0 }
        if spillCount != Int(st.spills) { spillCount = Int(st.spills) }
        if let w = warning {
            lastWarningSeq = st.warning_seq
            if !w.isEmpty { pendingSafetyMessages.append(L(w)) }
        }
        writeRate.add(st.bytes_written)
        let rate = writeRate.bytesPerSecond ?? config.estimatedRecordBytesPerSecond(format: format)
        writeBytesPerSecond = rate
        guard rate > 0, !lastFile.isEmpty else { remainingSeconds = nil; backupRemainingSeconds = nil; return }
        let reserve = OutputConfig.recordDiskReserve
        let mainFree = RecordDisk.freeBytes(lastFile) ?? 0
        var usable = Double(mainFree)
        let mirroring = backupState == 1 && !backupFile.isEmpty
        if let spill = config.spillFolderPath, !RecordDisk.sameVolume(lastFile, spill) {
            // moves to the spill disk at the reserve; while mirroring onto that disk, the backup uses it too
            let mainPart = max(0, Double(mainFree - reserve))
            var spillFree = Double(max(0, (RecordDisk.freeBytes(spill) ?? 0) - reserve))
            if mirroring && RecordDisk.sameVolume(backupFile, spill) { spillFree = max(0, spillFree - mainPart) }
            usable = mainPart + spillFree
        }
        let left = usable / rate
        if remainingSeconds.map({ abs($0 - left) >= 1 }) ?? true { remainingSeconds = left }
        if mirroring, let bf = RecordDisk.freeBytes(backupFile) {
            let b = Double(bf) / rate
            if backupRemainingSeconds.map({ abs($0 - b) >= 1 }) ?? true { backupRemainingSeconds = b }
        } else if backupRemainingSeconds != nil {
            backupRemainingSeconds = nil
        }
    }

    /// Once a second (refreshStats) for network outputs: one sample of the 60-s monitor history.
    fileprivate func appendStreamSample(_ st: mc_output_stats) {
        let srt = srtStats()
        let dropped = Int(max(0, st.frames_dropped - lastDroppedTotal))
        lastDroppedTotal = st.frames_dropped
        var retrans: Int?
        if let s = srt {
            if let l = lastRetrans { retrans = Int(max(0, s.retransmitted - l)) }
            lastRetrans = s.retransmitted
        }
        let sample = StreamSample(time: Date(), kbps: st.kbps, framesDropped: dropped, queueDepth: Int(st.queue_depth),
                                  connected: state == Int32(MC_STATE_RUNNING), rttMs: srt?.rttMs,
                                  lossPercent: srt?.lossPercent, retransmitted: retrans)
        var h = history
        h.append(sample)
        if h.count > OutputChannel.historySeconds { h.removeFirst(h.count - OutputChannel.historySeconds) }
        history = h
    }

    /// API: last n kbps samples, comma separated (compact, for tests).
    func kbpsHistoryText(last n: Int = 10) -> String {
        history.suffix(n).map { String(Int($0.kbps.rounded())) }.joined(separator: ",")
    }
}

/// Recording safety for the REC button: lowest recording time left over all recordings (+ MultiCorder),
/// disk warnings at a threshold (10/30/60 min, off) and again at 5 min, and the encoder's backup/spill events.
final class RecordingSafety: ObservableObject {
    static let warnOptions = [10, 30, 60, 0]   // minutes; 0 = off
    static let criticalMinutes = 5
    private static let defaultsKey = "HongMix.recordDiskWarnMinutes"

    /// Warning threshold in minutes (0 = off).
    @Published var warnMinutes: Int {
        didSet { UserDefaults.standard.set(warnMinutes, forKey: RecordingSafety.defaultsKey) }
    }
    /// Lowest recording time left over the running recordings (incl. their backup disks and MultiCorder).
    @Published private(set) var lowestRemainingSeconds: Double?
    /// MultiCorder folder: time left at the current ISO write rate.
    @Published private(set) var multiCorderRemainingSeconds: Double?
    /// Below the threshold somewhere → REC turns orange.
    @Published private(set) var diskWarning = false
    /// Below 5 minutes somewhere.
    @Published private(set) var diskCritical = false
    /// What the warning is about ("" = none).
    @Published private(set) var diskWarningMessage = ""

    private var levels: [String: Int] = [:]
    private var mcRate = WriteRateMeter()

    init() {
        let v = UserDefaults.standard.object(forKey: RecordingSafety.defaultsKey) as? Int
        warnMinutes = v ?? 30
    }

    /// "38분 남음"; nil → "".
    static func remainingText(_ s: Double?) -> String {
        guard let s = s else { return "" }
        return Lf("%@ 남음", RecordDisk.durationText(s))
    }

    /// REC button text: "REC 1:02:14 · 38 min left" (time left only while it is worth showing).
    func recLabel(elapsed: TimeInterval) -> String {
        let t = Int(max(0, elapsed))
        var s = String(format: "REC %d:%02d:%02d", t / 3600, t / 60 % 60, t % 60)
        if let r = lowestRemainingSeconds, r < 24 * 3600 { s += " · " + RecordingSafety.remainingText(r) }
        return s
    }

    private func level(_ seconds: Double?, key: String) -> Int {
        guard warnMinutes > 0, let s = seconds else { return 0 }
        let prev = levels[key] ?? 0
        if s < Double(RecordingSafety.criticalMinutes * 60) { return 2 }
        if s < Double(warnMinutes * 60) { return prev == 2 && s < Double(RecordingSafety.criticalMinutes * 60 + 60) ? 2 : 1 }
        // hysteresis: stay warned until clearly above the threshold again (space freed / spill disk added)
        if prev > 0 && s < Double(warnMinutes * 60) * 1.1 + 60 { return 1 }
        return 0
    }

    /// Once a second from the engine tick.
    func update(_ e: SwitcherEngine) {
        var lowest: Double?
        var worst = 0
        var worstText = ""
        var seen = Set<String>()
        func consider(_ key: String, _ name: String, _ secs: Double?, backup: Bool) {
            seen.insert(key)
            if let s = secs { lowest = min(lowest ?? s, s) }
            let lv = level(secs, key: key)
            let prev = levels[key] ?? 0
            levels[key] = lv
            guard lv > 0, let s = secs else { return }
            let left = RecordDisk.durationText(s)
            let text = backup ? Lf("⚠︎ 백업 디스크 공간: %@ — 약 %@ 남음", name, left)
                : lv == 2 ? Lf("⚠︎ 녹화 디스크가 곧 가득 참: %@ — 약 %@ 남음", name, left)
                : Lf("⚠︎ 녹화 디스크 공간: %@ — 약 %@ 남음", name, left)
            if lv > prev { e.lastMessage = text }   // once per threshold crossing
            if lv > worst || worstText.isEmpty { worst = max(worst, lv); worstText = text }
        }
        for o in e.outputs where o.running && o.config.kind == .record {
            for m in o.pendingSafetyMessages { e.lastMessage = "⚠︎ \(o.config.name): \(m)" }
            o.pendingSafetyMessages.removeAll()
            consider("rec:\(o.id)", o.config.name, o.remainingSeconds, backup: false)
            if o.backupRemainingSeconds != nil {
                consider("bak:\(o.id)", o.config.name, o.backupRemainingSeconds, backup: true)
            }
        }
        // MultiCorder: free space of its folder / measured ISO write rate
        if let folder = e.multiCorderFolderPath {
            mcRate.add(e.multiCorderBytesWritten())
            let rate = mcRate.bytesPerSecond ?? 0
            let left = rate > 0 ? RecordDisk.freeBytes(folder).map { Double($0) / rate } : nil
            if multiCorderRemainingSeconds.map({ abs($0 - (left ?? -1)) >= 1 }) ?? (left != nil) { multiCorderRemainingSeconds = left }
            consider("multicorder", "MultiCorder", left, backup: false)
        } else {
            mcRate.reset()
            if multiCorderRemainingSeconds != nil { multiCorderRemainingSeconds = nil }
        }
        levels = levels.filter { seen.contains($0.key) }
        if lowestRemainingSeconds.map({ abs($0 - (lowest ?? -1)) >= 1 }) ?? (lowest != nil) { lowestRemainingSeconds = lowest }
        if diskWarning != (worst > 0) { diskWarning = worst > 0 }
        if diskCritical != (worst == 2) { diskCritical = worst == 2 }
        if diskWarningMessage != worstText { diskWarningMessage = worstText }
    }
}

/// Status-callback context for one encoder start (retained until its mc_output is closed).
final class OutputStatusBox {
    weak var channel: OutputChannel?
    let generation: Int
    init(channel: OutputChannel, generation: Int) {
        self.channel = channel
        self.generation = generation
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
