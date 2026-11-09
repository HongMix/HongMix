import Foundation
import CoreVideo
import AppKit
import AVFoundation
import CoreImage
import CoreMedia
import Metal

// MARK: - Instant Replay
//
// Recording: up to 4 sources (CAM 1–4) are rendered at the program format each frame, encoded intra-only
// (H.264, or ProRes on the hardware ProRes engine) and written frame-indexed into the replay store
// (segment files on disk). Master audio is stored per frame as PCM. Frame numbers are the engine's
// render ticks, so all angles line up. The 4 slots are fixed streams: a slot's source can be changed
// or added while recording without touching the other cameras or the timecode.
// Wall-clock time of every recorded frame comes from anchors (tick → time) taken while recording,
// so it stays correct after the oldest footage is deleted or recording is stopped and restarted.
// Playback: two channels (Deck A / Deck B, shown in the window and on Replay A/B inputs). Slow motion
// is smoothed: AI-interpolated clip (background) → real-time AI (fast Macs) → GPU frame blending.

struct ReplaySettings: Codable, Equatable {
    var cameraIDs: [String] = Array(repeating: "", count: ReplaySettings.maxCameras)  // CAM 1–4, "" = empty
    var quality: Int = 100_000            // kbps per camera (H.264 intra)
    var codec: String = "hevc"            // "hevc" (default), "h264", "prores_proxy", "prores_lt"
    var hevcQuality: Int = 65             // HEVC intra constant quality (VideoToolbox 1–100)
    var formatRev = 2                     // 2 = HEVC default (1.3.37); older projects are migrated
    var smoothSlow = true                 // GPU blending between frames in slow motion
    var audioFollowsCamera = true         // replay plays the shown angle's own audio (else program audio)
    var aiSlow = true                     // AI frame interpolation for slow motion
    var folder: String = ""               // "" = ~/Movies/HongMix/Replay
    var maxGB: Double = 0                 // 0 = use the free space (minus a reserve)
    var autoDelete = true                 // delete the oldest footage when the limit is reached
    var autoReturn = true                 // "Replay → Program" cuts back when the event ends
    var preRoll: Double = 0               // seconds added before Mark In when playing events

    static let maxCameras = 4

    var folderPath: String {
        ((folder.isEmpty ? "~/Movies/HongMix/Replay" : folder) as NSString).expandingTildeInPath
    }

    /// CAM 1–4 → input ID (nil = empty slot).
    var slots: [UUID?] {
        (0..<Self.maxCameras).map { i in i < cameraIDs.count ? UUID(uuidString: cameraIDs[i]) : nil }
    }

    var assignedCount: Int { slots.compactMap { $0 }.count }
    var isProRes: Bool { codec.hasPrefix("prores") }
    var isHEVC: Bool { codec == "hevc" }
    /// Decoder family for a stored session: 0 = H.264, 1 = ProRes, 2 = HEVC.
    static func codecKind(_ codec: String) -> Int { codec.hasPrefix("prores") ? 1 : (codec == "hevc" ? 2 : 0) }
    /// Value for mc_output_config.video_kbps (negative = constant quality).
    var encoderKbps: Int32 { isHEVC ? -Int32(hevcQuality) : Int32(quality) }

    static func normalized(_ ids: [String]) -> [String] {
        var a = Array(ids.prefix(maxCameras))
        while a.count < maxCameras { a.append("") }
        return a
    }

    /// Approximate video bitrate per camera (kbps) at the given program format.
    func kbpsPerCamera(width: Int, height: Int, fps: Double) -> Double {
        let scale = Double(width * height) / (1920 * 1080) * max(1, fps) / 59.94
        if isHEVC {
            // measured on 1080p59.94 poker footage (VideoToolbox HEVC intra, constant quality)
            let table: [(Int, Double)] = [(55, 30_000), (65, 42_000), (72, 59_000), (80, 85_000)]
            let base = table.min(by: { abs($0.0 - hevcQuality) < abs($1.0 - hevcQuality) })?.1 ?? 42_000
            return base * scale
        }
        guard isProRes else { return Double(quality) }
        // Apple ProRes white paper, 1920×1080 at 29.97: Proxy 45, LT 102 Mb/s; scales with pixels × rate.
        let base: Double = codec == "prores_proxy" ? 45_000 : 102_000
        return base * Double(width * height) / (1920 * 1080) * max(1, fps) / 29.97
    }

    var codecLabel: String {
        switch codec {
        case "prores_proxy": return "ProRes 422 Proxy"
        case "prores_lt": return "ProRes 422 LT"
        case "hevc": return "HEVC Intra q\(hevcQuality)"
        default: return "H.264 Intra \(quality / 1000)Mb"
        }
    }

    init() {}
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = ReplaySettings()
        cameraIDs = Self.normalized(c.value(.cameraIDs, d.cameraIDs))
        quality = c.value(.quality, d.quality)
        codec = c.value(.codec, d.codec)
        hevcQuality = c.value(.hevcQuality, d.hevcQuality)
        // Before 1.3.37 the default was H.264 Intra 35 Mb/s, which measured soft (SSIM 0.968):
        // move those projects to HEVC Intra (same size class, ProRes-Proxy-like quality).
        if c.value(.formatRev, 1) < 2 && codec == "h264" { codec = "hevc" }
        formatRev = 2
        smoothSlow = c.value(.smoothSlow, d.smoothSlow)
        aiSlow = c.value(.aiSlow, d.aiSlow)
        audioFollowsCamera = c.value(.audioFollowsCamera, d.audioFollowsCamera)
        folder = c.value(.folder, d.folder)
        maxGB = c.value(.maxGB, d.maxGB)
        autoDelete = c.value(.autoDelete, d.autoDelete)
        autoReturn = c.value(.autoReturn, d.autoReturn)
        preRoll = c.value(.preRoll, d.preRoll)
    }
}
struct ReplayEvent: Identifiable, Equatable {
    let id = UUID()
    var number: Int
    var inFrame: Int64
    var outFrame: Int64
    var camera: Int
    var name: String = ""
}

/// Background AI slow-motion render of one clip.
struct ReplayAIClipState: Equatable {
    var camera: Int
    var progress: Double = 0
    var ready = false
    var failed = false
}

/// What the UI shows for one channel (published ~10×/s).
struct ReplayChannelUI: Equatable {
    var live = true
    var camera = 0
    var playing = false
    var speed: Double = 1
    var reverse = false
    var position: Int64 = 0
    var behindLive: Double = 0      // seconds behind the recording head
    var eventNumber: Int?
    var attached = false            // a Replay A/B input exists
    var smoothing = ""              // "", "BLEND", "AI", "AI RT"
}

struct ReplayStatus: Equatable {
    var cameras = 0
    var bufferedSeconds: Double = 0
    var bytes: Int64 = 0
    var free: Int64 = 0
    var hoursLeft: Double = 0
    var limitBytes: Int64 = 0
    var error: String?
}

/// Replay A / Replay B: shows what its replay channel plays.
final class ReplayInput: InputSource {
    var channel: Int { max(0, min(1, config.replayChannel)) }
    override func start() {
        ReplayEngine.shared.attach(self, channel: channel)
        postStatus(Int32(MC_STATE_RUNNING), channel == 0 ? "Replay A" : "Replay B")
    }
    override func stop() {
        ReplayEngine.shared.detach(self)
        video.clear()
        audio.clear()
    }
}

final class ReplayEngine: ObservableObject {
    static let shared = ReplayEngine()
    static let cams = ReplaySettings.maxCameras
    // Store streams: 0…3 = CAM 1–4 video, 4 = program (master) audio, 5…8 = CAM 1–4 source audio.
    private static let audioStream = Int32(ReplaySettings.maxCameras)
    private static func camAudioStream(_ k: Int) -> Int32 { Int32(ReplaySettings.maxCameras + 1 + k) }
    private static let streamCount = Int32(ReplaySettings.maxCameras * 2 + 1)
    private static let silence: UnsafeMutablePointer<Float> = {
        let p = UnsafeMutablePointer<Float>.allocate(capacity: 48_000 * 2)
        p.initialize(repeating: 0, count: 48_000 * 2)
        return p
    }()

    @Published var settings = ReplaySettings() { didSet { if settings != oldValue { settingsChanged(oldValue) } } }
    @Published private(set) var recording = false
    @Published private(set) var recordingStartedAt: Date?
    @Published private(set) var events: [ReplayEvent] = []
    @Published private(set) var channelsUI = [ReplayChannelUI(), ReplayChannelUI()]
    @Published private(set) var status = ReplayStatus()
    @Published private(set) var pendingIn: Int64?
    @Published private(set) var aiClips: [UUID: ReplayAIClipState] = [:]
    /// Clip export (Replay › ⬇): progress 0…1 per event being exported, last result message.
    @Published private(set) var exports: [UUID: Double] = [:]
    @Published private(set) var exportMessage = ""
    let exportQueue = DispatchQueue(label: "replay.export", qos: .utility)
    var lastExportError = ""          // export queue only
    /// How slow motion is smoothed on this Mac (shown in the settings).
    @Published private(set) var aiInfo = ""
    /// Channels the transport buttons act on (A, B or both).
    @Published var selected: Set<Int> = [0]

    /// Deck A / Deck B pictures for the replay window (filled even without Replay A/B inputs).
    let deckSlots = [VideoSlot(), VideoSlot()]

    weak var engine: SwitcherEngine?

