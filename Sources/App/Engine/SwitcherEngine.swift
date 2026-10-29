import Foundation
import AppKit
import CoreVideo
import CoreImage
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import QuartzCore
import Combine

/// Transition effects.
enum TransitionType: String, Codable, CaseIterable, Identifiable {
    case fade, merge, wipe, slide, fly, crossZoom, zoom, dip

    var id: String { rawValue }
    var label: String {
        switch self {
        case .fade: return "Fade"
        case .merge: return "Merge"
        case .wipe: return "Wipe"
        case .slide: return "Slide"
        case .fly: return "Fly"
        case .crossZoom: return "CrossZoom"
        case .zoom: return "Zoom"
        case .dip: return "FadeToBlack"
        }
    }
    var shaderCode: Int32 {
        switch self {
        case .fade: return 1
        case .wipe: return 2
        case .slide: return 3
        case .dip: return 4
        case .merge: return 5
        case .fly: return 6
        case .crossZoom: return 7
        case .zoom: return 8
        }
    }
    static func named(_ s: String) -> TransitionType? {
        allCases.first { $0.label.caseInsensitiveCompare(s) == .orderedSame || $0.rawValue.caseInsensitiveCompare(s) == .orderedSame }
    }
}

/// One of the four transition buttons (effect + duration).
struct TransitionSlot: Codable, Equatable {
    var type: TransitionType
    var durationMs: Int
}

/// What an auxiliary output bus (Output 2–4) carries.
enum BusSource: Codable, Equatable, Hashable {
    case program, clean, preview, multiview, input(UUID)

    var label: String {
        switch self {
        case .program: return L("Output (프로그램)")
        case .clean: return L("Clean (오버레이 없음)")
        case .preview: return "Preview"
        case .multiview: return "MultiView"
        case .input: return L("입력")
        }
    }
}

/// Stinger transition: a media input (ideally with alpha) played over the cut.
struct StingerConfig: Codable, Equatable {
    var inputID: UUID?
    var cutPointMs: Int = 500
}

struct MultiCorderSettings: Codable, Equatable {
    var folder: String = "~/Movies/BraceletMix/MultiCorder"
    var videoCodec: String = "h264"     // h264 | hevc | prores
    var container: String = "mov"
    var videoKbps: Int = 20000
    var audioFromMaster = false         // false = the input's own (pre-fader) audio
    var splitMinutes: Int = 0           // "New file every" (0 = off)

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = MultiCorderSettings()
        folder = c.value(.folder, d.folder)
        videoCodec = c.value(.videoCodec, d.videoCodec)
        container = c.value(.container, d.container)
        videoKbps = c.value(.videoKbps, d.videoKbps)
        audioFromMaster = c.value(.audioFromMaster, d.audioFromMaster)
        splitMinutes = c.value(.splitMinutes, d.splitMinutes)
    }
}

/// How an overlay channel animates in/out (Overlay settings window).
enum OverlayEffect: String, Codable, CaseIterable, Identifiable {
    case cut, fade, zoom, slide
    var id: String { rawValue }
    var label: String {
        switch self {
        case .cut: return "Cut"
        case .fade: return "Fade"
        case .zoom: return "Zoom"
        case .slide: return "Slide"
        }
    }
}

struct OverlaySettings: Codable, Equatable {
    var effect: OverlayEffect = .fade
    var durationMs: Int = 500
    var autoCloseSeconds: Double = 0    // 0 = stays until turned off
    var pip = false                     // Picture-in-Picture (else full screen)
    var pipX: Float = 0.9               // pan (-2…2)
    var pipY: Float = 0.9
    var pipZoom: Float = 0.33

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = OverlaySettings()
        effect = c.value(.effect, d.effect)
        durationMs = c.value(.durationMs, d.durationMs)
        autoCloseSeconds = c.value(.autoCloseSeconds, d.autoCloseSeconds)
        pip = c.value(.pip, d.pip)
        pipX = c.value(.pipX, d.pipX)
        pipY = c.value(.pipY, d.pipY)
        pipZoom = c.value(.pipZoom, d.pipZoom)
    }
}

private struct OverlayState {
    var id: UUID?
    var target: Float = 0
    var alpha: Float = 0
}

private struct StingerState {
    var slot: Int
    var id: UUID
    var start: CFTimeInterval
    var cutMs: Int
    var cutDone = false
}

/// State shared between the UI (main thread) and the render thread. Guarded by `SwitcherEngine.stateLock`.
private struct RenderState {
    var programID: UUID?
    var previewID: UUID?
    var transition: TransitionType = .fade
    var transitionActive = false
    var transitionStart: CFTimeInterval = 0
    var transitionDuration: Double = 1.0
    var manualT: Float? = nil
    var overlays = [OverlayState](repeating: OverlayState(), count: 4)
    var overlaySettings = [OverlaySettings](repeating: OverlaySettings(), count: 4)
    var ftbTarget: Float = 0
    var ftb: Float = 0
    var stinger: StingerState? = nil
    var busSources: [BusSource] = [.preview, .multiview, .clean]   // Output 2, 3, 4
    var fullscreenSource: BusSource? = nil                         // nil = fullscreen off
    var isoMasterAudio = false
}

/// The switcher: owns inputs, outputs, the render clock, GPU mixer and audio mixer.
final class EngineStats: ObservableObject {
    @Published var tick: Int = 0
    let history = HealthHistory()
}

final class SwitcherEngine: ObservableObject {
    static let overlayCount = 4

    // Published UI state (main thread only)
    @Published private(set) var inputs: [InputSource] = []
    @Published private(set) var outputs: [OutputChannel] = []
    @Published private(set) var programID: UUID?
    @Published private(set) var previewID: UUID?
    @Published private(set) var overlayIDs: [UUID?] = [nil, nil, nil, nil]
    @Published private(set) var overlayOn: [Bool] = [false, false, false, false]
    @Published private(set) var ftbOn = false
    @Published private(set) var transitioning = false
    @Published var transitionSlots: [TransitionSlot] = [
        TransitionSlot(type: .fade, durationMs: 500),
        TransitionSlot(type: .merge, durationMs: 1000),
        TransitionSlot(type: .wipe, durationMs: 1000),
        TransitionSlot(type: .fly, durationMs: 1000),
    ]
    var defaultTransition: TransitionSlot { transitionSlots[0] }
    @Published var stingers: [StingerConfig] = [StingerConfig(), StingerConfig(), StingerConfig(), StingerConfig()]
    @Published private(set) var stingerActive: Int? = nil
    @Published var busSources: [BusSource] = [.preview, .multiview, .clean] {
        didSet { withState { $0.busSources = busSources } }
    }
    /// Auto ducking (presenter mic lowers music/VT automatically)
    @Published var ducking = DuckSettings() { didSet { audioMixer.setDucking(ducking) } }
    @Published var busSettings: [BusSettings] = [BusSettings](repeating: BusSettings(), count: AudioMixer.busCount) {
        didSet { for (i, b) in busSettings.enumerated() { audioMixer.setBus(i, b) } }
    }
    @Published var headphonesVolume: Float = 1 { didSet { audioMixer.setHeadphones(volume: headphonesVolume) } }
    @Published var multiCorderSettings = MultiCorderSettings()
    @Published var overlaySettings = [OverlaySettings](repeating: OverlaySettings(), count: 4) {
        didSet { withState { $0.overlaySettings = overlaySettings } }
    }
    @Published private(set) var multiCorderOn = false
    @Published var mixerVisible = true
    @Published var tbar: Double = 0
    @Published private(set) var format: VideoFormat
    /// Per-second statistics live in their own observable so updating them doesn't redraw the window.
    let stats = EngineStats()
    let scheduler = Scheduler()
    let rundown = Rundown()
    let captions = CaptionEngine()
    private var appActivity: NSObjectProtocol?
    let srtMonitor = SRTMonitor()
    let blackbox = Blackbox()
    /// Recording: "≈ 3.2 h left" on the disk of the record folder (updated every second).
    @Published private(set) var recordRemaining: String = ""
    private var lastDropForBlackbox = 0
    /// vMix Data Sources (Google Sheets / CSV → title fields)
    let dataSources = DataSourceManager()
    private(set) var renderMs: Double = 0
    private(set) var droppedTicks: Int = 0
    /// Slowest frame in the last stats window (ms).
    private(set) var renderMsPeak: Double = 0
    /// Longest main-thread (UI) stall in the last second — monitors and buttons stutter when this is high.
    private(set) var uiStallMs: Double = 0
    private var uiLastTick: CFTimeInterval = 0
    private var uiMaxGap: Double = 0
    @Published var monitorOn = false { didSet { audioMixer.setMonitoring(monitorOn) } }
    @Published var apiStatus: String = ""
    @Published var lastMessage: String = ""

