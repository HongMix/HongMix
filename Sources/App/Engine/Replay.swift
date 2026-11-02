import Foundation
import CoreVideo
import AppKit

// MARK: - Instant Replay
//
// Recording: every selected camera is rendered at the program format each frame, encoded as intra-only
// H.264 (VideoToolbox) and written frame-indexed into the replay store (segment files on disk). Master
// audio is stored per frame as PCM. Frame numbers are the engine's render ticks, so all angles line up.
// Playback: two channels (Replay A / Replay B inputs). Each plays any camera at any speed (slow motion,
// reverse, frame steps); camera changes are frame-synchronous. Events = Mark In / Mark Out pairs.
// When the disk runs low the oldest minute of all angles is deleted and recording continues.

struct ReplaySettings: Codable, Equatable {
    var cameraIDs: [String] = []          // up to 8 inputs (UUID strings)
    var quality: Int = 35_000             // kbps per camera (intra-only H.264)
    var folder: String = ""               // "" = ~/Movies/HongMix/Replay
    var maxGB: Double = 0                 // 0 = use the free space (minus a reserve)
    var autoDelete = true                 // delete the oldest footage when the limit is reached
    var autoReturn = true                 // "Replay → Program" cuts back when the event ends
    var preRoll: Double = 0               // seconds added before Mark In when playing events

    static let maxCameras = 8

    var folderPath: String {
        ((folder.isEmpty ? "~/Movies/HongMix/Replay" : folder) as NSString).expandingTildeInPath
    }

    init() {}
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = ReplaySettings()
        cameraIDs = c.value(.cameraIDs, d.cameraIDs)
        quality = c.value(.quality, d.quality)
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