    // MARK: State shared with the render thread / player queue (lock)
    private struct ChannelState {
        var live = true
        var camera = 0
        var playing = false
        var speed: Double = 1
        var reverse = false
        var pos: Double = 0
        var stopFrame: Int64?
        var eventNumber: Int?
        var shown: Int64 = -1
        var shownCamera = -1
        var shownSmooth = false
        var shownPos: Double = -1
        var smoothing = ""
        var finished = false
        var gen = 0                 // bumped by every user change (player never overwrites a newer change)
    }
    private struct AIClipRef {
        let id: UUID
        let inFrame: Int64
        let outFrame: Int64
        let camera: Int
        let store: OpaquePointer
    }
    private let lock = NSLock()
    private var ch = [ChannelState(), ChannelState()]
    private var inputsByChannel: [Int: [ReplayInput]] = [:]
    private var store: OpaquePointer?
    private var outs = [OpaquePointer?](repeating: nil, count: ReplayEngine.cams)
    private var sinks = [OpaquePointer?](repeating: nil, count: ReplayEngine.cams)
    private var recCameras = [UUID?](repeating: nil, count: ReplayEngine.cams)   // source of each CAM slot
    private var recCodec = "h264"
    private var liveFrames = [CVPixelBuffer?](repeating: nil, count: ReplayEngine.cams)
    private var head: Int64 = -1                   // newest frame recorded
    private var clockAnchors: [(tick: Int64, time: Double)] = []
    private var needAnchor = true
    private var aiIndex: [AIClipRef] = []
    private var aiCancelled: Set<UUID> = []
    private var aiEpoch = 0
    private var playerSmooth = true
    private var playerAI = true
    private var playerAudioFollow = true
    private var fps: Double = 59.94
    private var format = VideoFormat.defaultFormat
    private let encoderCloses = DispatchGroup()     // encoder closes in flight (they still write into the store)
    private var reportedDrops: Int64 = 0            // main thread: store drop / write-error counts already reported
    private var reportedWriteErrors: Int64 = 0

    // player
    private let queue = DispatchQueue(label: "replay.player", qos: .userInteractive)
    private var timer: DispatchSourceTimer?
    private var decoders: [OpaquePointer?] = [nil, nil]
    private var decoderKind = -1
    private var aiDecoders: [OpaquePointer?] = [nil, nil]
    private var frameCache: [[(frame: Int64, cam: Int, pb: CVPixelBuffer)]] = [[], []]
    private var pool: CVPixelBufferPool?
    private var poolSize = (0, 0)
    private let blender = FrameBlender()
    private var rtAI: AIInterpolator?              // player queue only (fast Macs)
    private var uiCounter = 0
    private var returnToID: UUID?
    private var statusTimer: Timer?

    // background AI
    private let aiQueue = DispatchQueue(label: "replay.ai", qos: .utility)          // clip renders (cancel fast)
    private let aiLoadQueue = DispatchQueue(label: "replay.ai.load", qos: .utility) // ML model loading (slow)
    private var bgAI: AIInterpolator?              // lock; used only on aiQueue
    private var aiPreparedSize = (0, 0)            // lock

    var frameRate: Double { fps }

    // MARK: Inputs

    func attach(_ input: ReplayInput, channel: Int) {
        lock.lock()
        var list = inputsByChannel[channel] ?? []
        if !list.contains(where: { $0 === input }) { list.append(input) }
        inputsByChannel[channel] = list
        lock.unlock()
        startPlayer()
        publishUI()
    }

    func detach(_ input: ReplayInput) {
        lock.lock()
        for k in inputsByChannel.keys { inputsByChannel[k]?.removeAll { $0 === input } }
        lock.unlock()
        publishUI()
    }

    /// Render thread: replay needs camera frames this tick — while recording, or when a deck shows a
    /// live angle (replay window open or a Replay A/B input exists). Idle replay costs no GPU time.
    var wantsFrames: Bool {
        lock.lock(); defer { lock.unlock() }
        guard store != nil else { return false }
        if outs.contains(where: { $0 != nil }) { return true }
        let liveDeck = ch.indices.contains { ch[$0].live && (windowVisible || !(inputsByChannel[$0] ?? []).isEmpty) }
        return liveDeck
    }

    private var windowVisible = false
    /// The replay window reports whether its deck monitors are on screen.
    func setWindowVisible(_ on: Bool) {
        lock.lock(); windowVisible = on; lock.unlock()
        if on { startPlayer() }
    }

    /// Inputs whose own (pre-fader) audio the mixer must provide this tick: the recording CAM sources.
    var sourceAudioIDs: Set<UUID> {
        lock.lock(); defer { lock.unlock() }
        var ids = Set<UUID>()
        for k in 0..<Self.cams where outs[k] != nil { if let id = recCameras[k] { ids.insert(id) } }
        return ids
    }

    /// Sources of the current recording, CAM 1–4 (nil = empty).
    var recordingSlots: [UUID?] {
        lock.lock(); defer { lock.unlock() }
        return recCameras
    }

    // MARK: Sources (CAM 1–4)

    /// Assigns an input to a CAM slot (nil clears it). An input already used by another slot moves.
    func setSource(_ slot: Int, _ id: UUID?) {
        guard slot >= 0, slot < Self.cams else { return }
        var ids = ReplaySettings.normalized(settings.cameraIDs)
        if let id = id {
            for k in ids.indices where ids[k] == id.uuidString { ids[k] = "" }
            ids[slot] = id.uuidString
        } else {
            ids[slot] = ""
        }
        settings.cameraIDs = ids
    }

    /// CAM slot (0…3) an input is assigned to.
    func slot(of id: UUID) -> Int? {
        settings.slots.firstIndex(where: { $0 == id })
    }

    private func settingsChanged(_ old: ReplaySettings) {
        lock.lock()
        playerSmooth = settings.smoothSlow
        playerAI = settings.aiSlow
        playerAudioFollow = settings.audioFollowsCamera
        lock.unlock()
        if settings.slots != old.slots { applySlots() }
        if settings.aiSlow && !old.aiSlow { prepareAI() }
        refreshLimit()
    }

    /// While recording, start/stop per-slot encoders so a source can be added, swapped or removed live.
    private func applySlots() {
        guard let e = engine else { return }
        let want = settings.slots.map { id in id.flatMap { e.input(withID: $0) != nil ? $0 : nil } }
        lock.lock()
        let st = store
        if st != nil { recCameras = want }
        let current = outs
        lock.unlock()
        guard recording, let st = st else { return }
        var closing: [(OpaquePointer, OpaquePointer?)] = []
        for k in 0..<Self.cams {
            if want[k] != nil && current[k] == nil {
                if let (o, s) = openEncoder(slot: k, store: st) {
                    lock.lock(); outs[k] = o; sinks[k] = s; lock.unlock()
                }
            } else if want[k] == nil, let o = current[k] {
                lock.lock(); let s = sinks[k]; outs[k] = nil; sinks[k] = nil; lock.unlock()
                closing.append((o, s))
            }
        }
        if !closing.isEmpty {
            encoderCloses.enter()
            DispatchQueue.global(qos: .userInitiated).async {
                for (o, s) in closing { mc_output_close(o); if let s = s { mc_replay_sink_free(s) } }
                self.encoderCloses.leave()
            }
        }
        refreshStatus()
    }

    // MARK: Recording

    private func openEncoder(slot k: Int, store st: OpaquePointer) -> (OpaquePointer, OpaquePointer?)? {
        guard let sink = mc_replay_sink_new(st, Int32(k)) else { return nil }
        var cfg = mc_output_config()
        cfg.width = Int32(format.width); cfg.height = Int32(format.height)
        cfg.fps_num = Int32(format.fpsNum); cfg.fps_den = Int32(format.fpsDen)
        cfg.video_kbps = settings.encoderKbps
        cfg.audio_kbps = 64
        cfg.keyint_frames = 1                   // intra-only: every frame decodes on its own
        cfg.hardware = 1
        cfg.pixelbuffer_input = 1
        cfg.packet_cb = mc_replay_sink_cb
        cfg.packet_user = UnsafeMutableRawPointer(sink)
        let u = strdup("replay:"), f = strdup("null"), v = strdup(recCodec)
        cfg.url = UnsafePointer(u); cfg.format = UnsafePointer(f); cfg.video_codec = UnsafePointer(v)
        let h = mc_output_open(&cfg, nil, nil)
        free(u); free(f); free(v)
        guard let h = h else { mc_replay_sink_free(sink); return nil }
        return (h, sink)
    }