    var masterVolume: Float {
        get { busSettings[0].volume }
        set { busSettings[0].volume = max(0, min(1, newValue)) }
    }
    var masterMuted: Bool {
        get { busSettings[0].muted }
        set { busSettings[0].muted = newValue }
    }

    let audioMixer = AudioMixer()
    let programSlot = VideoSlot()
    /// Preview composed like the program (input Position/crop applied) — what the Preview monitor shows.
    let previewSlot = VideoSlot()
    /// Render thread: true when `previewSlot` holds the composed preview (read by the monitor's display thread).
    var previewComposed: Bool {
        get { previewComposedLock.lock(); defer { previewComposedLock.unlock() }; return _previewComposed }
        set { previewComposedLock.lock(); _previewComposed = newValue; previewComposedLock.unlock() }
    }
    private var _previewComposed = false
    private let previewComposedLock = NSLock()
    /// Drag-to-position mode on the monitors.
    @Published var positionEdit = false
    /// Trigger recursion guard (main thread).
    var triggerDepth = 0

    /// vMix-style: an aux bus (1…7 = A…G) is shown when it was enabled, or something routes to / records it.
    func busInUse(_ b: Int) -> Bool {
        guard b > 0, b < AudioMixer.busCount else { return b == 0 }
        if busSettings[b].enabled { return true }
        let letter = AudioBus.all[b]
        if inputs.contains(where: { $0.onBus(letter) }) { return true }
        if outputs.contains(where: { $0.config.audioBus.uppercased() == letter || $0.config.extraAudioBuses.uppercased().contains(letter) }) { return true }
        return false
    }
    var visibleBuses: [Int] { (1..<AudioMixer.busCount).filter { busInUse($0) } }

    /// Layers visible in the Output monitor, bottom → top, for the position editor.
    func outputEditLayers() -> [EditableLayer] {
        var out: [EditableLayer] = []
        if let p = input(withID: programID) { out.append(EditableLayer(input: p, label: p.name)) }
        for k in 0..<overlayIDs.count where overlayOn[k] {
            guard let id = overlayIDs[k], let i = input(withID: id) else { continue }
            let os = overlaySettings[k]
            out.append(EditableLayer(input: i, extraZoom: os.pip ? os.pipZoom : 1, extraPanX: os.pip ? os.pipX : 0,
                                     extraPanY: os.pip ? os.pipY : 0, label: "Overlay \(k + 1): \(i.name)"))
        }
        return out
    }
    /// Latest frame of Output 1…4 (index 0…3).
    let busSlots = [VideoSlot(), VideoSlot(), VideoSlot(), VideoSlot()]
    /// Latest frame of the Fullscreen output.
    let fullscreenSlot = VideoSlot()

    /// Fired on the main thread whenever program/preview/overlay/output state changes (TCP subscriptions).
    let switchEvents = PassthroughSubject<Void, Never>()

    private let stateLock = NSLock()
    private var rs = RenderState()
    private var renderInputs: [InputSource] = []      // stateLock
    private var renderOutputs: [OutputChannel] = []   // stateLock
    private var isoOutputs: [UUID: OpaquePointer] = [:] // stateLock (MultiCorder)
    private var mixer: MetalMixer?
    private var renderThread: Thread?
    private var running = false
    private var renderFormat: VideoFormat
    private var audioAccumulator: Int = 0
    private var statsTimer: Timer?
    private var mediaTimer: Timer?
    private var renderMsAccum: Double = 0
    private var renderMsCount = 0
    private var renderMsMax: Double = 0
    private var droppedCount = 0
    func resetDrops() {
        stateLock.lock(); droppedCount = 0; stateLock.unlock()
        droppedTicks = 0
        lastDropForBlackbox = 0
        lastDroppedForHistory = 0
    }
    private var volumeFades: [UUID: (from: Float, to: Float, start: CFTimeInterval, duration: Double)] = [:]
    let api = HTTPAPIServer()
    let tcpAPI = TCPAPIServer()
    private var childSubscriptions: [UUID: AnyCancellable] = [:]

    init(format: VideoFormat = .defaultFormat) {
        self.format = format
        self.renderFormat = format
        api.engine = self
        tcpAPI.engine = self
        InputSource.eventSink = { [weak self] input, e in self?.fireTriggers(input, e) }
    }

    private func watch(_ id: UUID, _ publisher: ObservableObjectPublisher) {
        // Children (inputs/outputs) change often — playback position, meters, bitrate text.
        // Coalesce so the whole window re-evaluates at most 10×/s; rows observe their own object directly.
        childSubscriptions[id] = publisher
            .throttle(for: .milliseconds(100), scheduler: DispatchQueue.main, latest: true)
            .sink { [weak self] _ in self?.childChanges[id, default: 0] += 1; self?.objectWillChange.send() }
    }
    /// Diagnostics: how often each child forced a window update (per second, reset in publishStats).
    var childChanges: [UUID: Int] = [:]
    private(set) var uiUpdateReport = ""
    private var engineChangeCount = 0
    private var engineChangeSub: AnyCancellable?

    private func unwatch(_ id: UUID) {
        childSubscriptions[id] = nil
    }

    // MARK: Lifecycle