    @Published var settings = ReplaySettings() { didSet { if settings != oldValue { refreshLimit() } } }
    @Published private(set) var recording = false
    @Published private(set) var recordingStartedAt: Date?
    @Published private(set) var events: [ReplayEvent] = []
    @Published private(set) var channelsUI = [ReplayChannelUI(), ReplayChannelUI()]
    @Published private(set) var status = ReplayStatus()
    @Published private(set) var pendingIn: Int64?
    /// Channels the transport buttons act on (A, B or both).
    @Published var selected: Set<Int> = [0]

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
        var finished = false
        var gen = 0                 // bumped by every user change (player never overwrites a newer change)
    }
    private let lock = NSLock()
    private var ch = [ChannelState(), ChannelState()]
    private var inputsByChannel: [Int: [ReplayInput]] = [:]
    private var store: OpaquePointer?
    private var outs: [OpaquePointer] = []
    private var sinks: [OpaquePointer] = []
    private var recCameras: [UUID] = []           // cameras of the current store (angle 1…n)
    private var liveFrames: [CVPixelBuffer?] = []
    private var head: Int64 = -1                   // newest frame recorded
    private var fps: Double = 59.94
    private var format = VideoFormat.defaultFormat

    // player
    private let queue = DispatchQueue(label: "replay.player", qos: .userInteractive)
    private var timer: DispatchSourceTimer?
    private var decoders: [OpaquePointer?] = [nil, nil]
    private var pool: CVPixelBufferPool?
    private var poolSize = (0, 0)
    private var uiCounter = 0
    private var returnToID: UUID?
    private var statusTimer: Timer?

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

    /// Render thread: replay needs camera frames this tick (recording, or a replay input showing live).
    var wantsFrames: Bool {
        lock.lock(); defer { lock.unlock() }
        return store != nil && (!outs.isEmpty || inputsByChannel.values.contains { !$0.isEmpty })
            || !outs.isEmpty
    }

    /// Cameras of the current recording (angle 1…n).
    var cameraIDs: [UUID] {
        lock.lock(); defer { lock.unlock() }
        return recCameras
    }

    // MARK: Recording

    func startRecording() -> String? {
        guard let e = engine else { return "Engine not ready" }
        if recording { return nil }
        let cams = settings.cameraIDs.compactMap { UUID(uuidString: $0) }.filter { e.input(withID: $0) != nil }
            .prefix(ReplaySettings.maxCameras)
        guard !cams.isEmpty else { return L("리플레이할 카메라를 먼저 고르세요 (Replay 설정)") }
        let fmt = e.format
        lock.lock()
        let sameSetup = store != nil && recCameras == Array(cams) && format.width == fmt.width && format.height == fmt.height
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
            guard let st = mc_replay_store_open(dir, Int32(cams.count + 1), Int32((60 * fps).rounded())) else {
                return L("리플레이 저장소를 열 수 없음")
            }
            lock.lock()
            store = st
            recCameras = Array(cams)
            liveFrames = Array(repeating: nil, count: cams.count)
            head = -1
            lock.unlock()
            events.removeAll()
            pendingIn = nil
        }
        var newOuts: [OpaquePointer] = []
        var newSinks: [OpaquePointer] = []
        lock.lock(); let st = store; lock.unlock()
        for k in 0..<cams.count {
            guard let st = st, let sink = mc_replay_sink_new(st, Int32(k)) else { continue }
            var cfg = mc_output_config()
            cfg.width = Int32(fmt.width); cfg.height = Int32(fmt.height)
            cfg.fps_num = Int32(fmt.fpsNum); cfg.fps_den = Int32(fmt.fpsDen)
            cfg.video_kbps = Int32(settings.quality)
            cfg.audio_kbps = 64
            cfg.keyint_frames = 1                   // intra-only: every frame decodes on its own
            cfg.hardware = 1
            cfg.pixelbuffer_input = 1
            cfg.packet_cb = mc_replay_sink_cb
            cfg.packet_user = UnsafeMutableRawPointer(sink)
            let u = strdup("replay:"), f = strdup("null"), v = strdup("h264")
            cfg.url = UnsafePointer(u); cfg.format = UnsafePointer(f); cfg.video_codec = UnsafePointer(v)
            let h = mc_output_open(&cfg, nil, nil)
            free(u); free(f); free(v)
            if let h = h { newOuts.append(h); newSinks.append(sink) } else { mc_replay_sink_free(sink) }
        }
        guard !newOuts.isEmpty else { return L("리플레이 인코더를 시작할 수 없음") }
        lock.lock()
        outs = newOuts
        sinks = newSinks
        lock.unlock()
        recording = true
        recordingStartedAt = Date()
        refreshLimit()
        startPlayer()
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
        outs = []; sinks = []
        lock.unlock()
        recording = false
        DispatchQueue.global(qos: .userInitiated).async {
            for h in o { mc_output_close(h) }          // flushes the last frames into the store
            for k in s { mc_replay_sink_free(k) }
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
        lock.lock()
        let st = store
        store = nil
        recCameras = []
        liveFrames = []
        head = -1
        for i in 0..<2 { ch[i] = ChannelState() }
        lock.unlock()
        if let st = st { queue.sync { mc_replay_store_close(st, 1) } }
    }

    /// Render thread, once per tick (after the audio mix).
    func renderHook(tick: Int64, audio: UnsafePointer<Float>, frames n: Int, render: (UUID) -> CVPixelBuffer?) {
        lock.lock()
        let cams = recCameras, o = outs, st = store
        lock.unlock()
        guard let st = st else { return }
        var live: [CVPixelBuffer?] = []
        for (k, id) in cams.enumerated() {
            let pb = render(id)
            live.append(pb)
            if k < o.count, let pb = pb {
                mc_output_push_pixelbuffer(o[k], Unmanaged.passUnretained(pb).toOpaque(), tick)
            }
        }
        if !o.isEmpty, n > 0 {
            mc_replay_store_write(st, Int32(cams.count), tick, UnsafeRawPointer(audio).assumingMemoryBound(to: UInt8.self),
                                  Int32(n * 2 * MemoryLayout<Float>.size))
        }
        lock.lock()
        liveFrames = live
        if !o.isEmpty { head = tick }
        lock.unlock()
    }

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
        let st = store, cams = recCameras.count, h = head
        lock.unlock()
        var s = status
        s.cameras = cams
        if let st = st, cams > 0 {
            let first = mc_replay_store_first(st, 0)
            s.bufferedSeconds = first >= 0 && h >= first ? Double(h - first) / fps : 0
            s.bytes = mc_replay_store_bytes(st)
        } else {
            s.bufferedSeconds = 0; s.bytes = 0
        }
        s.free = OutputConfig.freeSpace(at: settings.folderPath) ?? 0
        let camCount = max(1, cams > 0 ? cams : settings.cameraIDs.count)
        let perHour = (Double(settings.quality) * 1000 / 8 * Double(camCount) + 48_000 * 8) * 3600
        s.hoursLeft = perHour > 0 ? Double(max(0, s.free - ReplayEngine.reserve)) / perHour : 0
        if s != status { status = s }
        if Date().timeIntervalSince(lastLimitRefresh) > 5 { lastLimitRefresh = Date(); refreshLimit() }
    }

    /// Estimated recording time for the given settings and disk (shown before recording starts).
    func estimate(cameras: Int) -> (perHour: Int64, hours: Double, free: Int64) {
        let free = OutputConfig.freeSpace(at: settings.folderPath) ?? 0
        let perHour = Int64((Double(settings.quality) * 1000 / 8 * Double(max(1, cameras)) + 48_000 * 8) * 3600)
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
            pool = PixelBufferFactory.makePool(width: w, height: h, minimumCount: 6)
            poolSize = (w, h)
        }
        guard let p = pool else { return nil }
        return PixelBufferFactory.makeBuffer(pool: p)
    }

    private func decode(stream: Int, frame: Int64, st: OpaquePointer, channel: Int) -> CVPixelBuffer? {
        var data: UnsafeMutablePointer<UInt8>?
        var got: Int64 = 0
        let n = mc_replay_store_read(st, Int32(stream), frame, &data, &got)
        guard n > 0, let d = data else { return nil }
        defer { free(d) }
        if decoders[channel] == nil { decoders[channel] = mc_replay_dec_open() }
        guard let dec = decoders[channel], let pb = pixelBuffer() else { return nil }
        CVPixelBufferLockBaseAddress(pb, [])
        defer { CVPixelBufferUnlockBaseAddress(pb, []) }
        guard let base = CVPixelBufferGetBaseAddress(pb) else { return nil }
        let ok = mc_replay_dec_decode(dec, d, n, base.assumingMemoryBound(to: UInt8.self),
                                      Int32(CVPixelBufferGetBytesPerRow(pb)), Int32(format.width), Int32(format.height))
        return ok == 0 ? pb : nil
    }

    private func playerTick() {
        lock.lock()
        let st = store, h = head, live = liveFrames, nCams = recCameras.count
        let first = st.map { mc_replay_store_first($0, 0) } ?? -1
        var states = ch
        let targets = inputsByChannel
        lock.unlock()
        var finishedChannels: [Int] = []
        for c in 0..<2 {
            var s = states[c]
            let ins = targets[c] ?? []
            if s.live {
                if s.camera < live.count, let pb = live[s.camera] {
                    for i in ins { i.video.ingest(pixelBuffer: pb) }
                }
                states[c] = s
                continue
            }
            guard let st = st, nCams > 0 else { continue }
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
            if f != s.shown || s.camera != s.shownCamera {
                if let pb = decode(stream: min(s.camera, nCams - 1), frame: f, st: st, channel: c) {
                    for i in ins { i.video.ingest(pixelBuffer: pb) }
                    s.shown = f; s.shownCamera = s.camera
                }
            }
            // audio only at normal forward speed (no time-stretch)
            if s.playing && !s.reverse && abs(s.speed - 1) < 0.001, !ins.isEmpty {
                var data: UnsafeMutablePointer<UInt8>?
                var got: Int64 = 0
                let n = mc_replay_store_read(st, Int32(nCams), f, &data, &got)
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
        for c in 0..<2 where ch[c].gen == states[c].gen && !states[c].live {
            ch[c].pos = states[c].pos
            ch[c].shown = states[c].shown
            ch[c].shownCamera = states[c].shownCamera
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
                                    position: Int64(s.pos), behindLive: s.live || h < 0 ? 0 : Double(h) / fps - s.pos / fps,
                                    eventNumber: s.eventNumber, attached: !(inputsByChannel[c] ?? []).isEmpty)
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

    private var headFrame: Int64 {
        lock.lock(); defer { lock.unlock() }
        return head
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
            s.pos = min(Double(max(h, 0)), max(0, s.pos + Double(frames)))
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
        events.append(ReplayEvent(number: n, inFrame: inFrame, outFrame: outFrame, camera: cam))
    }

    func deleteEvent(_ id: UUID) { events.removeAll { $0.id == id } }
    func deleteLastEvent() { if !events.isEmpty { events.removeLast() } }
    func renameEvent(_ id: UUID, _ name: String) {
        if let i = events.firstIndex(where: { $0.id == id }) { events[i].name = name }
    }
    func setEventCamera(_ id: UUID, _ cam: Int) {
        if let i = events.firstIndex(where: { $0.id == id }) { events[i].camera = cam }
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

    func timecode(_ frame: Int64) -> String {
        lock.lock(); let st = store; lock.unlock()
        let first = st.map { mc_replay_store_first($0, 0) } ?? 0
        return elapsedTimecode(frames: max(0, frame - max(0, first)))
    }

    func recordTimecode() -> String {
        lock.lock(); let st = store, h = head; lock.unlock()
        guard let st = st, h >= 0 else { return "00:00:00:00" }
        let first = mc_replay_store_first(st, 0)
        return elapsedTimecode(frames: first >= 0 ? max(0, h - first) : 0)
    }

    func selectedTimecode() -> String {
        let c = selected.min() ?? 0
        return timecode(channelsUI[c].position)
    }

    func systemTimecode(_ date: Date = Date()) -> String {
        let cal = Calendar.current
        let c = cal.dateComponents([.hour, .minute, .second, .nanosecond], from: date)
        let rate = max(1, Int(fps.rounded()))
        let frame = min(rate - 1, Int((Double(c.nanosecond ?? 0) / 1_000_000_000.0) * Double(rate)))
        return String(format: "%02d:%02d:%02d:%02d", c.hour ?? 0, c.minute ?? 0, c.second ?? 0, frame)
    }

    /// Wall-clock time at which a replay frame was recorded. The replay store uses the switcher's
    /// global render ticks, so anchor the oldest stored frame to the recording start and keep the
    /// display frame-accurate at the current project rate.
    func recordedClockTimecode(_ frame: Int64) -> String {
        guard let started = recordingStartedAt else { return "--:--:--:--" }
        lock.lock(); let st = store; lock.unlock()
        let first = st.map { mc_replay_store_first($0, 0) } ?? frame
        let date = started.addingTimeInterval(Double(max(0, frame - max(0, first))) / fps)
        return systemTimecode(date)
    }

    func recordingStartText() -> String {
        guard let date = recordingStartedAt else { return "--:--:--" }
        return date.formatted(date: .omitted, time: .standard)
    }

    func timelineBounds() -> ClosedRange<Double> {
        lock.lock(); let st = store, h = head; lock.unlock()
        guard let st = st, h >= 0 else { return 0...1 }
        let first = mc_replay_store_first(st, 0)
        let lo = Double(max(0, first))
        return lo...max(lo + 1, Double(h))
    }

    func seekTimeline(_ frame: Double, channel: Int) {
        modify([channel]) { s, h in
            s.live = frame >= Double(h - 1)
            s.pos = max(0, min(Double(h), frame))
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