    func startRecording() -> String? {
        guard let e = engine else { return "Engine not ready" }
        if recording { return nil }
        let slots = settings.slots.map { id in id.flatMap { e.input(withID: $0) != nil ? $0 : nil } }
        guard slots.contains(where: { $0 != nil }) else { return L("리플레이 소스(CAM 1–4)를 먼저 고르세요") }
        let fmt = e.format
        lock.lock()
        let sameSetup = store != nil && recCodec == settings.codec && format.width == fmt.width && format.height == fmt.height
            && format.fpsNum == fmt.fpsNum && format.fpsDen == fmt.fpsDen
        lock.unlock()
        if !sameSetup { closeStore() }
        format = fmt
        fps = fmt.fps
        let folder = settings.folderPath
        do { try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true) } catch {
            return Lf("리플레이 폴더를 만들 수 없음: %@", folder)
        }
        if !sameSetup {
            let dir = (folder as NSString).appendingPathComponent("session")
            // The store's writer thread does the disk I/O; this queue absorbs disk stalls (~2.5 s at full
            // bitrate for all CAM slots, which can be added live) before packets get dropped.
            let perSecond = settings.kbpsPerCamera(width: fmt.width, height: fmt.height, fps: fmt.fps) * 1000 / 8
                * Double(Self.cams) + 48_000 * 8 * Double(Self.cams + 1)
            let queueBytes = Int64(min(512e6, max(64e6, perSecond * 2.5)))
            guard let st = mc_replay_store_open2(dir, Self.streamCount, Int32((60 * fps).rounded()), queueBytes, 0) else {
                return L("리플레이 저장소를 열 수 없음")
            }
            lock.lock()
            store = st
            reportedDrops = 0
            reportedWriteErrors = 0
            recCodec = settings.codec
            liveFrames = Array(repeating: nil, count: Self.cams)
            head = -1
            clockAnchors = []
            lock.unlock()
            events.removeAll()
            pendingIn = nil
        }
        lock.lock()
        recCameras = slots
        needAnchor = true
        let st = store
        lock.unlock()
        guard let st = st else { return L("리플레이 저장소를 열 수 없음") }
        var opened = 0
        for k in 0..<Self.cams where slots[k] != nil {
            if let (o, s) = openEncoder(slot: k, store: st) {
                lock.lock(); outs[k] = o; sinks[k] = s; lock.unlock()
                opened += 1
            }
        }
        guard opened > 0 else { return L("리플레이 인코더를 시작할 수 없음") }
        recording = true
        recordingStartedAt = Date()
        refreshLimit()
        startPlayer()
        prepareAI()
        if statusTimer == nil {
            let t = Timer(timeInterval: 1, repeats: true) { [weak self] _ in self?.refreshStatus() }
            RunLoop.main.add(t, forMode: .common)
            statusTimer = t
        }
        return nil
    }

    func stopRecording() {
        guard recording else { return }
        lock.lock()
        let o = outs, s = sinks
        outs = Array(repeating: nil, count: Self.cams)
        sinks = Array(repeating: nil, count: Self.cams)
        lock.unlock()
        recording = false
        encoderCloses.enter()
        DispatchQueue.global(qos: .userInitiated).async {
            for h in o.compactMap({ $0 }) { mc_output_close(h) }          // flushes the last frames into the store
            for k in s.compactMap({ $0 }) { mc_replay_sink_free(k) }
            self.encoderCloses.leave()
        }
        refreshStatus()
    }

    /// Deletes all recorded footage and events.
    func clearAll() {
        let was = recording
        stopRecording()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            self.closeStore()
            self.events.removeAll()
            self.pendingIn = nil
            self.refreshStatus()
            if was { _ = self.startRecording() }
        }
    }

    private func closeStore() {
        // Encoders still flushing write into the store from their threads: let them finish first.
        encoderCloses.wait()
        lock.lock()
        let st = store
        store = nil
        recCameras = Array(repeating: nil, count: Self.cams)
        liveFrames = Array(repeating: nil, count: Self.cams)
        head = -1
        clockAnchors = []
        let clips = aiIndex
        aiIndex = []
        aiEpoch += 1
        for i in 0..<2 { ch[i] = ChannelState() }
        lock.unlock()
        aiClips = [:]
        aiQueue.sync {}      // a running clip render sees the new epoch within one frame and stops
        exportQueue.sync {}  // a running clip export too (same epoch check)
        queue.sync {
            for c in 0..<2 {
                if let d = decoders[c] { mc_replay_dec_close(d) }
                if let d = aiDecoders[c] { mc_replay_dec_close(d) }
                decoders[c] = nil; aiDecoders[c] = nil
                frameCache[c] = []
            }
            for clip in clips { mc_replay_store_close(clip.store, 1) }
            if let st = st { mc_replay_store_close(st, 1) }
        }
    }

    /// Render thread, once per tick (after the audio mix).
    func renderHook(tick: Int64, audio: UnsafePointer<Float>, frames n: Int,
                    sourceAudio: (UUID) -> UnsafePointer<Float>?, render: (UUID) -> CVPixelBuffer?) {
        lock.lock()
        let cams = recCameras, o = outs, st = store
        lock.unlock()
        guard let st = st else { return }
        var live = [CVPixelBuffer?](repeating: nil, count: Self.cams)
        var recordingNow = false
        for k in 0..<Self.cams {
            guard let id = cams[k], let pb = render(id) else { continue }
            live[k] = pb
            if let out = o[k] {
                mc_output_push_pixelbuffer(out, Unmanaged.passUnretained(pb).toOpaque(), tick)
                recordingNow = true
            }
        }
        // each CAM's own audio (silence for a source without audio), so a replay angle sounds like its camera
        var camAudio = [UnsafePointer<Float>?](repeating: nil, count: Self.cams)
        if recordingNow, n > 0, n <= 48_000 {
            for k in 0..<Self.cams where o[k] != nil {
                guard let id = cams[k] else { continue }
                camAudio[k] = sourceAudio(id) ?? UnsafePointer(Self.silence)
            }
        }
        lock.lock()
        // The store writes only copy into its queue (its writer thread does the disk I/O), so they are cheap
        // enough to do under the lock — which keeps closeStore from freeing the store mid-write.
        if recordingNow, n > 0, store == st {
            let bytes = Int32(n * 2 * MemoryLayout<Float>.size)
            mc_replay_store_write(st, Self.audioStream, tick, UnsafeRawPointer(audio).assumingMemoryBound(to: UInt8.self), bytes)
            for k in 0..<Self.cams {
                guard let p = camAudio[k] else { continue }
                mc_replay_store_write(st, Self.camAudioStream(k), tick, UnsafeRawPointer(p).assumingMemoryBound(to: UInt8.self), bytes)
            }
        }
        liveFrames = live
        if recordingNow {
            head = tick
            // Re-anchor tick → wall clock every second: render-loop catch-ups never accumulate.
            if needAnchor || (clockAnchors.last.map { tick - $0.tick >= 60 } ?? true) {
                clockAnchors.append((tick, Date().timeIntervalSince1970))
                needAnchor = false
            }
        }
        lock.unlock()
    }

    /// Wall-clock time a frame was recorded (nil before anything was recorded).
    func wallTime(_ frame: Int64) -> Date? {
        lock.lock(); defer { lock.unlock() }
        guard !clockAnchors.isEmpty else { return nil }
        var lo = 0, hi = clockAnchors.count - 1
        while lo < hi {
            let mid = (lo + hi + 1) / 2
            if clockAnchors[mid].tick <= frame { lo = mid } else { hi = mid - 1 }
        }
        let a = clockAnchors[lo]
        return Date(timeIntervalSince1970: a.time + Double(frame - a.tick) / fps)
    }

    private func firstFrame(_ st: OpaquePointer) -> Int64 { mc_replay_store_first(st, Self.audioStream) }

    // MARK: Disk limit / status

    private static let reserve: Int64 = 5_000_000_000

    private func refreshLimit() {
        lock.lock(); let st = store; lock.unlock()
        guard let st = st else { return }
        let used = mc_replay_store_bytes(st)
        let free = OutputConfig.freeSpace(at: settings.folderPath) ?? 0
        var limit: Int64 = 0
        if settings.autoDelete {
            let room = used + max(0, free - ReplayEngine.reserve)
            limit = settings.maxGB > 0 ? min(Int64(settings.maxGB * 1e9), room) : room
            limit = max(limit, 1_000_000_000)
        } else if settings.maxGB > 0 {
            limit = Int64(settings.maxGB * 1e9)
        }
        mc_replay_store_set_limit(st, settings.autoDelete || settings.maxGB > 0 ? limit : 0)
        status.limitBytes = limit
    }

    private var lastLimitRefresh = Date.distantPast

    func refreshStatus() {
        lock.lock()
        let st = store, cams = recCameras.compactMap { $0 }.count, h = head
        if let st = st {
            // drop clock anchors older than the oldest footage (keep the one that covers it)
            let first = firstFrame(st)
            if first >= 0, clockAnchors.count > 2,
               let k = clockAnchors.lastIndex(where: { $0.tick <= first }), k > 0 {
                clockAnchors.removeFirst(k)
            }
        }
        lock.unlock()
        var s = status
        s.cameras = cams
        if let st = st {
            let first = firstFrame(st)
            s.bufferedSeconds = first >= 0 && h >= first ? Double(h - first) / fps : 0
            s.bytes = mc_replay_store_bytes(st)
            // The disk could not keep up (queue full → packets dropped) or failed: say so, never stall the program.
            var qs = mc_replay_store_stats()
            mc_replay_store_get_stats(st, &qs)
            var problems: [String] = []
            if qs.dropped_packets > 0 { problems.append(Lf("리플레이 디스크가 느려 패킷 %@개를 버림", "\(qs.dropped_packets)")) }
            if qs.write_errors > 0 { problems.append(Lf("리플레이 디스크 쓰기 실패 %@회", "\(qs.write_errors)")) }
            s.error = problems.isEmpty ? nil : problems.joined(separator: " · ")
            if qs.dropped_packets > reportedDrops || qs.write_errors > reportedWriteErrors {
                reportedDrops = qs.dropped_packets
                reportedWriteErrors = qs.write_errors
                engine?.blackbox.record(.outputError, s.error ?? "")
                engine?.lastMessage = s.error ?? ""
            }
        } else {
            s.bufferedSeconds = 0; s.bytes = 0; s.error = nil
        }
        s.free = OutputConfig.freeSpace(at: settings.folderPath) ?? 0
        let perHour = Double(estimate(cameras: max(1, cams > 0 ? cams : settings.assignedCount)).perHour)
        s.hoursLeft = perHour > 0 ? Double(max(0, s.free - ReplayEngine.reserve)) / perHour : 0
        if s != status { status = s }
        if Date().timeIntervalSince(lastLimitRefresh) > 5 { lastLimitRefresh = Date(); refreshLimit() }
    }

    /// Estimated recording time for the given settings and disk (shown before recording starts).
    func estimate(cameras: Int) -> (perHour: Int64, hours: Double, free: Int64) {
        let fmt = engine?.format ?? format
        let free = OutputConfig.freeSpace(at: settings.folderPath) ?? 0
        let kbps = settings.kbpsPerCamera(width: fmt.width, height: fmt.height, fps: fmt.fps)
        let perHour = Int64((kbps * 1000 / 8 * Double(max(1, cameras)) + 48_000 * 8) * 3600)
        let usable = settings.maxGB > 0 ? min(Int64(settings.maxGB * 1e9), free - ReplayEngine.reserve) : free - ReplayEngine.reserve
        return (perHour, perHour > 0 ? Double(max(0, usable)) / Double(perHour) : 0, free)
    }

    // MARK: Player

    private func startPlayer() {
        guard timer == nil else { return }
        let t = DispatchSource.makeTimerSource(flags: .strict, queue: queue)
        let interval = 1.0 / max(1, (engine?.format.fps ?? 59.94))
        t.schedule(deadline: .now(), repeating: interval, leeway: .milliseconds(1))
        t.setEventHandler { [weak self] in self?.playerTick() }
        t.resume()
        timer = t
    }

    private func pixelBuffer() -> CVPixelBuffer? {
        let w = format.width, h = format.height
        if pool == nil || poolSize != (w, h) {
            pool = PixelBufferFactory.makePool(width: w, height: h, minimumCount: 10)
            poolSize = (w, h)
        }
        guard let p = pool else { return nil }
        return PixelBufferFactory.makeBuffer(pool: p)
    }

    private static func decodeInto(_ dec: OpaquePointer, _ data: UnsafeMutablePointer<UInt8>, _ n: Int32, _ pb: CVPixelBuffer,
                                   _ w: Int, _ h: Int) -> Bool {
        CVPixelBufferLockBaseAddress(pb, [])
        defer { CVPixelBufferUnlockBaseAddress(pb, []) }
        guard let base = CVPixelBufferGetBaseAddress(pb) else { return false }
        return mc_replay_dec_decode(dec, data, n, base.assumingMemoryBound(to: UInt8.self),
                                    Int32(CVPixelBufferGetBytesPerRow(pb)), Int32(w), Int32(h)) == 0
    }

    /// Hardware (VideoToolbox) decode → NV12 IOSurface the GPU reads directly; software → BGRA.
    private static func decodeHW(_ dec: OpaquePointer, _ data: UnsafeMutablePointer<UInt8>, _ n: Int32, _ w: Int, _ h: Int) -> CVPixelBuffer? {
        var out: UnsafeMutableRawPointer?
        guard mc_replay_dec_decode_pb(dec, data, n, Int32(w), Int32(h), &out) == 0, let p = out else { return nil }
        return Unmanaged<CVPixelBuffer>.fromOpaque(p).takeRetainedValue()
    }

    /// Player queue: decoded recorded frame (cached: slow motion reuses the last few frames).
    private func frame(_ f: Int64, cam: Int, st: OpaquePointer, channel c: Int, kind: Int) -> CVPixelBuffer? {
        if let hit = frameCache[c].first(where: { $0.frame == f && $0.cam == cam }) { return hit.pb }
        var data: UnsafeMutablePointer<UInt8>?
        var got: Int64 = 0
        let n = mc_replay_store_read(st, Int32(cam), f, &data, &got)
        guard n > 0, let d = data else { return nil }
        defer { free(d) }
        if decoderKind != kind {
            for k in 0..<2 { if let x = decoders[k] { mc_replay_dec_close(x) }; decoders[k] = nil }
            decoderKind = kind
        }
        if decoders[c] == nil { decoders[c] = mc_replay_dec_open_hw(Int32(kind)) }
        guard let dec = decoders[c], let pb = Self.decodeHW(dec, d, n, format.width, format.height) else { return nil }
        frameCache[c].append((f, cam, pb))
        if frameCache[c].count > 4 { frameCache[c].removeFirst() }
        return pb
    }

    /// Player queue: AI-rendered in-between frame of a clip (quarter phases 1…3).
    private func aiFrame(_ clip: AIClipRef, frame f: Int64, quarter k: Int, channel c: Int) -> CVPixelBuffer? {
        let idx = (f - clip.inFrame) * 4 + Int64(k)
        var data: UnsafeMutablePointer<UInt8>?
        var got: Int64 = 0
        let n = mc_replay_store_read(clip.store, 0, idx, &data, &got)
        guard n > 0, let d = data else { return nil }
        defer { free(d) }
        guard got == idx else { return nil }
        if aiDecoders[c] == nil { aiDecoders[c] = mc_replay_dec_open_hw(2) }
        return aiDecoders[c].flatMap { Self.decodeHW($0, d, n, format.width, format.height) }
    }

    private func playerTick() {
        lock.lock()
        let st = store, h = head, live = liveFrames
        let kind = ReplaySettings.codecKind(recCodec)
        let first = st.map { firstFrame($0) } ?? -1
        var states = ch
        let targets = inputsByChannel
        let clips = aiIndex
        let smooth = playerSmooth, useAI = playerAI, audioFollow = playerAudioFollow
        lock.unlock()
        var finishedChannels: [Int] = []
        for c in 0..<2 {
            var s = states[c]
            let ins = targets[c] ?? []
            func show(_ pb: CVPixelBuffer) {
                deckSlots[c].ingest(pixelBuffer: pb)
                for i in ins { i.video.ingest(pixelBuffer: pb) }
            }
            if s.live {
                if s.camera < live.count, let pb = live[s.camera] { show(pb) }
                s.smoothing = ""
                states[c] = s
                continue
            }
            guard let st = st else { continue }
            if s.playing {
                s.pos += (s.reverse ? -1 : 1) * s.speed
                if let stop = s.stopFrame, !s.reverse, s.pos >= Double(stop) {
                    s.pos = Double(stop); s.playing = false; s.finished = true
                }
                if s.reverse, first >= 0, s.pos <= Double(first) { s.pos = Double(first); s.playing = false }
                if !s.reverse, h >= 0, s.pos >= Double(h) { s.pos = Double(h) }
            }
            if first >= 0 { s.pos = max(Double(first), s.pos) }
            let f = Int64(s.pos.rounded(.down))
            let phase = s.pos - Double(f)
            var smoothed: CVPixelBuffer?
            var mode = ""
            // Slow motion between two recorded frames: AI clip → real-time AI → GPU blend.
            let unchangedStill = !s.playing && s.shownSmooth && s.shownPos == s.pos && s.shownCamera == s.camera
            if s.speed < 0.99, phase > 0.02, phase < 0.98, h < 0 || f + 1 <= h, !unchangedStill {
                let k = Int((phase * 4).rounded())
                if useAI, k >= 1, k <= 3,
                   let clip = clips.first(where: { $0.camera == s.camera && f >= $0.inFrame && f < $0.outFrame }),
                   let pb = aiFrame(clip, frame: f, quarter: k, channel: c) {
                    smoothed = pb; mode = "AI"
                } else if let a = frame(f, cam: s.camera, st: st, channel: c, kind: kind),
                          let b = frame(f + 1, cam: s.camera, st: st, channel: c, kind: kind) {
                    if useAI, let rt = rtAI, let p = pool,
                       let out = rt.interpolate(a, b, phases: [Float(phase)], bgraPool: p)?.first {
                        smoothed = out; mode = "AI RT"
                    } else if smooth, let dst = pixelBuffer(), blender.blend(a, b, phase: phase, into: dst) {
                        smoothed = dst; mode = "BLEND"
                    }
                }
            }
            if let pb = smoothed {
                show(pb)
                s.shown = f; s.shownCamera = s.camera; s.shownSmooth = true; s.shownPos = s.pos
            } else if unchangedStill {
                mode = s.smoothing
            } else if f != s.shown || s.camera != s.shownCamera || s.shownSmooth {
                if let pb = frame(f, cam: min(s.camera, Self.cams - 1), st: st, channel: c, kind: kind) {
                    show(pb)
                    s.shown = f; s.shownCamera = s.camera; s.shownSmooth = false
                }
            }
            s.smoothing = mode
            // audio only at normal forward speed (no time-stretch)
            if s.playing && !s.reverse && abs(s.speed - 1) < 0.001, !ins.isEmpty {
                var data: UnsafeMutablePointer<UInt8>?
                var got: Int64 = 0
                // the shown angle's own audio; program audio if that CAM has none for this frame
                var n = audioFollow ? mc_replay_store_read(st, Self.camAudioStream(s.camera), f, &data, &got) : -1
                if n <= 0 || got != f {
                    if let d = data { free(d); data = nil }
                    n = mc_replay_store_read(st, Self.audioStream, f, &data, &got)
                }
                if n > 0, let d = data {
                    if got == f {
                        d.withMemoryRebound(to: Float.self, capacity: Int(n) / 4) { p in
                            for i in ins { i.noteAudioFrame(); i.audio.write(p, frames: Int(n) / 8) }
                        }
                    }
                    free(d)
                }
            }
            if s.finished { s.finished = false; finishedChannels.append(c) }
            states[c] = s
        }
        lock.lock()
        // keep the user's latest changes; only take over what the player advanced
        for c in 0..<2 {
            ch[c].smoothing = states[c].smoothing
            guard ch[c].gen == states[c].gen && !states[c].live else { continue }
            ch[c].pos = states[c].pos
            ch[c].shown = states[c].shown
            ch[c].shownCamera = states[c].shownCamera
            ch[c].shownSmooth = states[c].shownSmooth
            ch[c].shownPos = states[c].shownPos
            ch[c].playing = states[c].playing
        }
        lock.unlock()
        if !finishedChannels.isEmpty {
            DispatchQueue.main.async { self.eventFinished(channels: finishedChannels) }
        }
        uiCounter += 1
        if uiCounter % 6 == 0 { DispatchQueue.main.async { self.publishUI() } }
    }

    private func publishUI() {
        lock.lock()
        let h = head
        var ui = [ReplayChannelUI(), ReplayChannelUI()]
        for c in 0..<2 {
            let s = ch[c]
            ui[c] = ReplayChannelUI(live: s.live, camera: s.camera, playing: s.playing, speed: s.speed, reverse: s.reverse,
                                    position: s.live ? max(0, h) : Int64(s.pos),
                                    behindLive: s.live || h < 0 ? 0 : Double(h) / fps - s.pos / fps,
                                    eventNumber: s.eventNumber, attached: !(inputsByChannel[c] ?? []).isEmpty,
                                    smoothing: s.smoothing)
        }
        lock.unlock()
        if ui != channelsUI { channelsUI = ui }
    }

    private func modify(_ channels: Set<Int>? = nil, _ f: (inout ChannelState, Int64) -> Void) {
        lock.lock()
        let h = head
        for c in channels ?? selected where c < 2 { f(&ch[c], h); ch[c].gen += 1 }
        lock.unlock()
        publishUI()
    }

    // MARK: AI slow motion

    /// Loads the ML interpolator for the program size in the background, measures this Mac once,
    /// and decides between real-time AI and background AI clips.
    func prepareAI() {
        guard settings.aiSlow else { return }
        guard ReplayCaps.aiSupported else {
            aiInfo = L("이 맥/macOS 는 AI 보간 미지원 — GPU 블렌딩으로 부드럽게")
            return
        }
        let fmt = engine?.format ?? format
        let w = fmt.width, h = fmt.height, rate = fmt.fps
        lock.lock(); let ready = bgAI != nil && aiPreparedSize == (w, h); lock.unlock()
        if ready { return }
        aiInfo = L("AI 모델 준비 중… (이 맥에서 처음 한 번 10초 정도)")
        aiLoadQueue.async {
            lock_: do {
                self.lock.lock(); let done = self.bgAI != nil && self.aiPreparedSize == (w, h); self.lock.unlock()
                if done { break lock_ }
                guard let ai = AIInterpolator(width: w, height: h),
                      let p = PixelBufferFactory.makePool(width: w, height: h, minimumCount: 4) else {
                    DispatchQueue.main.async { self.aiInfo = L("AI 보간을 시작할 수 없음 — GPU 블렌딩 사용") }
                    return
                }
                let cost = ReplayCaps.aiCostMs(width: w, height: h) ?? ai.measure(bgraPool: p) ?? 999
                self.lock.lock(); self.bgAI = ai; self.aiPreparedSize = (w, h); self.lock.unlock()
                let realtime = ReplayCaps.aiRealtime(width: w, height: h, fps: rate)
                if realtime {
                    let rt = AIInterpolator(width: w, height: h)
                    self.queue.async { self.rtAI = rt }
                }
                DispatchQueue.main.async {
                    self.aiInfo = realtime
                        ? Lf("AI 실시간 보간 (%@ · %@ ms/프레임)", ReplayCaps.chip, String(format: "%.0f", cost))
                        : Lf("AI 클립 백그라운드 렌더 + 실시간 GPU 블렌딩 (%@ · %@ ms/프레임)", ReplayCaps.chip, String(format: "%.0f", cost))
                }
            }
        }
    }

    private var aiRealtimeActive: Bool {
        let fmt = engine?.format ?? format
        return ReplayCaps.aiRealtime(width: fmt.width, height: fmt.height, fps: fmt.fps)
    }

    /// Renders AI in-between frames (¼, ½, ¾) of a clip in the background. Slow Macs only; on fast
    /// Macs playback interpolates in real time instead.
    private func scheduleAI(_ e: ReplayEvent) {
        guard settings.aiSlow, ReplayCaps.aiSupported, !aiRealtimeActive else { return }
        lock.lock()
        let st = store, epoch = aiEpoch
        let kind = ReplaySettings.codecKind(recCodec)
        aiCancelled.remove(e.id)
        lock.unlock()
        guard let st = st, e.outFrame > e.inFrame else { return }
        aiClips[e.id] = ReplayAIClipState(camera: e.camera)
        let fmt = format, quality = settings.quality
        let dir = (settings.folderPath as NSString).appendingPathComponent("session-ai/\(e.id.uuidString)")
        aiQueue.async { [weak self] in
            self?.renderAIClip(e, store: st, kind: kind, epoch: epoch, fmt: fmt, quality: quality, dir: dir)
        }
    }

    private func renderAIClip(_ e: ReplayEvent, store st: OpaquePointer, kind: Int, epoch: Int, fmt: VideoFormat,
                              quality: Int, dir: String) {
        func cancelled() -> Bool {
            lock.lock(); defer { lock.unlock() }
            return aiEpoch != epoch || aiCancelled.contains(e.id)
        }
        func finish(failed: Bool) {
            DispatchQueue.main.async {
                if failed { self.aiClips[e.id]?.failed = true }
            }
        }
        // The model loads on aiLoadQueue; wait for it here, staying cancellable.
        var model: AIInterpolator?
        for _ in 0..<1200 {
            if cancelled() { return }
            lock.lock()
            if aiPreparedSize == (fmt.width, fmt.height) { model = bgAI }
            lock.unlock()
            if model != nil { break }
            Thread.sleep(forTimeInterval: 0.05)
        }
        guard let ai = model, let pool = PixelBufferFactory.makePool(width: fmt.width, height: fmt.height, minimumCount: 8),
              let dec = mc_replay_dec_open_codec(Int32(kind)) else { return finish(failed: true) }
        defer { mc_replay_dec_close(dec) }
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        // offline render: wait for the disk rather than drop frames
        guard let ast = mc_replay_store_open2(dir, 1, 4 * 3600, 32_000_000, 1),
              let sink = mc_replay_sink_new(ast, 0) else { return finish(failed: true) }
        var cfg = mc_output_config()
        cfg.width = Int32(fmt.width); cfg.height = Int32(fmt.height)
        cfg.fps_num = Int32(fmt.fpsNum); cfg.fps_den = Int32(fmt.fpsDen)
        cfg.video_kbps = -72                    // HEVC intra, constant quality (high)
        cfg.audio_kbps = 64
        cfg.keyint_frames = 1
        cfg.hardware = 1
        cfg.pixelbuffer_input = 1
        cfg.packet_cb = mc_replay_sink_cb
        cfg.packet_user = UnsafeMutableRawPointer(sink)
        let u = strdup("replay:"), f = strdup("null"), v = strdup("hevc")
        cfg.url = UnsafePointer(u); cfg.format = UnsafePointer(f); cfg.video_codec = UnsafePointer(v)
        let out = mc_output_open(&cfg, nil, nil)
        free(u); free(f); free(v)
        guard let out = out else {
            mc_replay_sink_free(sink); mc_replay_store_close(ast, 1)
            return finish(failed: true)
        }
        func decode(_ frame: Int64) -> CVPixelBuffer? {
            var data: UnsafeMutablePointer<UInt8>?
            var got: Int64 = 0
            let n = mc_replay_store_read(st, Int32(e.camera), frame, &data, &got)
            guard n > 0, let d = data else { return nil }
            defer { free(d) }
            guard let pb = PixelBufferFactory.makeBuffer(pool: pool),
                  Self.decodeInto(dec, d, n, pb, fmt.width, fmt.height) else { return nil }
            return pb
        }
        var ok = true
        var prev = decode(e.inFrame)
        let total = Double(e.outFrame - e.inFrame)
        for fr in e.inFrame..<e.outFrame {
            if cancelled() { ok = false; break }
            let next = decode(fr + 1)
            if let a = prev, let b = next {
                let t0 = CACurrentMediaTime()
                if let mids = ai.interpolate(a, b, phases: [0.25, 0.5, 0.75], bgraPool: pool) {
                    for (k, pb) in mids.enumerated() {
                        mc_output_push_pixelbuffer(out, Unmanaged.passUnretained(pb).toOpaque(), (fr - e.inFrame) * 4 + Int64(k + 1))
                    }
                }
                // Leave GPU time for the live program: never use more than ~2/3 of the GPU.
                let spent = CACurrentMediaTime() - t0
                Thread.sleep(forTimeInterval: max(0.004, spent * 0.5))
                // keep the encoder queue (8 frames) from overflowing
                var stt = mc_output_stats()
                for _ in 0..<50 {
                    mc_output_get_stats(out, &stt)
                    if stt.queue_depth <= 3 { break }
                    Thread.sleep(forTimeInterval: 0.005)
                }
            }
            prev = next
            if (fr - e.inFrame) % 15 == 0 {
                let p = Double(fr - e.inFrame) / max(1, total)
                DispatchQueue.main.async { self.aiClips[e.id]?.progress = p }
            }
        }
        mc_output_close(out)                // flush the last frames into the clip store
        mc_replay_sink_free(sink)
        mc_replay_store_flush(ast)          // on disk before playback (readers would also find it queued)
        lock.lock()
        let stillValid = ok && aiEpoch == epoch && !aiCancelled.contains(e.id)
        if stillValid {
            aiIndex.removeAll { $0.id == e.id }
            aiIndex.append(AIClipRef(id: e.id, inFrame: e.inFrame, outFrame: e.outFrame, camera: e.camera, store: ast))
        }
        lock.unlock()
        if !stillValid {
            mc_replay_store_close(ast, 1)
            return
        }
        DispatchQueue.main.async {
            if self.aiClips[e.id] != nil {
                self.aiClips[e.id]?.progress = 1
                self.aiClips[e.id]?.ready = true
            }
        }
    }

    /// Drops an event's AI clip (deleted, or its angle changed).
    private func dropAI(_ id: UUID) {
        lock.lock()
        aiCancelled.insert(id)
        let clips = aiIndex.filter { $0.id == id }
        aiIndex.removeAll { $0.id == id }
        lock.unlock()
        aiClips[id] = nil
        // close on the player queue: a tick may still hold the clip from its snapshot
        queue.async { for c in clips { mc_replay_store_close(c.store, 1) } }
    }

    // MARK: Transport (selected channels)

    func goLive(_ channels: Set<Int>? = nil) {
        modify(channels) { s, _ in s.live = true; s.playing = false; s.stopFrame = nil; s.eventNumber = nil }
    }

    /// Leaves live mode at the current moment (frozen on "now").
    private func enterReplay(_ s: inout ChannelState, _ h: Int64) {
        if s.live { s.live = false; s.pos = Double(max(0, h)); s.shown = -1 }
    }

    func playPause() {
        modify { s, h in
            self.enterReplay(&s, h)
            if !s.playing, let stop = s.stopFrame, s.pos >= Double(stop) { s.stopFrame = nil }
            s.playing.toggle()
        }
    }

    func play() { modify { s, h in self.enterReplay(&s, h); s.playing = true } }
    func pause() { modify { s, h in self.enterReplay(&s, h); s.playing = false } }

    func jump(frames: Int) {
        modify { s, h in
            self.enterReplay(&s, h)
            s.pos = min(Double(max(h, 0)), max(0, s.pos.rounded(.down) + Double(frames)))
            s.stopFrame = nil
        }
    }

    func jump(seconds: Double) { jump(frames: Int((seconds * fps).rounded())) }

    func setSpeed(_ v: Double) { modify { s, _ in s.speed = max(0.05, min(4, v)) } }
    func changeSpeed(by d: Double) { modify { s, _ in s.speed = max(0.05, min(4, s.speed + d)) } }
    func setReverse(_ on: Bool) { modify { s, _ in s.reverse = on } }

    func setCamera(_ k: Int, channels: Set<Int>? = nil) {
        modify(channels) { s, _ in s.camera = max(0, min(ReplaySettings.maxCameras - 1, k)) }
    }

    // MARK: Events

    /// Mark In at the replay position (when replaying) or at "now" (live).
    func markIn() {
        let at = markPoint()
        pendingIn = at
    }

    func markOut() {
        let out = markPoint()
        guard let i = pendingIn else { return markInOut(seconds: 5) }
        addEvent(inFrame: min(i, out), outFrame: max(i, out))
        pendingIn = nil
    }

    /// Event of the last N seconds (one button, like "-5 s / -10 s / -20 s").
    func markInOut(seconds: Double) {
        let out = markPoint()
        addEvent(inFrame: max(0, out - Int64(seconds * fps)), outFrame: out)
        pendingIn = nil
    }

    private func markPoint() -> Int64 {
        lock.lock(); defer { lock.unlock() }
        let c = selected.min() ?? 0
        return ch[c].live ? head : Int64(ch[c].pos)
    }

    private func addEvent(inFrame: Int64, outFrame: Int64) {
        guard outFrame > inFrame, outFrame >= 0 else { return }
        lock.lock(); let cam = ch[selected.min() ?? 0].camera; lock.unlock()
        let n = (events.map { $0.number }.max() ?? 0) + 1
        let e = ReplayEvent(number: n, inFrame: inFrame, outFrame: outFrame, camera: cam)
        events.append(e)
        scheduleAI(e)
    }

    func deleteEvent(_ id: UUID) {
        events.removeAll { $0.id == id }
        dropAI(id)
    }

    func deleteLastEvent() {
        if let e = events.last { deleteEvent(e.id) }
    }

    func renameEvent(_ id: UUID, _ name: String) {
        if let i = events.firstIndex(where: { $0.id == id }) { events[i].name = name }
    }

    func setEventCamera(_ id: UUID, _ cam: Int) {
        guard let i = events.firstIndex(where: { $0.id == id }), events[i].camera != cam else { return }
        events[i].camera = cam
        dropAI(id)
        scheduleAI(events[i])
    }

    func playEvent(_ e: ReplayEvent, channels: Set<Int>? = nil) {
        let pre = Int64(settings.preRoll * fps)
        modify(channels) { s, _ in
            s.live = false
            s.camera = e.camera
            s.pos = Double(max(0, e.inFrame - pre))
            s.stopFrame = e.outFrame
            s.playing = true
            s.reverse = false
            s.shown = -1
            s.eventNumber = e.number
        }
    }

    func playLastEvent() {
        if let e = events.last { playEvent(e) }
    }

    /// Plays the last event on Replay A and puts Replay A on air; returns to the previous input at the end.
    func replayToProgram() -> String? {
        guard let e = engine else { return nil }
        guard let ev = events.last else { return L("이벤트가 없습니다 (Mark In/Out 먼저)") }
        guard let a = e.inputs.first(where: { ($0 as? ReplayInput)?.channel == 0 }) else {
            return L("Replay A 입력이 없습니다 — 입력 추가 › Instant Replay")
        }
        if e.programID != a.id { returnToID = e.programID }
        playEvent(ev, channels: [0])
        if e.programID != a.id { e.cutDirect(a.id) }
        return nil
    }

    private func eventFinished(channels: [Int]) {
        guard channels.contains(0), settings.autoReturn, let back = returnToID, let e = engine,
              let a = e.inputs.first(where: { ($0 as? ReplayInput)?.channel == 0 }), e.programID == a.id else { return }
        returnToID = nil
        if e.input(withID: back) != nil { e.cutDirect(back) }
    }

    // MARK: Timecode

    func timecode(_ frame: Int64) -> String {
        lock.lock(); let st = store; lock.unlock()
        let first = st.map { firstFrame($0) } ?? 0
        return elapsedTimecode(frames: max(0, frame - max(0, first)))
    }

    func recordTimecode() -> String {
        lock.lock(); let st = store, h = head; lock.unlock()
        guard let st = st, h >= 0 else { return "00:00:00:00" }
        let first = firstFrame(st)
        return elapsedTimecode(frames: first >= 0 ? max(0, h - first) : 0)
    }

    func selectedTimecode() -> String {
        let c = selected.min() ?? 0
        return timecode(channelsUI[c].position)
    }

    /// Recording time (system clock) of the selected deck's position.
    func selectedClock() -> String {
        let c = selected.min() ?? 0
        return recordedClockTimecode(channelsUI[c].position)
    }

    func systemTimecode(_ date: Date = Date()) -> String {
        let cal = Calendar.current
        let c = cal.dateComponents([.hour, .minute, .second, .nanosecond], from: date)
        let rate = max(1, Int(fps.rounded()))
        let frame = min(rate - 1, Int((Double(c.nanosecond ?? 0) / 1_000_000_000.0) * Double(rate)))
        return String(format: "%02d:%02d:%02d:%02d", c.hour ?? 0, c.minute ?? 0, c.second ?? 0, frame)
    }

    /// Wall-clock time (HH:MM:SS:FF) at which a replay frame was recorded.
    func recordedClockTimecode(_ frame: Int64) -> String {
        guard let d = wallTime(frame) else { return "--:--:--:--" }
        return systemTimecode(d)
    }

    func recordingStartText() -> String {
        guard let date = recordingStartedAt else { return "--:--:--" }
        return date.formatted(date: .omitted, time: .standard)
    }

    func timelineBounds() -> ClosedRange<Double> {
        lock.lock(); let st = store, h = head; lock.unlock()
        guard let st = st, h >= 0 else { return 0...1 }
        let first = firstFrame(st)
        let lo = Double(max(0, first))
        return lo...max(lo + 1, Double(h))
    }

    func seekTimeline(_ frame: Double, channel: Int) {
        modify([channel]) { s, h in
            s.live = frame >= Double(h - 1)
            s.pos = max(0, min(Double(h), frame.rounded(.down)))
            s.playing = false
            s.shown = -1
            s.eventNumber = nil
        }
    }

    func pendingDuration() -> String? {
        guard let i = pendingIn else { return nil }
        let out = markPoint()
        return elapsedTimecode(frames: abs(out - i))
    }

    private func elapsedTimecode(frames: Int64) -> String {
        let rate = max(1, Int(fps.rounded()))
        let seconds = Int(Double(frames) / fps)
        let base = Int64((Double(seconds) * fps).rounded(.down))
        let ff = max(0, min(rate - 1, Int(frames - base)))
        return String(format: "%02d:%02d:%02d:%02d", seconds / 3600, (seconds / 60) % 60, seconds % 60, ff)
    }

    func duration(_ e: ReplayEvent) -> String { String(format: "%.1fs", Double(e.outFrame - e.inFrame) / fps) }

    // MARK: API (vMix-compatible names)

    func api(_ fn: String, _ value: String, _ q: [String: String]) -> String? {
        let v = Double(value)
        func cam(_ prefix: String) -> Int? {
            guard fn.hasPrefix(prefix), let n = Int(fn.dropFirst(prefix.count)), n >= 1 else { return nil }
            return n - 1
        }
        if let n = cam("replayacamera") { setCamera(n, channels: [0]); return nil }
        if let n = cam("replaybcamera") { setCamera(n, channels: [1]); return nil }
        if let n = cam("replaycamera") { setCamera(n); return nil }
        switch fn {
        case "replaystartrecording": return startRecording()
        case "replaystoprecording": stopRecording()
        case "replaystartstoprecording": if recording { stopRecording() } else { return startRecording() }
        case "replaymarkin", "replaymarkinlive": markIn()
        case "replaymarkout": markOut()
        case "replaymarkinout", "replaymarkinoutlive": markInOut(seconds: v ?? 5)
        case "replayplay": play()
        case "replaypause": pause()
        case "replayplaypause": playPause()
        case "replaylive": goLive()
        case "replayrecorded": modify { s, h in self.enterReplay(&s, h) }
        case "replayplaylastevent": playLastEvent()
        case "replayplaylasteventtooutput", "replayplaytooutput": return replayToProgram()
        case "replayplayevent", "replayplayselectedeventtooutput":
            if let n = Int(value), let e = events.first(where: { $0.number == n }) { playEvent(e) } else { playLastEvent() }
        case "replaydeletelastevent": deleteLastEvent()
        case "replayexportlastevent", "replayexportevent":
            // HongMix: Value=horizontal|vertical|square (default: last used); ReplayExportEvent uses Value2/Selection=event number
            var o = ReplayExportOptions.saved
            switch value.lowercased() {
            case "vertical", "9:16": o.aspect = 1
            case "square", "1:1": o.aspect = 2
            case "horizontal", "16:9": o.aspect = 0
            default: break
            }
            let e: ReplayEvent?
            if fn == "replayexportevent", let n = Int(q["value2"] ?? q["selection"] ?? "") {
                e = events.first { $0.number == n }
            } else {
                e = events.last
            }
            guard let ev = e else { return "No replay clip" }
            export([ev], options: o)
        case "replaysetspeed": if let v = v { setSpeed(v > 4 ? v / 100 : v) }
        case "replaychangespeed": if let v = v { changeSpeed(by: v) }
        case "replayjumpframes": jump(frames: Int(v ?? 0))
        case "replayjumpseconds": jump(seconds: v ?? 0)
        case "replayfastforward": setReverse(false); setSpeed(2); play()
        case "replayfastbackward": setReverse(true); setSpeed(2); play()
        case "replayforward": setReverse(false)
        case "replayreverse": setReverse(true)
        case "replayselectchannela": selected = [0]
        case "replayselectchannelb": selected = [1]
        case "replayselectchannelab": selected = [0, 1]
        default: return "Not supported in HongMix: \(fn)"
        }
        return nil
    }
}