    func startEngine() {
        guard !running else { return }
        // No App Nap / timer coalescing while HongMix runs — even minimised or behind other windows.
        // (macOS otherwise slows background apps, which shows up as dropped frames.)
        appActivity = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiated, .latencyCritical, .idleSystemSleepDisabled],
            reason: "HongMix live production")
        startRenderThread()
        dataSources.start(engine: self)
        captions.engine = self
        ShortcutManager.shared.install(engine: self)
        statsTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.publishStats()
        }
        let watch = Timer(timeInterval: 0.01, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            let now = CACurrentMediaTime()
            if self.uiLastTick > 0 { self.uiMaxGap = max(self.uiMaxGap, (now - self.uiLastTick) * 1000 - 10) }
            self.uiLastTick = now
        }
        RunLoop.main.add(watch, forMode: .common)
        mediaTimer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
            self?.mediaTick()
        }
        // keep failover, scheduler and stats running while a menu is open or a window is being resized
        for t in [statsTimer, mediaTimer].compactMap({ $0 }) { RunLoop.main.add(t, forMode: .common) }
        let ip = HTTPAPIServer.localIPAddress() ?? "localhost"
        let httpOK = api.start(port: 8088)
        let tcpOK = tcpAPI.start(port: 8099)
        apiStatus = (httpOK ? "Web/API http://\(ip):8088" : L("HTTP 8088 사용 불가")) +
            (tcpOK ? " · TCP 8099" : L(" · TCP 8099 사용 불가"))
    }

    private func startRenderThread() {
        VideoSlot.programFPS = format.fps
        mixer = MetalMixer(format: format)
        renderFormat = format
        stateLock.lock()
        running = true
        stateLock.unlock()
        let t = Thread { [weak self] in self?.renderLoop() }
        t.name = "BraceletMix.render"
        t.qualityOfService = .userInteractive
        renderThread = t
        t.start()
    }

    func shutdown() {
        for o in outputs where o.running { o.stop(waitForClose: true) }
        stopMultiCorder(wait: true)
        stopRenderLoop()
        for i in inputs { i.stop() }
        api.stop()
        tcpAPI.stop()
        audioMixer.setMonitoring(false)
    }

    private func stopRenderLoop() {
        stateLock.lock()
        running = false
        stateLock.unlock()
        while renderThread?.isFinished == false { usleep(2000) }
        renderThread = nil
    }

    @discardableResult
    func setFormat(_ f: VideoFormat) -> Bool {
        if f == format { return true }
        if outputs.contains(where: { $0.running }) || multiCorderOn { return false }
        stopRenderLoop()
        format = f
        startRenderThread()
        return true
    }

    private func withState(_ body: (inout RenderState) -> Void) {
        stateLock.lock()
        body(&rs)
        stateLock.unlock()
    }

    // MARK: Inputs

    func addInput(_ config: InputConfig) {
        let input = InputSource.make(config)
        inputs.append(input)
        watch(input.id, input.objectWillChange)
        syncRenderLists()
        input.start()
        if programID == nil {
            withState { $0.programID = input.id }
            programID = input.id
        } else if previewID == nil {
            withState { $0.previewID = input.id }
            previewID = input.id
        }
        switchEvents.send()
    }

    func removeInput(_ input: InputSource) {
        inputs.removeAll { $0.id == input.id }
        unwatch(input.id)
        stopISO(input.id)
        syncRenderLists()
        withState { s in
            if s.programID == input.id { s.programID = nil }
            if s.previewID == input.id { s.previewID = nil }
            for i in 0..<s.overlays.count where s.overlays[i].id == input.id { s.overlays[i] = OverlayState() }
            if s.stinger?.id == input.id { s.stinger = nil }
            s.busSources = s.busSources.map { $0 == .input(input.id) ? .program : $0 }
        }
        busSources = busSources.map { $0 == .input(input.id) ? .program : $0 }
        if programID == input.id { programID = nil }
        if previewID == input.id { previewID = nil }
        for i in 0..<overlayIDs.count where overlayIDs[i] == input.id {
            overlayIDs[i] = nil
            overlayOn[i] = false
        }
        for i in 0..<stingers.count where stingers[i].inputID == input.id { stingers[i].inputID = nil }
        switchEvents.send()
        DispatchQueue.global(qos: .userInitiated).async { input.stop() }
    }

    func replaceInput(_ input: InputSource, with config: InputConfig) {
        guard let idx = inputs.firstIndex(where: { $0.id == input.id }) else { return }
        DispatchQueue.global(qos: .userInitiated).async { input.stop() }
        var c = config
        c.id = input.id
        let fresh = InputSource.make(c)
        inputs[idx] = fresh
        watch(fresh.id, fresh.objectWillChange)
        syncRenderLists()
        fresh.start()
    }

    func moveInput(from: Int, to: Int) {
        guard inputs.indices.contains(from), to >= 0, to < inputs.count, from != to else { return }
        let item = inputs.remove(at: from)
        inputs.insert(item, at: to)
        syncRenderLists()
        switchEvents.send()
    }

    private func syncRenderLists() {
        stateLock.lock()
        renderInputs = inputs
        renderOutputs = outputs
        stateLock.unlock()
    }

    func input(withID id: UUID?) -> InputSource? {
        guard let id = id else { return nil }
        return inputs.first { $0.id == id }
    }

    func number(of input: InputSource) -> Int {
        (inputs.firstIndex { $0.id == input.id } ?? -1) + 1
    }

    func number(ofID id: UUID?) -> Int {
        guard let id = id else { return 0 }
        return (inputs.firstIndex { $0.id == id } ?? -1) + 1
    }

    /// 0 = off, 1 = program (incl. visible overlays), 2 = preview.
    func tally(of input: InputSource) -> Int {
        if input.id == programID { return 1 }
        for i in 0..<SwitcherEngine.overlayCount where overlayOn[i] && overlayIDs[i] == input.id { return 1 }
        if input.id == previewID { return 2 }
        return 0
    }

    private func isLive(_ id: UUID) -> Bool {
        id == programID || (0..<SwitcherEngine.overlayCount).contains { overlayOn[$0] && overlayIDs[$0] == id }
    }

    // MARK: Auto Play / Auto Pause / Auto Restart

    private func goLive(_ id: UUID?, overlay: Bool = false) {
        guard let i = input(withID: id) else { return }
        fireTriggers(i, overlay ? .overlayIn : .transitionIn)
        if i.supportsTransport && i.autoPlay {
            if i.duration > 0 && i.position >= i.duration - 0.1 && !i.looping { i.restart() }
            if !i.playing { i.playing = true }
        }
        i.didGoLive()
    }

    private func leftLive(_ id: UUID?, overlay: Bool = false) {
        if let id = id, let i = input(withID: id) {
            let stillThere = overlay ? (0..<SwitcherEngine.overlayCount).contains { overlayOn[$0] && overlayIDs[$0] == id }
                                     : id == programID
            if !stillThere { fireTriggers(i, overlay ? .overlayOut : .transitionOut) }
        }
        guard let id = id, !isLive(id), let i = input(withID: id), i.supportsTransport else { return }
        if i.autoRestart { i.restart() }
        if i.autoPause { i.playing = false }
    }

    // MARK: Switching (main thread)

    func setPreview(_ id: UUID?) {
        withState { $0.previewID = id }
        previewID = id
        switchEvents.send()
    }

    func cut() {
        var newPgm: UUID?, newPvw: UUID?
        withState { s in
            s.transitionActive = false
            s.manualT = nil
            let old = s.programID
            s.programID = s.previewID
            s.previewID = old
            newPgm = s.programID
            newPvw = s.previewID
        }
        let old = programID
        programID = newPgm
        previewID = newPvw
        goLive(newPgm)
        leftLive(old)
        transitioning = false
        tbar = 0
        switchEvents.send()
    }

    func cutDirect(_ id: UUID) {
        withState { s in
            s.transitionActive = false
            s.manualT = nil
            s.programID = id
        }
        let old = programID
        programID = id
        goLive(id)
        leftLive(old)
        transitioning = false
        tbar = 0
        switchEvents.send()
    }

    func autoTransition(_ type: TransitionType, durationMs: Int) {
        let d = max(0.05, Double(durationMs) / 1000)
        var started = false
        var incoming: UUID?
        withState { s in
            guard !s.transitionActive, s.stinger == nil, s.previewID != nil else { return }
            s.transition = type
            s.transitionDuration = d
            s.transitionStart = CACurrentMediaTime()
            s.manualT = nil
            s.transitionActive = true
            started = true
            incoming = s.previewID
        }
        if started {
            goLive(incoming)
            transitioning = true
        }
    }

    func transition(slot: Int) {
        let i = max(1, min(4, slot)) - 1
        autoTransition(transitionSlots[i].type, durationMs: transitionSlots[i].durationMs)
    }

    func quickPlay(_ id: UUID) {
        if id == programID { return }
        setPreview(id)
        transition(slot: 1)
    }

    func setTBar(_ value: Double) {
        let v = Float(max(0, min(1, value)))
        tbar = Double(v)
        var completed = false
        var began = false
        let type = defaultTransition.type
        withState { s in
            if v >= 0.999 {
                if s.manualT != nil {
                    let old = s.programID
                    s.programID = s.previewID
                    s.previewID = old
                    completed = true
                }
                s.manualT = nil
                s.transitionActive = false
            } else if v <= 0.001 {
                s.manualT = nil
                s.transitionActive = false
            } else {
                began = s.manualT == nil
                s.transition = type
                s.manualT = v
                s.transitionActive = true
            }
        }
        if began { goLive(previewID) }
        if completed {
            let old = programID
            syncSwitchState()
            leftLive(old)
            tbar = 0
        }
        transitioning = v > 0.001 && v < 0.999
    }

    // Stingers (1-based)

    func stinger(_ slot: Int) {
        let i = max(1, min(4, slot)) - 1
        guard let sid = stingers[i].inputID, let s = input(withID: sid), previewID != nil else {
            lastMessage = Lf("Stinger %@: 미디어 입력이 지정되지 않음", "\(slot)")
            return
        }
        var ok = false
        withState { st in
            guard st.stinger == nil, !st.transitionActive else { return }
            st.stinger = StingerState(slot: slot, id: sid, start: CACurrentMediaTime(), cutMs: stingers[i].cutPointMs)
            ok = true
        }
        guard ok else { return }
        s.video.clear()
        s.restart()
        s.playing = true
        stingerActive = slot
        transitioning = true
    }

    private func finishStinger() {
        withState { $0.stinger = nil }
        stingerActive = nil
        transitioning = false
    }

    // Overlay channels (1-based)

    func toggleOverlay(_ channel: Int, _ id: UUID) {
        let c = channel - 1
        guard (0..<SwitcherEngine.overlayCount).contains(c) else { return }
        if overlayOn[c] && overlayIDs[c] == id { overlayOut(channel) } else { overlayIn(channel, id) }
    }

    func overlayIn(_ channel: Int, _ id: UUID) {
        let c = channel - 1
        guard (0..<SwitcherEngine.overlayCount).contains(c) else { return }
        let replaced = overlayOn[c] && overlayIDs[c] != id ? overlayIDs[c] : nil
        withState { s in
            if s.overlays[c].id != id { s.overlays[c].alpha = 0 }
            s.overlays[c].id = id
            s.overlays[c].target = 1
        }
        overlayIDs[c] = id
        overlayOn[c] = true
        overlayOnSince[c] = CACurrentMediaTime()
        goLive(id, overlay: true)
        if let r = replaced { leftLive(r, overlay: true) }
        switchEvents.send()
    }

    func overlayOut(_ channel: Int) {
        let c = channel - 1
        guard (0..<SwitcherEngine.overlayCount).contains(c) else { return }
        guard overlayOn[c] else { return }
        withState { $0.overlays[c].target = 0 }
        overlayOn[c] = false
        leftLive(overlayIDs[c], overlay: true)
        switchEvents.send()
    }

    /// Immediate removal without fade (OverlayInputNOff).
    func overlayOffImmediate(_ channel: Int) {
        let c = channel - 1
        guard (0..<SwitcherEngine.overlayCount).contains(c) else { return }
        withState { s in
            s.overlays[c].target = 0
            s.overlays[c].alpha = 0
        }
        let was = overlayOn[c]
        overlayOn[c] = false
        if was { leftLive(overlayIDs[c], overlay: true) }
        switchEvents.send()
    }

    func overlayAllOff() {
        for ch in 1...SwitcherEngine.overlayCount { overlayOut(ch) }
    }

    func overlayChannels(of id: UUID) -> [Int] {
        (0..<SwitcherEngine.overlayCount).filter { overlayOn[$0] && overlayIDs[$0] == id }.map { $0 + 1 }
    }

    func toggleFTB() {
        var on = false
        withState { s in
            s.ftbTarget = s.ftbTarget > 0 ? 0 : 1
            on = s.ftbTarget > 0
        }
        ftbOn = on
        switchEvents.send()
    }

    private func syncSwitchState() {
        stateLock.lock()
        let p = rs.programID, v = rs.previewID
        stateLock.unlock()
        programID = p
        previewID = v
        switchEvents.send()
    }

    // MARK: Audio helpers

    func setBusVolume(_ bus: Int, _ v: Float) {
        guard (0..<AudioMixer.busCount).contains(bus) else { return }
        busSettings[bus].volume = max(0, min(1, v))
    }

    /// SetVolumeFade: animate an input fader to `target` over `ms`.
    func fadeVolume(_ input: InputSource, to target: Float, ms: Int) {
        volumeFades[input.id] = (input.volume, max(0, min(1, target)), CACurrentMediaTime(), max(0.01, Double(ms) / 1000))
    }

    // MARK: Output buses / fullscreen

    func setBusSource(_ bus: Int, _ src: BusSource) {
        guard (2...4).contains(bus) else { return }
        busSources[bus - 2] = src
    }

    func setFullscreenSource(_ src: BusSource?) {
        withState { $0.fullscreenSource = src }
    }

    func busSlot(_ bus: Int) -> VideoSlot {
        busSlots[max(1, min(4, bus)) - 1]
    }

    // MARK: Outputs

    func addOutput(_ config: OutputConfig) {
        let o = OutputChannel(config: config)
        outputs.append(o)
        watch(o.id, o.objectWillChange)
        syncRenderLists()
    }

    func removeOutput(_ o: OutputChannel) {
        o.stop()
        outputs.removeAll { $0.id == o.id }
        unwatch(o.id)
        syncRenderLists()
    }

    @discardableResult
    func startOutput(_ o: OutputChannel) -> String? {
        let r = o.start(format: format)
        switchEvents.send()
        return r
    }

    func stopOutput(_ o: OutputChannel) {
        o.stop()
        switchEvents.send()
    }

    func setOutputs(kind: OutputKind, running on: Bool, filter: ((OutputChannel) -> Bool)? = nil) {
        // Like vMix: StartRecording with nothing configured records with the default settings.
        if on, kind == .record, filter == nil, !outputs.contains(where: { $0.config.kind == .record }) {
            addOutput(OutputConfig.defaultConfig(kind: .record))
        }
        for o in outputs where o.config.kind == kind && (filter?(o) ?? !o.config.returnFeed) {
            if on && !o.running { o.start(format: format) }
            if !on && o.running { o.stop() }
        }
        switchEvents.send()
    }

    func anyRunning(kind: OutputKind) -> Bool {
        outputs.contains { $0.config.kind == kind && $0.running && !$0.config.returnFeed }
    }

    /// Dual path: a copy of a stream output (same encoding) for a second server / line, started with Stream.
    func addBackupPath(of o: OutputChannel) {
        var c = o.config
        c.id = UUID()
        c.name = o.config.name + L(" (보조 경로)")
        c.returnFeed = false
        if c.proto == .srt && c.srtMode == "listener" { c.srtPort += 1 }
        addOutput(c)
        lastMessage = Lf("'%@' 추가 — 주소(서버/호스트)를 두 번째 경로로 바꿔 주세요", c.name)
    }

    /// Return feed: SRT listener (port 9998) with the program at a light bitrate, for the field / presenters.
    @discardableResult
    func addReturnFeed() -> OutputConfig {
        var c = OutputConfig.defaultConfig(kind: .stream)
        c.name = L("리턴 피드")
        c.proto = .srt
        c.srtMode = "listener"
        var port = 9998
        while outputs.contains(where: { $0.config.proto == .srt && $0.config.srtMode == "listener" && $0.config.srtPort == port }) { port += 1 }
        c.srtPort = port
        c.srtLatencyMs = 300
        c.videoKbps = 2500
        c.audioKbps = 128
        c.keyintSeconds = 1
        c.returnFeed = true
        addOutput(c)
        if let o = outputs.last { _ = startOutput(o) }
        lastMessage = Lf("리턴 피드 시작: 현장에서 srt://이 맥의 IP:%@ 로 접속 (콜러)", "\(port)")
        return c
    }

    // MARK: MultiCorder (ISO recording of each flagged input)

    func startMultiCorder() {
        guard !multiCorderOn else { return }
        let targets = inputs.filter { $0.multiCorder }
        guard !targets.isEmpty else {
            lastMessage = L("MultiCorder: 녹화할 입력이 없습니다 (입력 설정에서 'MultiCorder 녹화' 체크)")
            return
        }
        let s = multiCorderSettings
        let folder = (s.folder as NSString).expandingTildeInPath
        try? FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        let df = DateFormatter()
        df.dateFormat = "yyyyMMdd_HHmmss"
        let stamp = df.string(from: Date())
        var handles: [UUID: OpaquePointer] = [:]
        for i in targets {
            let safe = i.name.replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: ":", with: "_")
            let ext = s.videoCodec == "prores" ? "mov" : s.container
            let path = (folder as NSString).appendingPathComponent("\(number(of: i))_\(safe)_\(stamp).\(ext)")
            var cfg = mc_output_config()
            cfg.width = Int32(format.width)
            cfg.height = Int32(format.height)
            cfg.fps_num = Int32(format.fpsNum)
            cfg.fps_den = Int32(format.fpsDen)
            cfg.video_kbps = Int32(s.videoKbps)
            cfg.audio_kbps = 192
            cfg.keyint_frames = Int32(format.fps.rounded())
            cfg.hardware = 1
            cfg.pixelbuffer_input = 1
            let uPtr = strdup(path), fPtr = strdup(ext == "ts" ? "mpegts" : ext), vPtr = strdup(s.videoCodec)
            cfg.url = UnsafePointer(uPtr)
            cfg.format = UnsafePointer(fPtr)
            cfg.video_codec = UnsafePointer(vPtr)
            if let h = mc_output_open(&cfg, nil, nil) { handles[i.id] = h }
            free(uPtr)
            free(fPtr)
            free(vPtr)
        }
        stateLock.lock()
        isoOutputs = handles
        rs.isoMasterAudio = s.audioFromMaster
        stateLock.unlock()
        multiCorderStarted = CACurrentMediaTime()
        multiCorderOn = !handles.isEmpty
        lastMessage = Lf("MultiCorder: %@개 입력 녹화 중 → %@", "\(handles.count)", "\(folder)")
        switchEvents.send()
    }

    func stopMultiCorder(wait: Bool = false) {
        stateLock.lock()
        let handles = isoOutputs
        isoOutputs = [:]
        stateLock.unlock()
        multiCorderOn = false
        let close = { handles.values.forEach { mc_output_close($0) } }
        if wait { close() } else { DispatchQueue.global(qos: .userInitiated).async(execute: close) }
        switchEvents.send()
    }

    private func stopISO(_ id: UUID) {
        stateLock.lock()
        let h = isoOutputs.removeValue(forKey: id)
        stateLock.unlock()
        if let h = h { DispatchQueue.global().async { mc_output_close(h) } }
    }

    // MARK: Snapshot

    /// Saves a PNG of the program output (or an input). Returns the file path.
    @discardableResult
    func snapshot(input: InputSource? = nil, path: String? = nil) -> String? {
        guard let pb = input?.currentFrame() ?? programSlot.latest() else { return nil }
        let folder = (("~/Pictures/BraceletMix") as NSString).expandingTildeInPath
        try? FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        let df = DateFormatter()
        df.dateFormat = "yyyyMMdd_HHmmss_SSS"
        let file = path.map { ($0 as NSString).expandingTildeInPath } ??
            (folder as NSString).appendingPathComponent("Snapshot_\(df.string(from: Date())).png")
        let ci = CIImage(cvPixelBuffer: pb)
        guard let cg = CIContext().createCGImage(ci, from: ci.extent),
              let dest = CGImageDestinationCreateWithURL(URL(fileURLWithPath: file) as CFURL,
                                                         UTType.png.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, cg, nil)
        guard CGImageDestinationFinalize(dest) else { return nil }
        lastMessage = Lf("스냅샷 저장: %@", "\(file)")
        return file
    }

    // MARK: Main-thread media tick (positions, stinger end, volume fades)

    /// original input → backup it was failed over to
    private var failovers: [UUID: UUID] = [:]
    /// Inputs currently without signal (for the bottom-bar warning).
    @Published private(set) var lostInputs: [UUID] = []

    /// Close an input, asking first if it is on air (program / overlay) or recording in the MultiCorder.
    /// Close button: like vMix there is no confirmation — the last closed input can be brought back
    /// with Undo (top bar) instead.
    func requestRemove(_ i: InputSource) {
        lastClosed = (i.currentConfig(), inputs.firstIndex { $0.id == i.id } ?? inputs.count)
        undoTitle = i.name
        removeInput(i)
    }

    /// vMix Undo: restores the most recently closed input (same settings, same place in the input bar).
    func undoClose() {
        guard let (cfg, idx) = lastClosed else { return }
        lastClosed = nil
        undoTitle = nil
        let input = InputSource.make(cfg)
        inputs.insert(input, at: min(idx, inputs.count))
        watch(input.id, input.objectWillChange)
        syncRenderLists()
        input.start()
        switchEvents.send()
    }
    private var lastClosed: (InputConfig, Int)?
    @Published private(set) var undoTitle: String?

    private func checkSignals() {
        let now = CACurrentMediaTime()
        for i in inputs where i.isLiveSource {
            switch i.checkSignal(now: now) {
            case 1: signalLost(i)
            case -1: signalBack(i)
            default: break
            }
        }
        let lost = inputs.filter { $0.signalLost }.map { $0.id }
        if lost != lostInputs { lostInputs = lost }
    }

    private func signalLost(_ i: InputSource) {
        let live = programID == i.id
        if live || overlayIDs.contains(i.id) {
            blackbox.record(.signalLost, Lf("%@ 신호 끊김 (온에어)", i.name))
        }
        if i.lossAlert {
            NSSound(named: live ? "Sosumi" : "Tink")?.play()
            lastMessage = Lf("⚠︎ 신호 끊김: %@. %@", "\(number(of: i))", "\(i.name)") + (live ? L(" (온에어!)") : "")
        }
        // failover: the live input lost its signal and has a backup → cut to the backup
        if live, let b = i.backupInputID, let backup = input(withID: b), !backup.signalLost {
            failovers[i.id] = b
            cutDirect(b)
            lastMessage = Lf("⚠︎ %@ 신호 끊김 → 백업 %@으로 자동 전환", "\(i.name)", "\(backup.name)")
        }
    }

    private func signalBack(_ i: InputSource) {
        if i.lossAlert { lastMessage = Lf("✓ 신호 복구: %@. %@", "\(number(of: i))", "\(i.name)") }
        if let b = failovers.removeValue(forKey: i.id), i.autoReturn, programID == b {
            cutDirect(i.id)
            lastMessage = Lf("✓ %@ 신호 복구 → 원래 입력으로 복귀", "\(i.name)")
        }
    }

    private func mediaTick() {
        checkSignals()
        for i in inputs where i.supportsTransport { i.pollPosition() }
        for case let f as FFmpegInput in inputs { f.pollNominalRate() }
        if let slot = stingerActive {
            stateLock.lock()
            let st = rs.stinger
            stateLock.unlock()
            if let st = st, let s = input(withID: st.id) {
                let elapsed = CACurrentMediaTime() - st.start
                let ended = elapsed > 0.5 && (!s.playing || (s.duration > 0 && s.position >= s.duration - 0.06))
                if st.cutDone && !programChangeHandled {
                    programChangeHandled = true
                    let old = previewID
                    syncSwitchState()
                    goLive(programID)
                    leftLive(old)
                }
                if ended || elapsed > 30 {
                    finishStinger()
                    programChangeHandled = false
                    if !st.cutDone { cut() }
                }
            } else {
                finishStinger()
            }
            _ = slot
        }
        // overlay auto close ("Duration" in Overlay settings)
        let nowT = CACurrentMediaTime()
        for c in 0..<SwitcherEngine.overlayCount where overlayOn[c] {
            let ac = overlaySettings[c].autoCloseSeconds
            if ac > 0 && nowT - overlayOnSince[c] >= ac { overlayOut(c + 1) }
        }
        // MultiCorder "New file every"
        if multiCorderOn && multiCorderSettings.splitMinutes > 0 &&
            nowT - multiCorderStarted >= Double(multiCorderSettings.splitMinutes) * 60 {
            stopMultiCorder()
            startMultiCorder()
        }
        if !volumeFades.isEmpty {
            let now = CACurrentMediaTime()
            for (id, f) in volumeFades {
                guard let i = input(withID: id) else {
                    volumeFades.removeValue(forKey: id)
                    continue
                }
                let p = Float(min(1, (now - f.start) / f.duration))
                i.volume = f.from + (f.to - f.from) * p
                if p >= 1 { volumeFades.removeValue(forKey: id) }
            }
        }
    }
    private var programChangeHandled = false
    private var overlayOnSince: [CFTimeInterval] = [0, 0, 0, 0]
    private var multiCorderStarted: CFTimeInterval = 0

    // MARK: Render loop (render thread)

    /// Ask the kernel to treat the render thread like an audio/video real-time thread:
    /// it gets its slice every frame period instead of competing with UI and WebKit.
    private static func makeRealtime(frameNs: Double, tb: mach_timebase_info_data_t) {
        func ticks(_ ns: Double) -> UInt32 { UInt32(ns * Double(tb.denom) / Double(tb.numer)) }
        var policy = thread_time_constraint_policy_data_t(
            period: ticks(frameNs),
            computation: ticks(min(frameNs * 0.5, 8_000_000)),
            constraint: ticks(frameNs * 0.9),
            preemptible: 1)
        let count = mach_msg_type_number_t(MemoryLayout<thread_time_constraint_policy_data_t>.size / MemoryLayout<integer_t>.size)
        _ = withUnsafeMutablePointer(to: &policy) { ptr in
            ptr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                thread_policy_set(pthread_mach_thread_np(pthread_self()), thread_policy_flavor_t(THREAD_TIME_CONSTRAINT_POLICY), $0, count)
            }
        }
    }

    private func renderLoop() {
        var tb = mach_timebase_info_data_t()
        mach_timebase_info(&tb)
        // always real-time: a switcher must never be throttled (the old test switch is ignored)
        UserDefaults.standard.removeObject(forKey: "renderRealtime")
        SwitcherEngine.makeRealtime(frameNs: renderFormat.frameDuration * 1e9, tb: tb)
        func toAbs(_ ns: Double) -> UInt64 { UInt64(ns * Double(tb.denom) / Double(tb.numer)) }
        var start = mach_absolute_time()
        var tick: Int64 = 0
        let frameNs = renderFormat.frameDuration * 1e9
        while true {
            stateLock.lock()
            let keepGoing = running
            stateLock.unlock()
            if !keepGoing { break }
            let t0 = CACurrentMediaTime()
            tickMarks.removeAll(keepingCapacity: true)
            autoreleasepool { renderTick(tick) }
            let t1 = CACurrentMediaTime()
            let ms = (t1 - t0) * 1000
            stateLock.lock()
            renderMsAccum += ms
            renderMsCount += 1
            if ms > renderMsMax {
                // keep a per-section breakdown of the slowest tick of the second (diagnostics)
                var prev = t0, parts: [String] = []
                for (n, t) in tickMarks { parts.append(String(format: "%@ %.1f", n, (t - prev) * 1000)); prev = t }
                parts.append(String(format: "rest %.1f", (t1 - prev) * 1000))
                slowTickBreakdown = parts.joined(separator: ", ")
            }
            renderMsMax = max(renderMsMax, ms)
            stateLock.unlock()
            tick += 1
            let target = start + toAbs(Double(tick) * frameNs)
            let now = mach_absolute_time()
            if now > target + toAbs(frameNs * 3) {
                stateLock.lock()
                droppedCount += 1
                stateLock.unlock()
                start = now - toAbs(Double(tick) * frameNs)
                continue
            }
            mach_wait_until(target)
        }
    }

    private func layer(_ input: InputSource?, mixAlpha: Float = 1) -> LayerInput {
        guard let i = input else { return LayerInput.empty }
        let c = i.composed
        return LayerInput(buffer: c ?? i.video.latest(),
                          params: i.videoAdjust.layerParams(premultiplied: c != nil || i.alphaPremultiplied, mixAlpha: mixAlpha))
    }

    /// Overlay channel layer: Picture-in-Picture placement and the in/out effect.
    /// vMix Layers: draws each input that has layers into one frame (base input + up to 10 layers).
    /// Layers use the source's own frame (or its previous composition — nesting works one frame late).
    private func composeLayers(_ ins: [InputSource], fmt: VideoFormat) {
        guard let mixer = mixer else { return }
        let W = CGFloat(fmt.width), H = CGFloat(fmt.height)
        // 1. LUT pre-pass (only inputs with a loaded LUT; reused while the source frame is unchanged)
        var lutOut: [UUID: CVPixelBuffer] = [:]
        for i in ins {
            let (path, strength) = i.lutSnapshot
            guard !path.isEmpty, strength > 0.001, let lut = LUTCache.shared.lut(path), let src = i.video.latest() else {
                if i.lutCacheOut != nil { i.lutCacheOut = nil; i.lutCacheSrc = nil }
                continue
            }
            let key = "\(path)|\(strength)"
            if let o = i.lutCacheOut, i.lutCacheSrc === src, i.lutCacheKey == key {
                lutOut[i.id] = o
            } else if let o = mixer.applyLUT(src, lut: lut, strength: strength, premultiplied: i.alphaPremultiplied) {
                i.lutCacheSrc = src; i.lutCacheOut = o; i.lutCacheKey = key
                lutOut[i.id] = o
            }
        }
        // 2. layers
        for i in ins {
            let ls = i.layersSnapshot.filter { $0.visible && $0.inputID != nil }
            if ls.isEmpty {
                let o = lutOut[i.id]
                if i.composed !== o { i.composed = o }
                continue
            }
            var parts: [ComposeLayer] = []
            if let base = lutOut[i.id] ?? i.video.latest() {
                var p = LayerParams(); p.premul = (lutOut[i.id] != nil || i.alphaPremultiplied) ? 1 : 0
                parts.append(ComposeLayer(buffer: base, params: p, rect: CGRect(x: 0, y: 0, width: W, height: H)))
            }
            for l in ls {
                guard let src = ins.first(where: { $0.id == l.inputID }), src.id != i.id else { continue }
                let buf = src.composed ?? src.video.latest()
                var p = src.videoAdjust.layerParams(premultiplied: src.composed != nil || src.alphaPremultiplied)
                p.panX = 0; p.panY = 0
                p.cropL = l.cropL; p.cropT = l.cropT; p.cropR = l.cropR; p.cropB = l.cropB
                let rect = CGRect(x: CGFloat(l.x) * W, y: CGFloat(l.y) * H, width: CGFloat(l.w) * W, height: CGFloat(l.h) * H)
                p.zoom = 1
                if l.fill, let b = buf {
                    // crop-to-fill: zoom so the (cropped) source covers the box
                    let sw = CGFloat(CVPixelBufferGetWidth(b)) * CGFloat(1 - l.cropL - l.cropR)
                    let sh = CGFloat(CVPixelBufferGetHeight(b)) * CGFloat(1 - l.cropT - l.cropB)
                    let sa = sw / max(1, sh), da = rect.width / max(1, rect.height)
                    p.zoom = Float(max(sa / da, da / sa))
                }
                let bc = HexColor.parse(l.borderColor) ?? (1, 1, 1, 1)
                parts.append(ComposeLayer(buffer: buf, params: p, rect: rect, border: Float(l.border),
                                          borderColor: (Float(bc.0), Float(bc.1), Float(bc.2))))
            }
            i.composed = mixer.compose(parts)
        }
    }

    private func overlayLayer(_ input: InputSource?, alpha: Float, settings os: OverlaySettings) -> LayerInput {
        var l = layer(input, mixAlpha: alpha)
        guard input != nil else { return l }
        let e = alpha * alpha * (3 - 2 * alpha)
        if os.pip {
            l.params.zoom *= os.pipZoom
            l.params.panX += os.pipX
            l.params.panY += os.pipY
        }
        switch os.effect {
        case .cut, .fade:
            break
        case .zoom:
            l.params.zoom *= max(0.01, e)
            l.params.mixAlpha = min(1, alpha * 2)
        case .slide:
            l.params.panX += (1 - e) * 2
            l.params.mixAlpha = 1
        }
        return l
    }

    private func fullTile(_ input: InputSource?, rect: CGRect) -> TileSpec {
        let c = input?.composed
        return TileSpec(buffer: c ?? input?.video.latest(),
                        params: input?.videoAdjust.layerParams(premultiplied: c != nil || (input?.alphaPremultiplied ?? false)) ?? LayerParams(),
                        rect: rect)
    }

    private func renderTick(_ tick: Int64) {
        let fmt = renderFormat
        let now = CACurrentMediaTime()
        // 1. Snapshot + advance animated state
        stateLock.lock()
        var completed = false
        var t: Float = 0
        if rs.transitionActive {
            if let m = rs.manualT {
                t = m
            } else {
                t = Float((now - rs.transitionStart) / rs.transitionDuration)
                if t >= 1 {
                    let old = rs.programID
                    rs.programID = rs.previewID
                    rs.previewID = old
                    rs.transitionActive = false
                    completed = true
                    t = 0
                }
            }
        }
        if var sg = rs.stinger, !sg.cutDone, (now - sg.start) * 1000 >= Double(sg.cutMs) {
            let old = rs.programID
            rs.programID = rs.previewID
            rs.previewID = old
            sg.cutDone = true
            rs.stinger = sg
        }
        for i in 0..<rs.overlays.count {
            let os = rs.overlaySettings[i]
            let step: Float = (os.effect == .cut || os.durationMs <= 0) ? 1 : Float(fmt.frameDuration * 1000 / Double(os.durationMs))
            var o = rs.overlays[i]
            if o.alpha < o.target { o.alpha = min(o.target, o.alpha + step) }
            if o.alpha > o.target { o.alpha = max(o.target, o.alpha - step) }
            rs.overlays[i] = o
        }
        let ftbStep = Float(fmt.frameDuration / 1.0)
        if rs.ftb < rs.ftbTarget { rs.ftb = min(rs.ftbTarget, rs.ftb + ftbStep) }
        if rs.ftb > rs.ftbTarget { rs.ftb = max(rs.ftbTarget, rs.ftb - ftbStep) }
        let st = rs
        let ins = renderInputs
        let outs = renderOutputs
        let isos = isoOutputs
        stateLock.unlock()

        if completed {
            DispatchQueue.main.async {
                let old = self.programID
                self.syncSwitchState()
                self.leftLive(old)
                self.transitioning = false
                self.tbar = 0
            }
        }

        func find(_ id: UUID?) -> InputSource? {
            guard let id = id else { return nil }
            return ins.first { $0.id == id }
        }
        let pgm = find(st.programID)
        let pvw = find(st.previewID)

        composeLayers(ins, fmt: fmt)
        tickMarks.append(("state", CACurrentMediaTime()))
        // 2. Program (Output 1)
        var layers = [LayerInput](repeating: LayerInput.empty, count: MetalMixer.layerCount)
        layers[0] = layer(pgm)
        layers[1] = st.transitionActive ? layer(pvw) : LayerInput.empty
        for (i, o) in st.overlays.enumerated() where o.alpha > 0 {
            layers[2 + i] = overlayLayer(find(o.id), alpha: o.alpha, settings: st.overlaySettings[i])
        }
        if let sg = st.stinger { layers[6] = layer(find(sg.id)) }
        let code = st.transitionActive ? st.transition.shaderCode : 0
        let program = mixer?.render(layers: layers, t: t, transition: code, ftb: st.ftb)
        if let program = program {
            programSlot.store(program)
            busSlots[0].store(program)
        }
        if tick % 300 == 0 { mixer?.flushCache() }

        tickMarks.append(("program", CACurrentMediaTime()))
        // 3. Output 2–4 (only when something uses them)
        let liveOuts = outs.filter { $0.hasHandle }
        let neededBuses = Set(liveOuts.map { $0.routing.bus })
        var busFrames: [Int: CVPixelBuffer] = [:]
        if let p = program { busFrames[1] = p }
        let full = CGRect(x: 0, y: 0, width: fmt.width, height: fmt.height)
        var sourceCache: [BusSource: CVPixelBuffer] = [:]
        func frame(for src: BusSource) -> CVPixelBuffer? {
            if let f = sourceCache[src] { return f }
            var f: CVPixelBuffer?
            switch src {
            case .program:
                f = program
            case .clean:
                var clean = layers
                for i in 2..<MetalMixer.layerCount { clean[i] = LayerInput.empty }
                f = mixer?.render(layers: clean, t: t, transition: code, ftb: 0)
            case .preview:
                f = mixer?.renderTiles([fullTile(pvw, rect: full)])
            case .input(let id):
                f = mixer?.renderTiles([fullTile(find(id), rect: full)])
            case .multiview:
                f = renderMultiView(ins: ins, st: st, program: program, pvw: pvw, fmt: fmt)
            }
            if let f = f { sourceCache[src] = f }
            return f
        }
        // Preview monitor: the preview input composed with its Position settings (shares the .preview bus frame)
        // Only when the preview input is actually repositioned/cropped/keyed — otherwise the monitor shows the
        // input directly (saves a full GPU pass + wait every frame).
        let composePreview = pvw.map { !$0.videoAdjust.isIdentityPlacement } ?? false
        previewComposed = composePreview
        if composePreview, let f = frame(for: .preview) { previewSlot.store(f) }
        for b in 2...4 where neededBuses.contains(b) {
            if let f = frame(for: st.busSources[b - 2]) {
                busFrames[b] = f
                busSlots[b - 1].store(f)
            }
        }
        if let fsrc = st.fullscreenSource, let f = frame(for: fsrc) {
            fullscreenSlot.store(f)
        }

        tickMarks.append(("buses", CACurrentMediaTime()))
        // Tally (NDI sources)
        if tick % 5 == 0 {
            for i in ins {
                let onOverlay = st.overlays.contains { $0.id == i.id && $0.alpha > 0 }
                let onPgm = i.id == st.programID || (st.transitionActive && i.id == st.previewID) || onOverlay
                i.setTally(program: onPgm, preview: i.id == st.previewID)
            }
        }

        // 4. Audio
        var weights: [UUID: Float] = [:]
        if let a = st.programID { weights[a] = st.transitionActive ? (1 - t) : 1 }
        if st.transitionActive, let b = st.previewID { weights[b] = max(weights[b] ?? 0, t) }
        for o in st.overlays where o.alpha > 0 {
            if let id = o.id { weights[id] = max(weights[id] ?? 0, o.alpha) }
        }
        if let sg = st.stinger { weights[sg.id] = 1 }
        audioAccumulator += AudioMixer.rate * fmt.fpsDen
        let frames = audioAccumulator / fmt.fpsNum
        audioAccumulator -= frames * fmt.fpsNum
        tickMarks.append(("tally", CACurrentMediaTime()))
        let n = audioMixer.mix(inputs: ins, weights: weights, frames: frames, isoIDs: Set(isos.keys))
        tickMarks.append(("audio", CACurrentMediaTime()))
        captions.feed(UnsafePointer(audioMixer.bus(captions.feedBus)), frames: n)
        if st.ftb > 0 {
            let g = 1 - st.ftb
            for b in 0..<AudioMixer.busCount {
                let p = audioMixer.bus(b)
                for i in 0..<(n * 2) { p[i] *= g }
            }
        }

        // 5. Outputs
        for o in liveOuts {
            let r = o.routing
            if let f = busFrames[r.bus] ?? program {
                push(frame: f, to: o, fmt: fmt, tick: tick)
            }
            if r.extra.isEmpty {
                o.pushAudio(UnsafePointer(audioMixer.bus(r.audioBus)), frames: n)
            } else {
                o.pushAudio(UnsafePointer(audioMixer.bus(r.audioBus)),
                            extra: r.extra.map { UnsafePointer(audioMixer.bus($0)) }, frames: n)
            }
        }

        // 6. MultiCorder ISO recordings
        if !isos.isEmpty, let mixer = mixer {
            for (id, h) in isos {
                guard let f = mixer.renderTiles([fullTile(find(id), rect: full)]) else { continue }
                mc_output_push_pixelbuffer(h, Unmanaged.passUnretained(f).toOpaque(), tick)
                if st.isoMasterAudio {
                    mc_output_push_audio(h, UnsafePointer(audioMixer.bus(0)), Int32(n))
                } else if let a = audioMixer.iso(id) {
                    mc_output_push_audio(h, a, Int32(n))
                }
            }
        }
    }

    private func push(frame f: CVPixelBuffer, to o: OutputChannel, fmt: VideoFormat, tick: Int64) {
        o.pushVideo(f, width: fmt.width, height: fmt.height, tick: tick)
    }

    private func renderMultiView(ins: [InputSource], st: RenderState, program: CVPixelBuffer?, pvw: InputSource?,
                                 fmt: VideoFormat) -> CVPixelBuffer? {
        let layout = MultiViewLayout.rects(width: fmt.width, height: fmt.height)
        let green: (Float, Float, Float) = (0.16, 0.72, 0.24)
        let red: (Float, Float, Float) = (0.86, 0.16, 0.16)
        let gray: (Float, Float, Float) = (0.25, 0.25, 0.28)
        let bw = Float(max(2, fmt.height / 270))
        var tiles: [TileSpec] = []
        var pv = fullTile(pvw, rect: layout.preview)
        pv.borderColor = green
        pv.borderWidth = bw
        pv.label = "PREVIEW  " + (pvw?.name ?? "")
        tiles.append(pv)
        var pg = TileSpec(buffer: program, params: LayerParams(), rect: layout.program)
        pg.borderColor = red
        pg.borderWidth = bw
        pg.label = "OUTPUT"
        tiles.append(pg)
        for (idx, r) in layout.small.enumerated() where idx < ins.count {
            let i = ins[idx]
            var t = fullTile(i, rect: r)
            let live = i.id == st.programID || st.overlays.contains { $0.id == i.id && $0.alpha > 0 }
            t.borderColor = live ? red : (i.id == st.previewID ? green : gray)
            t.borderWidth = bw
            t.label = "\(idx + 1)  \(i.name)"
            tiles.append(t)
        }
        return mixer?.renderTiles(tiles)
    }

    private func publishStats() {
        stateLock.lock()
        let avg = renderMsCount > 0 ? renderMsAccum / Double(renderMsCount) : 0
        let peak = renderMsMax
        renderMsAccum = 0
        renderMsCount = 0
        renderMsMax = 0
        let dropped = droppedCount
        slowTickReport = slowTickBreakdown
        stateLock.unlock()
        // light smoothing so the number is readable (vMix shows a similar averaged figure)
        renderMs = renderMs == 0 ? avg : renderMs * 0.6 + avg * 0.4
        renderMsPeak = peak
        uiStallMs = max(0, uiMaxGap)
        uiMaxGap = 0
        MonitorRenderer.publishDrawStats()
        droppedTicks = dropped
        for o in outputs { o.refreshStats() }
        // 2-minute health history for the Statistics graphs
        var rtt = 0.0, loss = 0.0
        for case let f as FFmpegInput in inputs {
            if let s = f.srtStats() { rtt = max(rtt, s.rttMs); loss = max(loss, s.lossPercent) }
        }
        for o in outputs where o.running {
            if let s = o.srtStats() { rtt = max(rtt, s.rttMs); loss = max(loss, s.lossPercent) }
        }
        let kbps = outputs.filter { $0.running && $0.config.kind == .stream }.reduce(0) { $0 + $1.lastKbps }
        stats.history.append(HealthHistory.Sample(time: Date(), renderAvgMs: avg, renderMaxMs: peak,
                                                  droppedFrames: max(0, dropped - lastDroppedForHistory),
                                                  streamKbps: kbps, srtRttMs: rtt, srtLossPct: loss,
                                                  uiStallMs: uiStallMs, lostInputs: lostInputs.count))
        lastDroppedForHistory = dropped
        if engineChangeSub == nil { engineChangeSub = objectWillChange.sink { [weak self] in self?.engineChangeCount += 1 } }
        let top = childChanges.sorted { $0.value > $1.value }.prefix(3)
            .map { "\(self.input(withID: $0.key)?.name ?? "out")=\($0.value)" }.joined(separator: ",")
        uiUpdateReport = "\(engineChangeCount) [\(top)]"
        engineChangeCount = 0
        childChanges.removeAll()
        // vMix Alert "LOW VOLUME": master below −50 dBFS for 5 s while something is on air
        let m = audioMixer.master
        // only matters while something actually goes out (stream / record / external)
        let goingOut = outputs.contains { $0.running } || multiCorderOn
        if goingOut && max(m.0, m.1) < 0.00316 && programID != nil { quietSeconds += 1 } else { quietSeconds = 0 }
        let low = quietSeconds >= 5
        if low != lowVolumeAlert { lowVolumeAlert = low }
        scheduler.tick(self)
        rundown.tick(self)
        monitorTick(droppedTotal: dropped)
        stats.tick &+= 1
    }
    private var lastDroppedForHistory = 0

    /// Once a second: SRT link history, blackbox, recording disk estimate.
    private func monitorTick(droppedTotal: Int) {
        srtMonitor.sample(self, blackbox: blackbox)
        let onAir = outputs.contains { $0.running } || multiCorderOn
        if onAir { blackbox.tick(program: programSlot.latest()) }
        if onAir && droppedTotal > lastDropForBlackbox {
            blackbox.record(.frameDrop, Lf("렌더러 프레임 드롭 %@개", "\(droppedTotal - lastDropForBlackbox)"))
        }
        lastDropForBlackbox = droppedTotal
        if onAir && lowVolumeAlert { blackbox.record(.silence, L("Master 무음 5초 이상")) }
        for o in outputs where o.running && o.state == Int32(MC_STATE_ERROR) {
            blackbox.record(.outputError, Lf("%@: %@", o.config.name, o.message))
        }
        // recording time left
        let recs = outputs.filter { $0.running && $0.config.kind == .record }
        if recs.isEmpty && !multiCorderOn {
            if !recordRemaining.isEmpty { recordRemaining = "" }
        } else {
            let folder = ((recs.first?.config.recordFolder ?? multiCorderSettings.folder) as NSString).expandingTildeInPath
            let kbps = recs.reduce(0) { $0 + $1.config.videoKbps + $1.config.audioKbps }
                + (multiCorderOn ? inputs.filter { $0.multiCorder }.count * (multiCorderSettings.videoKbps + 192) : 0)
            if let free = DiskSpace.freeBytes(at: folder), kbps > 0 {
                let secs = Double(free) * 8 / 1000 / Double(kbps)
                let t = secs >= 3600 ? String(format: L("녹화 %.1f시간 남음"), secs / 3600) : String(format: L("녹화 %.0f분 남음"), secs / 60)
                if t != recordRemaining { recordRemaining = t }
            }
        }
    }
    private var tickMarks: [(String, CFTimeInterval)] = []      // render thread
    private var slowTickBreakdown = ""                          // stateLock
    private(set) var slowTickReport = ""                        // main
    private var quietSeconds = 0
    /// Shown on the Output monitor only (never in recordings/streams), like vMix Alerts.
    @Published private(set) var lowVolumeAlert = false

    // MARK: Project files

    func makeProject() -> ProjectFile {
        var p = ProjectFile(formatID: format.id,
                            inputs: inputs.map { $0.currentConfig() },
                            outputs: outputs.map { $0.config },
                            programIndex: inputs.firstIndex { $0.id == programID },
                            previewIndex: inputs.firstIndex { $0.id == previewID },
                            transitions: transitionSlots,
                            masterVolume: masterVolume)
        p.busSettings = busSettings
        p.ducking = ducking
        p.busSources = busSources
        p.stingers = stingers
        p.multiCorder = multiCorderSettings
        p.overlaySettings = overlaySettings
        p.dataSources = dataSources.configs
        p.dataBindings = dataSources.bindings
        p.schedule = scheduler.actions
        p.rundown = rundown.items
        return p
    }

    func load(project: ProjectFile) {
        for o in outputs { o.stop() }
        stopMultiCorder()
        outputs.removeAll()
        let old = inputs
        inputs.removeAll()
        childSubscriptions.removeAll()
        syncRenderLists()
        withState { s in s = RenderState() }
        programID = nil
        previewID = nil
        overlayIDs = [nil, nil, nil, nil]
        overlayOn = [false, false, false, false]
        ftbOn = false
        stingerActive = nil
        DispatchQueue.global(qos: .userInitiated).async { old.forEach { $0.stop() } }
        _ = setFormat(VideoFormat.preset(id: project.formatID))
        if let t = project.transitions, t.count == 4 { transitionSlots = t }
        if let b = project.busSettings, b.count == AudioMixer.busCount { busSettings = b }
        ducking = project.ducking ?? DuckSettings()
        masterVolume = project.masterVolume ?? masterVolume
        if let s = project.stingers, s.count == 4 { stingers = s }
        if let m = project.multiCorder { multiCorderSettings = m }
        if let o = project.overlaySettings, o.count == 4 { overlaySettings = o }
        dataSources.load(project.dataSources ?? [], project.dataBindings ?? [])
        scheduler.load(project.schedule ?? [])
        rundown.load(project.rundown ?? [])
        // Load Chromium before any input starts: dlopen runs CEF's static initialisers (which hook
        // malloc); camera/audio threads enumerating bundles at that moment can crash in them.
        if Thread.isMainThread, project.inputs.contains(where: { $0.kind == .browser && !$0.browserUseWebKit }) {
            _ = mc_web_init()
        }
        for c in project.inputs {
            let input = InputSource.make(c)
            inputs.append(input)
            watch(input.id, input.objectWillChange)
            input.start()
        }
        for c in project.outputs {
            let o = OutputChannel(config: c)
            outputs.append(o)
            watch(o.id, o.objectWillChange)
        }
        if let bs = project.busSources, bs.count == 3 { busSources = bs } else { busSources = [.preview, .multiview, .clean] }
        syncRenderLists()
        if let pi = project.programIndex, inputs.indices.contains(pi) { cutDirect(inputs[pi].id) }
        if let vi = project.previewIndex, inputs.indices.contains(vi) { setPreview(inputs[vi].id) }
    }
}

struct ProjectFile: Codable {
    var version = 3
    var formatID: String
    var inputs: [InputConfig]
    var outputs: [OutputConfig]
    var programIndex: Int?
    var previewIndex: Int?
    var transitions: [TransitionSlot]?
    var masterVolume: Float?
    var busSettings: [BusSettings]? = nil
    var busSources: [BusSource]? = nil
    var stingers: [StingerConfig]? = nil
    var multiCorder: MultiCorderSettings? = nil
    var overlaySettings: [OverlaySettings]? = nil
    var dataSources: [DataSourceConfig]? = nil
    var dataBindings: [DataBinding]? = nil
    var schedule: [ScheduledAction]? = nil
    var rundown: [RundownItem]? = nil
    var ducking: DuckSettings? = nil

    static var autosaveURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("BraceletMix", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base.appendingPathComponent("last-session.bmix")
    }
}