// MARK: - Clip export (Replay › ⬇ — highlight clips for social media / the edit)

struct ReplayExportOptions: Codable, Equatable {
    /// 0 = 16:9 (programme size) · 1 = 9:16 (1080×1920) · 2 = 1:1 (1080×1080)
    var aspect = 0
    /// horizontal crop centre for 9:16 / 1:1 (0 = left edge, 0.5 = centre, 1 = right edge)
    var cropX = 0.5
    /// false = the clip's angle · true = one file per recorded angle
    var allAngles = false
    /// 0 = normal · 1 = 50 % slow · 2 = AI slow (25 %, uses the clip's AI frames when ready)
    var speed = 0
    /// seconds added before IN and after OUT
    var pad = 1
    /// "h264" · "hevc" · "prores"
    var codec = "h264"
    var folder = (NSHomeDirectory() as NSString).appendingPathComponent("Movies/HongMix Highlights")

    private static let key = "replayExportOptions"
    static var saved: ReplayExportOptions {
        get {
            guard let d = UserDefaults.standard.data(forKey: key),
                  let o = try? JSONDecoder().decode(ReplayExportOptions.self, from: d) else { return ReplayExportOptions() }
            return o
        }
        set { if let d = try? JSONEncoder().encode(newValue) { UserDefaults.standard.set(d, forKey: key) } }
    }

    func outputSize(programWidth w: Int, programHeight h: Int) -> (Int, Int) {
        switch aspect {
        case 1: return (1080, 1920)
        case 2: let s = min(1080, h); return (s - s % 2, s - s % 2)
        default: return (w, h)
        }
    }
}

extension ReplayEngine {
    private static let exportCI: CIContext = {
        let opts: [CIContextOption: Any] = [.workingColorSpace: NSNull(), .outputColorSpace: NSNull(), .cacheIntermediates: false]
        if let dev = MTLCreateSystemDefaultDevice() { return CIContext(mtlDevice: dev, options: opts) }
        return CIContext(options: opts)
    }()

    /// Exports clips in the background (never touches the live programme or the player).
    func export(_ evs: [ReplayEvent], options o: ReplayExportOptions) {
        lock.lock()
        let st = store, kind = ReplaySettings.codecKind(recCodec), fmt = format, rate = fps
        let recorded = (0..<Self.cams).map { recCameras[$0] != nil }
        let epoch = aiEpoch
        lock.unlock()
        let follow = settings.audioFollowsCamera
        guard let st else { exportMessage = L("녹화된 리플레이가 없습니다"); return }
        try? FileManager.default.createDirectory(atPath: o.folder, withIntermediateDirectories: true)
        for e in evs { exports[e.id] = 0 }
        exportQueue.async { [weak self] in
            guard let self else { return }
            var written: [String] = []
            var failed = 0
            self.lastExportError = ""
            for e in evs {
                let cams = o.allAngles ? (0..<Self.cams).filter { recorded[$0] || $0 == e.camera } : [e.camera]
                for (ci, cam) in cams.enumerated() {
                    let r = self.exportOne(e, cam: cam, options: o, store: st, kind: kind, fmt: fmt, fps: rate, follow: follow, epoch: epoch) { p in
                        let total = (Double(ci) + p) / Double(max(1, cams.count))
                        DispatchQueue.main.async { if self.exports[e.id] != nil { self.exports[e.id] = total } }
                    }
                    if let r { written.append(r) } else if !o.allAngles || cam == e.camera { failed += 1 }
                }
                DispatchQueue.main.async { self.exports[e.id] = nil }
            }
            DispatchQueue.main.async {
                if written.isEmpty {
                    self.exportMessage = L("내보내기 실패 — 이 구간에 녹화된 프레임이 없습니다")
                        + (self.lastExportError.isEmpty ? "" : " (\(self.lastExportError))")
                } else {
                    self.exportMessage = Lf("클립 %@개 저장: %@", "\(written.count)", (o.folder as NSString).abbreviatingWithTildeInPath)
                        + (failed > 0 ? Lf(" · 실패 %@", "\(failed)") : "")
                }
            }
        }
    }

    /// One file. Returns its path, or nil when nothing could be written.
    private func exportOne(_ e: ReplayEvent, cam: Int, options o: ReplayExportOptions, store st: OpaquePointer,
                           kind: Int, fmt: VideoFormat, fps: Double, follow: Bool, epoch: Int, progress: @escaping (Double) -> Void) -> String? {
        let padFrames = Int64((Double(o.pad) * fps).rounded())
        let first = max(mc_replay_store_first(st, Int32(cam)), e.inFrame - padFrames)
        let last = min(mc_replay_store_last(st, Int32(cam)), e.outFrame + padFrames)
        guard last > first else { lastExportError = "range \(first)…\(last)"; return nil }
        let (ow, oh) = o.outputSize(programWidth: fmt.width, programHeight: fmt.height)

        // file name: "Clip 0007 CAM2 9x16 2026-11-09 13.55.12.mp4"
        let df = DateFormatter(); df.dateFormat = "yyyy-MM-dd HH.mm.ss"
        let tag = ["16x9", "9x16", "1x1"][max(0, min(2, o.aspect))]
        let slow = ["", " 50%", " AI-slow"][max(0, min(2, o.speed))]
        let ext = o.codec == "prores" ? "mov" : "mp4"
        let name = String(format: "Clip %04d CAM%d %@%@ %@.%@", e.number, cam + 1, tag, slow, df.string(from: Date()), ext)
        let url = URL(fileURLWithPath: o.folder).appendingPathComponent(name)
        try? FileManager.default.removeItem(at: url)

        let writer: AVAssetWriter
        do { writer = try AVAssetWriter(outputURL: url, fileType: o.codec == "prores" ? .mov : .mp4) }
        catch { lastExportError = "file: \(error.localizedDescription)"; return nil }
        var vset: [String: Any] = [AVVideoWidthKey: ow, AVVideoHeightKey: oh]
        switch o.codec {
        case "prores": vset[AVVideoCodecKey] = AVVideoCodecType.proRes422
        case "hevc":
            vset[AVVideoCodecKey] = AVVideoCodecType.hevc
            vset[AVVideoCompressionPropertiesKey] = [AVVideoAverageBitRateKey: ow * oh * 6]
        default:
            vset[AVVideoCodecKey] = AVVideoCodecType.h264
            vset[AVVideoCompressionPropertiesKey] = [AVVideoAverageBitRateKey: ow * oh * 10,
                                                     AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel]
        }
        let vin = AVAssetWriterInput(mediaType: .video, outputSettings: vset)
        vin.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: vin, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: ow, kCVPixelBufferHeightKey as String: oh,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:]])
        guard writer.canAdd(vin) else { lastExportError = "video settings \(ow)x\(oh) \(o.codec)"; return nil }
        writer.add(vin)
        // audio only at normal speed (the player doesn't time-stretch either)
        let withAudio = o.speed == 0
        var ain: AVAssetWriterInput?
        if withAudio {
            let aset: [String: Any] = o.codec == "prores"
                ? [AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: AudioMixer.rate, AVNumberOfChannelsKey: 2,
                   AVLinearPCMBitDepthKey: 24, AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false,
                   AVLinearPCMIsNonInterleaved: false]
                : [AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: AudioMixer.rate, AVNumberOfChannelsKey: 2,
                   AVEncoderBitRateKey: 192_000]
            let a = AVAssetWriterInput(mediaType: .audio, outputSettings: aset)
            a.expectsMediaDataInRealTime = false
            if writer.canAdd(a) { writer.add(a); ain = a }
        }
        guard writer.startWriting() else { lastExportError = writer.error?.localizedDescription ?? "writer"; return nil }
        writer.startSession(atSourceTime: .zero)

        // same hardware decode path as the replay player (NV12 IOSurface frames Core Image reads directly)
        guard let dec = mc_replay_dec_open_hw(Int32(kind)) else {
            writer.cancelWriting(); lastExportError = "decoder"; return nil
        }
        defer { mc_replay_dec_close(dec) }
        var aiDec: OpaquePointer?
        defer { if let aiDec { mc_replay_dec_close(aiDec) } }
        lock.lock()
        let aiClip = o.speed == 2 ? aiIndex.first { $0.id == e.id && $0.camera == cam } : nil
        lock.unlock()

        func decode(_ f: Int64) -> CVPixelBuffer? {
            var data: UnsafeMutablePointer<UInt8>?
            var got: Int64 = 0
            let n = mc_replay_store_read(st, Int32(cam), f, &data, &got)
            guard n > 0, let d = data else { return nil }
            defer { free(d) }
            return Self.decodeHW(dec, d, n, fmt.width, fmt.height)
        }
        func decodeAI(_ clip: AIClipRef, _ f: Int64, _ k: Int) -> CVPixelBuffer? {
            let idx = (f - clip.inFrame) * 4 + Int64(k)
            var data: UnsafeMutablePointer<UInt8>?
            var got: Int64 = 0
            let n = mc_replay_store_read(clip.store, 0, idx, &data, &got)
            guard n > 0, let d = data, got == idx else { if let d = data { free(d) }; return nil }
            defer { free(d) }
            if aiDec == nil { aiDec = mc_replay_dec_open_hw(2) }
            return aiDec.flatMap { Self.decodeHW($0, d, n, fmt.width, fmt.height) }
        }
        // crop + scale with Core Image
        let srcRect: CGRect = {
            let W = CGFloat(fmt.width), H = CGFloat(fmt.height)
            switch o.aspect {
            case 1, 2:
                let cw = o.aspect == 1 ? H * 9 / 16 : H
                let x = max(0, min(W - cw, (W - cw) * CGFloat(o.cropX)))
                return CGRect(x: x, y: 0, width: cw, height: H)
            default: return CGRect(x: 0, y: 0, width: W, height: H)
            }
        }()
        let sx = CGFloat(ow) / srcRect.width, sy = CGFloat(oh) / srcRect.height
        func convert(_ pb: CVPixelBuffer) -> CVPixelBuffer? {
            guard let pool = adaptor.pixelBufferPool else { return nil }
            var out: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(nil, pool, &out)
            guard let out else { return nil }
            let img = CIImage(cvPixelBuffer: pb).cropped(to: srcRect)
                .transformed(by: CGAffineTransform(translationX: -srcRect.minX, y: -srcRect.minY))
                .transformed(by: CGAffineTransform(scaleX: sx, y: sy))
            Self.exportCI.render(img, to: out, bounds: CGRect(x: 0, y: 0, width: ow, height: oh), colorSpace: nil)
            return out
        }
        let timescale = CMTimeScale(fmt.fpsNum)
        let frameDur = CMTimeValue(fmt.fpsDen)
        let total = Double(last - first + 1)

        // first decodable frame: video and audio both start there (keeps them in sync)
        var startF = first
        while startF < last, decode(startF) == nil { startF += 1 }

        // audio for the whole range (small: ~400 KB per second)
        var audioQueue: [CMSampleBuffer] = []
        if ain != nil {
            var audioSamples: Int64 = 0
            for f in startF...last {
                var data: UnsafeMutablePointer<UInt8>?
                var got: Int64 = 0
                var n = follow ? mc_replay_store_read(st, Self.camAudioStream(cam), f, &data, &got) : -1
                if n <= 0 || got != f {
                    if let d = data { free(d); data = nil }
                    n = mc_replay_store_read(st, Self.audioStream, f, &data, &got)
                }
                let frames = Int(fmt.frameDuration * Double(AudioMixer.rate) + 0.5)
                let floats: [Float]
                if n > 0, got == f, let d = data {
                    floats = Array(UnsafeBufferPointer(start: UnsafeRawPointer(d).assumingMemoryBound(to: Float.self), count: Int(n) / 4))
                } else {
                    floats = [Float](repeating: 0, count: frames * 2)
                }
                if let d = data { free(d) }
                if let sb = Self.audioSample(floats, at: audioSamples) { audioQueue.append(sb) }
                audioSamples += Int64(floats.count / 2)
            }
        }

        // The writer pulls from both tracks when it is ready (Apple's pattern — tracks can't deadlock each other).
        let group = DispatchGroup()
        let vq = DispatchQueue(label: "replay.export.video"), aq = DispatchQueue(label: "replay.export.audio")
        var nextF = startF
        var pending: [CVPixelBuffer] = []
        var lastGood: CVPixelBuffer?
        var outIndex: Int64 = 0
        var wroteAny = false
        var aborted = false
        var videoDone = false
        /// video queue: output frames for the next source frame (1, 2 for 50 %, 4 for AI slow)
        func produce() -> Bool {
            while pending.isEmpty {
                lock.lock(); let stale = aiEpoch != epoch; lock.unlock()
                if stale { aborted = true; return false }    // replay store is closing (cleared / new setup)
                guard nextF <= last else { return false }
                let f = nextF
                nextF += 1
                if let src = decode(f), let c = convert(src) { lastGood = c; wroteAny = true }
                guard let cur = lastGood else { continue }
                switch o.speed {
                case 1: pending = [cur, cur]
                case 2:
                    pending = [cur]
                    for k in 1...3 {
                        // AI in-betweens inside the clip; outside (padding) or not rendered yet → hold the frame
                        let mid = aiClip.flatMap { c in (f >= c.inFrame && f < c.outFrame) ? decodeAI(c, f, k).flatMap(convert) : nil }
                        pending.append(mid ?? cur)
                    }
                default: pending = [cur]
                }
                if (f - first) % 10 == 0 { progress(Double(f - first) / total) }
            }
            return true
        }
        group.enter()
        vin.requestMediaDataWhenReady(on: vq) {
            guard !videoDone else { return }
            while vin.isReadyForMoreMediaData {
                if pending.isEmpty && !produce() {
                    videoDone = true; vin.markAsFinished(); group.leave(); return
                }
                let pb = pending.removeFirst()
                if !adaptor.append(pb, withPresentationTime: CMTime(value: outIndex * frameDur, timescale: timescale)) {
                    aborted = true; videoDone = true; vin.markAsFinished(); group.leave(); return
                }
                outIndex += 1
            }
        }
        if let ain {
            var audioDone = false
            group.enter()
            ain.requestMediaDataWhenReady(on: aq) {
                guard !audioDone else { return }
                while ain.isReadyForMoreMediaData {
                    if audioQueue.isEmpty || !ain.append(audioQueue.removeFirst()) {
                        audioDone = true; ain.markAsFinished(); group.leave(); return
                    }
                }
            }
        }
        // generous limit (≈ 30 s per output second); a stalled writer must never hang the export queue
        let limit = DispatchTime.now() + .seconds(max(60, Int(total / max(1, fps) * 30)))
        let finished = group.wait(timeout: limit) == .success
        let stuck = !finished
        if stuck || aborted { wroteAny = false }
        let done = DispatchSemaphore(value: 0)
        if wroteAny {
            writer.finishWriting { done.signal() }
            done.wait()
        } else {
            writer.cancelWriting()
        }
        progress(1)
        guard wroteAny, writer.status == .completed else {
            let werr = (writer.error as NSError?).map { "\($0.domain) \($0.code) \($0.localizedDescription) \(($0.userInfo[NSUnderlyingErrorKey] as? NSError)?.code ?? 0)" }
            lastExportError = (werr ?? (stuck ? "writer timeout" : "decode \(kind)")) + " frames \(outIndex)"
            try? FileManager.default.removeItem(at: url)
            return nil
        }
        return url.path
    }

    /// Interleaved stereo Float32 → CMSampleBuffer at sample position `pos` (48 kHz).
    private static func audioSample(_ floats: [Float], at pos: Int64) -> CMSampleBuffer? {
        let frames = floats.count / 2
        guard frames > 0 else { return nil }
        var asbd = AudioStreamBasicDescription(mSampleRate: Double(AudioMixer.rate), mFormatID: kAudioFormatLinearPCM,
                                               mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
                                               mBytesPerPacket: 8, mFramesPerPacket: 1, mBytesPerFrame: 8,
                                               mChannelsPerFrame: 2, mBitsPerChannel: 32, mReserved: 0)
        var fmtDesc: CMAudioFormatDescription?
        guard CMAudioFormatDescriptionCreate(allocator: nil, asbd: &asbd, layoutSize: 0, layout: nil, magicCookieSize: 0,
                                             magicCookie: nil, extensions: nil, formatDescriptionOut: &fmtDesc) == noErr,
              let fd = fmtDesc else { return nil }
        let bytes = frames * 8
        var block: CMBlockBuffer?
        guard CMBlockBufferCreateWithMemoryBlock(allocator: nil, memoryBlock: nil, blockLength: bytes, blockAllocator: nil,
                                                 customBlockSource: nil, offsetToData: 0, dataLength: bytes,
                                                 flags: kCMBlockBufferAssureMemoryNowFlag,
                                                 blockBufferOut: &block) == noErr, let bb = block else { return nil }
        let ok = floats.withUnsafeBytes { CMBlockBufferReplaceDataBytes(with: $0.baseAddress!, blockBuffer: bb, offsetIntoDestination: 0, dataLength: bytes) }
        guard ok == noErr else { return nil }
        var sb: CMSampleBuffer?
        guard CMAudioSampleBufferCreateReadyWithPacketDescriptions(allocator: nil, dataBuffer: bb, formatDescription: fd,
                                                                   sampleCount: frames,
                                                                   presentationTimeStamp: CMTime(value: pos, timescale: CMTimeScale(AudioMixer.rate)),
                                                                   packetDescriptions: nil, sampleBufferOut: &sb) == noErr else { return nil }
        return sb
    }
}
