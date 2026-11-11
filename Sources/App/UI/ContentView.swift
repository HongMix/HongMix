import SwiftUI
import CoreVideo
import AppKit

/// Colours follow vMix conventions for Preview/Program. Overlay channels have their own
/// control-surface colors; these are UI indicators and never tint the broadcast picture.
enum AppSkin: String, CaseIterable, Identifiable {
    case mono, classic
    var id: String { rawValue }
    var title: String { self == .mono ? "Black & White" : L("기본") }
    static let defaultsKey = "appSkin"
    /// Cached: Theme colours read this many times per redraw. Refreshed when the skin changes.
    private static var cached: AppSkin?
    static var current: AppSkin {
        if let c = cached { return c }
        migrate()
        let c = AppSkin(rawValue: UserDefaults.standard.string(forKey: defaultsKey) ?? "mono") ?? .mono
        cached = c
        return c
    }
    static func reload() { cached = nil }
    /// Called from the app body with the stored value, before any window rebuilds.
    static func sync(_ raw: String) {
        let s = AppSkin(rawValue: raw) ?? .mono
        if cached != s { cached = s }
    }
    static var isMono: Bool { current == .mono }

    /// 1.4.2: Monochrome becomes the default look once; a skin picked afterwards is kept.
    private static var migrated = false
    private static func migrate() {
        guard !migrated else { return }
        migrated = true
        let d = UserDefaults.standard
        if d.integer(forKey: "appSkinRev") < 2 {
            d.set(AppSkin.mono.rawValue, forKey: defaultsKey)
            d.set(2, forKey: "appSkinRev")
        }
    }
}

enum Theme {
    // Monochrome follows broadcast tally: Program red, Preview green. Other skins keep vMix colours.
    static var program: Color { AppSkin.isMono ? Color(red: 1.0, green: 0.23, blue: 0.19) : Color(red: 0.20, green: 0.66, blue: 0.22) }
    static var preview: Color { AppSkin.isMono ? Color(red: 0.19, green: 0.82, blue: 0.35) : Color(red: 0.93, green: 0.52, blue: 0.10) }
    static let overlay = Color(red: 0.42, green: 0.80, blue: 0.36)
    static func overlayChannel(_ channel: Int) -> Color {
        // Deliberately avoid Program green so on-air tally stays unambiguous.
        let palette: [Color] = [
            Color(red: 0.88, green: 0.40, blue: 0.10), // 1 amber
            Color(red: 0.16, green: 0.48, blue: 0.88), // 2 blue
            Color(red: 0.60, green: 0.34, blue: 0.82), // 3 violet
            Color(red: 0.08, green: 0.62, blue: 0.72), // 4 cyan
            Color(red: 0.82, green: 0.30, blue: 0.55), // 5 magenta
            Color(red: 0.70, green: 0.55, blue: 0.08), // 6 yellow/ochre
            Color(red: 0.12, green: 0.58, blue: 0.46), // 7 teal
            AppSkin.isMono ? Color(red: 0.45, green: 0.50, blue: 0.62)   // 8 slate (Program is red)
                           : Color(red: 0.82, green: 0.24, blue: 0.25)   // 8 red
        ]
        return palette[max(0, min(palette.count - 1, channel - 1))]
    }
    static let live = Color(red: 0.86, green: 0.16, blue: 0.16)
    static var window: Color {
        switch AppSkin.current {
        case .mono: return Color(white: 0.043)
        case .classic: return Color(red: 0.13, green: 0.14, blue: 0.16)
        }
    }
    static var panel: Color {
        switch AppSkin.current {
        case .mono: return Color(white: 0.082)
        case .classic: return Color(red: 0.18, green: 0.19, blue: 0.21)
        }
    }
    static var panelDark: Color {
        switch AppSkin.current {
        case .mono: return Color(white: 0.06)
        case .classic: return Color(red: 0.10, green: 0.11, blue: 0.12)
        }
    }
    static var button: Color {
        switch AppSkin.current {
        case .mono: return Color(white: 0.135)
        case .classic: return Color(red: 0.27, green: 0.28, blue: 0.31)
        }
    }
    static let buttonText = Color(white: 0.92)
    /// Selected / active state. Monochrome uses a light grey instead of blue.
    static var accent: Color { AppSkin.isMono ? Color(white: 0.36) : Color(red: 0.20, green: 0.50, blue: 0.85) }
    /// Monochrome primary action (CUT): white fill, black text.
    static let primaryFill = Color(white: 0.96)
    static let hairline = Color.white.opacity(0.08)
    /// Corner radius: Monochrome uses softer Apple-style corners.
    static var radius: CGFloat { AppSkin.isMono ? 6 : 3 }
}

/// Floating chrome (top bar, bottom bar, monitor labels). Monochrome: Liquid Glass on macOS 26+,
/// vibrancy material before that. Other skins: their flat panel colour.
struct HMGlass: ViewModifier {
    var cornerRadius: CGFloat
    var fallback: Color

    func body(content: Content) -> some View {
        if AppSkin.isMono {
            if #available(macOS 26.0, *) {
                content.glassEffect(.regular, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            } else {
                content
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous).stroke(Color.white.opacity(0.12), lineWidth: 1))
            }
        } else {
            content.background(fallback)
        }
    }
}

extension View {
    func hmGlass(cornerRadius: CGFloat = 14, fallback: Color = Theme.panelDark) -> some View {
        modifier(HMGlass(cornerRadius: cornerRadius, fallback: fallback))
    }
}

struct SheetRequest: Identifiable {
    enum Mode { case source, properties, title }
    let id = UUID()
    var kind: InputKind
    var editing: InputSource?
    var mode: Mode = .source
    var tab: Int = 0
}

/// Main window, laid out like a classic software switcher:
///   [ Preview | Transitions | Output ]
///   [ Inputs ......................  | Audio mixer ]
///   [ Add Input | Record | External | Stream | Fullscreen ......... status ]
struct ContentView: View {
    @EnvironmentObject var engine: SwitcherEngine
    @ViewState private var sheet: SheetRequest? = nil
    @ViewState private var outputsSheet: OutputKind? = nil
    /// vMix: drag the dividing line to give the inputs more (or fewer) rows
    @AppStorage("monitorFraction") private var monitorFraction = 0.58
    @AppStorage("audioInputStripsCollapsed") private var audioInputStripsCollapsed = false
    @AppStorage("inputDockLeft") private var inputDockLeft = false
    @AppStorage(AppSkin.defaultsKey) private var appSkin = AppSkin.mono.rawValue
    @ViewState private var dragStartFraction: Double? = nil

    var body: some View {
        VStack(spacing: 0) {
            TopBar()
            ControlFocusBanner()
            GeometryReader { geo in
                let activeAudioInputs = engine.inputs.filter { $0.hasAudio && $0.audioFX.visibleInMixer }
                let lay = SwitcherLayout(size: geo.size, mixerVisible: engine.mixerVisible,
                                       strips: 1 + engine.visibleBuses.count + (audioInputStripsCollapsed ? 0 : activeAudioInputs.count),
                                       inputStripsCollapsed: audioInputStripsCollapsed,
                                       topFraction: monitorFraction)
                VStack(spacing: 0) {
                    // Preview | transitions | Output — height follows the 16:9 monitors so nothing hangs below them
                    HStack(alignment: .top, spacing: SwitcherLayout.gap) {
                        let pvw = engine.input(withID: engine.previewID)
                        let hasPvw = pvw != nil
                        let pslot = engine.previewSlot
                        let eng = engine
                        // vMix Preview shows the input as it will appear (Position/crop applied)
                        MonitorPane(title: "Preview", color: Theme.preview, input: pvw,
                                    editLayers: { pvw.map { [EditableLayer(input: $0, label: $0.name)] } ?? [] }) {
                            // read by the display thread: composed frame when repositioned, else the input itself
                            hasPvw ? (eng.previewComposed ? pslot.latest() : pvw?.currentFrame()) : nil
                        }
                        .frame(width: lay.monitorWidth)
                        TransitionColumn()
                            .frame(width: SwitcherLayout.transitionWidth, height: lay.topHeight)
                        MonitorPane(title: "Output", color: Theme.program, input: engine.input(withID: engine.programID),
                                    editLayers: { engine.outputEditLayers() }) {
                            engine.programSlot.latest()
                        }
                        .frame(width: lay.monitorWidth)
                    }
                    .frame(width: geo.size.width, height: lay.topHeight + SwitcherLayout.gap * 2)

                    // draggable divider (monitors ↕ inputs)
                    ZStack {
                        Rectangle().fill(Color.black).frame(height: 1)
                        Capsule().fill(Color.white.opacity(0.18)).frame(width: 40, height: 3)
                    }
                    .frame(height: 7)
                    .frame(maxWidth: .infinity)
                    .contentShape(Rectangle())
                    .onHover { inside in if inside { NSCursor.resizeUpDown.push() } else { NSCursor.pop() } }
                    .gesture(DragGesture(minimumDistance: 1)
                        .onChanged { g in
                            let start = dragStartFraction ?? min(monitorFraction, Double(lay.topHeight / max(1, geo.size.height)))
                            if dragStartFraction == nil { dragStartFraction = start }
                            monitorFraction = min(0.8, max(0.2, start + Double(g.translation.height / max(1, geo.size.height))))
                        }
                        .onEnded { _ in dragStartFraction = nil })
                    .help(L("드래그해서 입력 영역 크기 조절"))

                    // Inputs (fill the rest) | Audio mixer docked right, same height
                    HStack(spacing: 0) {
                        InputGrid(sheet: $sheet)
                            .frame(maxWidth: inputDockLeft ? nil : .infinity, maxHeight: .infinity, alignment: .topLeading)
                        if inputDockLeft { Spacer(minLength: 0) }
                        if engine.mixerVisible {
                            Rectangle().fill(Color.black).frame(width: 1)
                            AudioMixerPanel(sheet: $sheet, inputStripsCollapsed: $audioInputStripsCollapsed)
                                .frame(width: lay.mixerWidth)
                                .frame(maxHeight: .infinity)
                        }
                    }
                    .frame(width: geo.size.width)
                    .frame(maxHeight: .infinity)
                    .clipped()
                }
            }

            BottomBar(sheet: $sheet, outputsSheet: $outputsSheet)
        }
        .background(
            Theme.window
        )
        .sheet(item: $sheet) { req in
            switch req.mode {
            case .source:
                InputEditorSheet(kind: req.kind, editing: req.editing)
                    .environmentObject(engine)
            case .properties:
                if let input = req.editing {
                    InputPropertiesSheet(input: input, initialTab: req.tab, onChangeSource: {
                        sheet = SheetRequest(kind: input.kind, editing: input)
                    })
                    .environmentObject(engine)
                }
            case .title:
                if let t = req.editing as? TitleInput {
                    TitleEditorSheet(title: t)
                        .environmentObject(engine)
                }
            }
        }
        .sheet(item: $outputsSheet) { kind in
            OutputsSheet(focusKind: kind)
                .environmentObject(engine)
        }
        .background(KeyboardShortcuts())
    }
}

/// Main-window geometry: monitors keep 16:9, the transition column matches their height,
/// and the audio mixer gets just enough width for its strips (max ~45% of the window).
struct SwitcherLayout {
    static let gap: CGFloat = 6
    static let transitionWidth: CGFloat = 168
    static let header: CGFloat = 22
    static let transport: CGFloat = 26      // vMix video controls row under each monitor
    static let stripWidth: CGFloat = 72
    /// Smallest height the TransitionColumn's fixed controls need (header gap, Quick Play, Cut,
    /// 4 transition rows, Stinger, Overlay 1–8, T-bar min 56, FTB + spacing). Below this the
    /// column overflowed its frame and its top/bottom buttons were pushed outside.
    static let transitionMinHeight: CGFloat = 414

    let monitorWidth: CGFloat
    let topHeight: CGFloat
    let mixerWidth: CGFloat

    init(size: CGSize, mixerVisible: Bool, strips: Int, inputStripsCollapsed: Bool = false,
         topFraction: Double = 0.58) {
        let maxTop = max(200, size.height * CGFloat(topFraction))
        var mw = max(200, (size.width - Self.transitionWidth - Self.gap * 4) / 2)
        var h = mw * 9 / 16 + Self.header + Self.transport
        if h > maxTop {                       // short window: shrink monitors, keep aspect
            h = maxTop
            mw = (h - Self.header - Self.transport) * 16 / 9
        }
        monitorWidth = mw
        topHeight = max(h, Self.transitionMinHeight)
        let want = CGFloat(strips) * Self.stripWidth + 12
        // wide enough for the mixer header's title + buttons (it overflowed and pushed the
        // collapse chevron off-screen at 120 / 300)
        let minimumMixerWidth: CGFloat = inputStripsCollapsed ? 250 : 340
        mixerWidth = mixerVisible ? min(max(minimumMixerWidth, want + (inputStripsCollapsed ? 36 : 0)), size.width * 0.45) : 0
    }
}

extension OutputKind: Identifiable {
    var id: String { rawValue }
}

// MARK: - Top status bar

struct TopBar: View {
    @EnvironmentObject var engine: SwitcherEngine

    var body: some View {
        HStack(spacing: 14) {
            Text("HongMix")
                .font(.system(size: 12, weight: .bold))
                .foregroundColor(Theme.buttonText)
            Text("v" + AppInfo.version)
                .font(.system(size: 10, weight: .semibold).monospacedDigit())
                .foregroundColor(.secondary)
                .help(Lf("HongMix 버전 %@ (빌드 %@)", AppInfo.version, AppInfo.build))
            Text(engine.format.name)
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(.secondary)
                .lineLimit(1)
            if let t = engine.undoTitle {
                Button { engine.undoClose() } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "arrow.uturn.backward")
                        Text("Undo")
                    }
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(.white)
                    .padding(.horizontal, 8).frame(height: 20)
                    .background(Theme.button)
                    .clipShape(RoundedRectangle(cornerRadius: Theme.radius, style: .continuous))
                }
                .buttonStyle(.plain)
                .help(Lf("방금 닫은 입력 되살리기: %@", "\(t)"))
            }
            Spacer()
            if !engine.lostInputs.isEmpty {
                Text(Lf("⚠︎ 신호 끊김 %@", "\(engine.lostInputs.count)"))
                    .font(.system(size: 11, weight: .heavy))
                    .foregroundColor(.white)
                    .padding(.horizontal, 6)
                    .background(Theme.live)
                    .clipShape(RoundedRectangle(cornerRadius: Theme.radius, style: .continuous))
            }
            if !engine.recordRemaining.isEmpty {
                Text(engine.recordRemaining)
                    .font(.system(size: 11, weight: .semibold).monospacedDigit())
                    .foregroundColor(engine.recordRemaining.contains(L("분")) ? .orange : .secondary)
                    .help(L("녹화 폴더 디스크에 남은 녹화 가능 시간 (현재 비트레이트 기준)"))
            }
            DelayStatusChips()
            EngineStatsChips(stats: engine.stats)
            if AppSkin.isMono && engine.anyRunning(kind: .stream) {
                OnAirChip()
            }
            if engine.ftbOn {
                Text("FTB")
                    .font(.system(size: 11, weight: .heavy))
                    .padding(.horizontal, 6)
                    .background(Theme.live)
                    .clipShape(RoundedRectangle(cornerRadius: Theme.radius, style: .continuous))
            }
            FocusChip()
            SettingsLink {
                Image(systemName: "gearshape")
            }
            .buttonStyle(.plain)
            .help(L("설정"))
        }
        .padding(.horizontal, AppSkin.isMono ? 14 : 10)
        .frame(height: AppSkin.isMono ? 30 : 26)
        .hmGlass(cornerRadius: 15)
        .padding(.horizontal, AppSkin.isMono ? 8 : 0)
        .padding(.vertical, AppSkin.isMono ? 5 : 0)
    }
}

/// "● ON AIR 00:41:07" — time since the first stream output went live.
struct OnAirChip: View {
    @EnvironmentObject var engine: SwitcherEngine

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { ctx in
            let since = engine.outputs.filter { $0.config.kind == .stream && $0.running }.compactMap { $0.liveSince }.min()
            let t = since.map { Int(ctx.date.timeIntervalSince($0)) } ?? 0
            Text(String(format: "● ON AIR %02d:%02d:%02d", t / 3600, (t / 60) % 60, t % 60))
                .font(.system(size: 11, weight: .bold).monospacedDigit())
                .foregroundColor(Color(red: 1, green: 0.42, blue: 0.38))
                .padding(.horizontal, 9).frame(height: 20)
                .background(Capsule().fill(Theme.program.opacity(0.18)))
        }
    }
}

/// FPS / Render / Max / Drop — redrawn once a second without touching the rest of the window.
struct EngineStatsChips: View {
    @EnvironmentObject var engine: SwitcherEngine
    @ObservedObject var stats: EngineStats

    var body: some View {
        let budget = engine.format.frameDuration * 1000
        HStack(spacing: 14) {
            StatusChip(label: "FPS", value: String(format: "%.2f", engine.format.fps))
            StatusChip(label: "Render", value: String(format: "%.1f ms", engine.renderMs),
                       warn: engine.renderMs > budget * 0.8)
                .help(String(format: L("1초 평균 %.1f ms · 최대 %.1f ms (프레임 예산 %.1f ms)"),
                             engine.renderMs, engine.renderMsPeak, budget))
            StatusChip(label: "Max", value: String(format: "%.1f ms", engine.renderMsPeak),
                       warn: engine.renderMsPeak > budget)
            StatusChip(label: "Drop", value: "\(engine.droppedTicks)", warn: engine.droppedTicks > 0)
                .onTapGesture { engine.resetDrops() }
                .help(L("렌더러가 늦어 건너뛴 프레임 수 (앱 시작 이후 누적). 클릭하면 0으로."))
        }
    }
}

struct StatusChip: View {
    let label: String
    let value: String
    var warn = false

    var body: some View {
        HStack(spacing: 4) {
            Text(label).foregroundColor(.secondary)
            Text(value).foregroundColor(warn ? .orange : Theme.buttonText)
        }
        .font(.system(size: 11).monospacedDigit())
    }
}

// MARK: - Monitors

struct MonitorPane: View {
    @EnvironmentObject var engine: SwitcherEngine
    let title: String
    let color: Color
    let input: InputSource?
    var editLayers: () -> [EditableLayer] = { [] }
    let source: () -> CVPixelBuffer?
    @AppStorage("previewSafeAreas") private var safeAreas = false

    private var browser: BrowserInput? { input as? BrowserInput }

    var body: some View {
        let mono = AppSkin.isMono
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                if mono {
                    Circle().fill(color).frame(width: 7, height: 7)
                    Text(title == "Output" ? "PROGRAM" : title.uppercased())
                        .font(.system(size: 11, weight: .bold)).tracking(0.6)
                    Text(input.map { "· \($0.name)" } ?? "")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(Color(white: 0.6))
                        .lineLimit(1)
                } else {
                    Text(title)
                        .font(.system(size: 12, weight: .bold))
                    Text(input?.name ?? "")
                        .font(.system(size: 12))
                        .lineLimit(1)
                }
                if let i = input {
                    InputFormatLabel(slot: i.video, size: 10)
                    MonitorLossChip(input: i)
                }
                Spacer()
                if let b = browser, !engine.positionEdit {
                    BrowserBadge(browser: b)
                }
                if title == "Preview" {
                    Button { safeAreas.toggle() } label: {
                        Image(systemName: "rectangle.dashed")
                            .font(.system(size: 10, weight: .semibold))
                            .padding(.horizontal, 6).frame(height: 16)
                            .background(safeAreas ? Color.white.opacity(0.9) : Color.black.opacity(0.3))
                            .foregroundColor(safeAreas ? .black : .white)
                            .clipShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .help(L("Safe Areas — 90% 액션 세이프 / 80% 타이틀 세이프 / 중앙 표시"))
                }
                Button { engine.positionEdit.toggle() } label: {
                    HStack(spacing: 3) {
                        Image(systemName: "arrow.up.and.down.and.arrow.left.and.right")
                        Text(L("위치"))
                    }
                    .font(.system(size: 10, weight: .semibold))
                    .padding(.horizontal, 6).frame(height: 16)
                    .background(engine.positionEdit ? Color.yellow.opacity(0.9) : Color.black.opacity(0.3))
                    .foregroundColor(engine.positionEdit ? .black : .white)
                    .clipShape(Capsule())
                }
                .buttonStyle(.plain)
                .help(L("위치 편집: 모니터에서 입력·자막·이미지를 드래그해 옮기고 모서리로 크기 조절 (Input Settings › Position 값이 바뀝니다)"))
            }
            .foregroundColor(.white)
            .padding(.horizontal, mono ? 10 : 8)
            .frame(height: mono ? 26 : 22)
            .background(mono ? Theme.panelDark : color)
            ZStack {
                MonitorView(fps: 60, countDraws: title == "Output", source: source)
                if title == "Preview" && safeAreas {
                    SafeAreaGuides().allowsHitTesting(false)
                }
                if title == "Output" {
                    OutputAlerts()
                }
                if engine.positionEdit {
                    PositionEditLayer(layers: editLayers())
                } else if let b = browser {
                    BrowserInteractionLayer(browser: b, sourceSize: {
                        // both monitors draw the composed 16:9 frame
                        guard let pb = source() else { return nil }
                        return CGSize(width: CVPixelBufferGetWidth(pb), height: CVPixelBufferGetHeight(pb))
                    })
                }
            }
            .aspectRatio(16.0 / 9.0, contentMode: .fit)
            .background(Color.black)
            TransportBar(input: input)
        }
        .background(Color.black)
        .clipShape(RoundedRectangle(cornerRadius: mono ? 10 : 0, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: mono ? 10 : 0, style: .continuous).stroke(color, lineWidth: mono ? 1.5 : 2))
        .frame(maxWidth: .infinity)
    }
}

struct MonitorLossChip: View {
    @ObservedObject var input: InputSource
    var body: some View {
        if input.signalLost { SignalLostBadge(input: input, big: true).padding(-4) }
    }
}

/// Shows that the browser in this monitor takes mouse/keyboard, and whether it currently has the keyboard.
struct BrowserBadge: View {
    @ObservedObject var browser: BrowserInput

    var body: some View {
        if browser.mouseEnabled {
            HStack(spacing: 4) {
                Image(systemName: browser.keyboardFocused ? "keyboard.fill" : "cursorarrow.click")
                Text(browser.keyboardFocused ? L("키보드 입력 중 · Esc 해제") : L("클릭해서 조작"))
                    .lineLimit(1).truncationMode(.tail)
            }
            .font(.system(size: 10, weight: .semibold))
            .padding(.horizontal, 6)
            .padding(.vertical, 1)
            .background(browser.keyboardFocused ? Color.orange : Color.black.opacity(0.35))
            .clipShape(Capsule())
            .help(L("vMix처럼 모니터에서 웹 페이지를 마우스/키보드로 조작합니다. Esc 또는 다른 곳을 클릭하면 스위처 단축키로 돌아갑니다."))
        }
    }
}

// MARK: - Bottom bar

struct BottomBar: View {
    @EnvironmentObject var engine: SwitcherEngine
    @Environment(\.openWindow) private var openWindow
    @Binding var sheet: SheetRequest?
    @Binding var outputsSheet: OutputKind?
    @ViewState private var utilitySheet: UtilitySheet?
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    private enum UtilitySheet: String, Identifiable {
        case overlay, scheduler, captions, preflight, monitoring, multiCorder, allOutputs
        var id: String { rawValue }
    }

    var body: some View {
        HStack(spacing: 6) {
            Button {
                sheet = SheetRequest(kind: .media, editing: nil)
            } label: {
                Text("Add Input")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(.white)
                    .padding(.horizontal, 14)
                    .frame(height: 30)
                    .background(Theme.button)
                    .clipShape(RoundedRectangle(cornerRadius: Theme.radius, style: .continuous))
            }
            .buttonStyle(.plain)
            .keyboardShortcut("i", modifiers: [.command])
            .help(L("입력 추가 (⌘I)"))

            OutputBarButton(title: "Record", kind: .record, outputsSheet: $outputsSheet)
            OutputBarButton(title: "External", kind: .ndi, alsoKind: .decklink, outputsSheet: $outputsSheet)
            OutputBarButton(title: "Stream", kind: .stream, outputsSheet: $outputsSheet)
            FullscreenBarButton()
            ToolBarWindowButton(title: "Replay", symbol: "gobackward", windowID: "replay",
                                help: L("Instant Replay — 녹화 · 마크 · 슬로모션 재생"))
            ToolBarWindowButton(title: "Scopes", symbol: "waveform.path.ecg", windowID: "scopes",
                                help: L("스코프 — 파형 · 벡터스코프 · 히스토그램"))
            ToolBarWindowButton(title: "PTZ", symbol: "camera.metering.center.weighted", windowID: "ptz",
                                help: L("PTZ 컨트롤 — 1~9 카메라 · WASD 이동 · Q/E 줌 · Z/X 포커스"))
            Button {
                engine.mixerVisible.toggle()
            } label: {
                Image(systemName: "slider.vertical.3")
                    .foregroundColor(.white)
                    .frame(width: 30, height: 30)
                    .background(engine.mixerVisible ? Theme.accent : Theme.button)
                    .clipShape(RoundedRectangle(cornerRadius: Theme.radius, style: .continuous))
            }
            .buttonStyle(.plain)
            .help(L("Audio Mixer 보이기/숨기기"))

            Menu {
                Button(engine.multiCorderOn ? L("MultiCorder 녹화 중지") : L("MultiCorder 시작")) {
                    if engine.multiCorderOn { engine.stopMultiCorder() } else { engine.startMultiCorder() }
                }
                Button(L("MultiCorder 설정…")) { utilitySheet = .multiCorder }
                Button(L("모든 출력 보기…")) { utilitySheet = .allOutputs }
                Divider()
                Button(L("Overlay 설정…")) { utilitySheet = .overlay }
                Button(L("Rundown / 큐시트")) { openWindow(id: "rundown") }
                Button(L("스케줄러…")) { utilitySheet = .scheduler }
                Button(L("자막…")) { utilitySheet = .captions }
                Button(L("송출 전 점검…")) { utilitySheet = .preflight }
                Button(L("상황판 / 블랙박스…")) { utilitySheet = .monitoring }
                Divider()
                Button(L("스냅샷 저장")) { engine.snapshot() }
            } label: {
                Label(L("도구"), systemImage: "ellipsis")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(.white)
                    .padding(.horizontal, 10)
                    .frame(height: 30)
                    .background(Theme.button)
                    .clipShape(RoundedRectangle(cornerRadius: Theme.radius, style: .continuous))
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .help(L("도구: MultiCorder, 모든 출력, Overlay, 큐시트, 스케줄, 자막, 상황판, 스냅샷"))

            Spacer()
            Button {
                openWindow(id: "statistics")
            } label: {
                Image(systemName: "chart.bar.xaxis")
                    .foregroundColor(.white)
                    .frame(width: 30, height: 30)
                    .background(Theme.button)
                    .clipShape(RoundedRectangle(cornerRadius: Theme.radius, style: .continuous))
            }
            .buttonStyle(.plain)
            .help(L("Statistics — 별도 모니터링 창 열기 (다른 디스플레이·데스크톱으로 이동 가능)"))
            VStack(alignment: .trailing, spacing: 1) {
                Text(engine.apiStatus)
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
                    .textSelection(.enabled)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: 220, alignment: .trailing)
                if !engine.lastMessage.isEmpty {
                    Text(engine.lastMessage)
                        .font(.system(size: 10))
                        .foregroundColor(.orange)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .frame(maxWidth: 360, alignment: .trailing)
                        .help(engine.lastMessage)
                }
            }
            .layoutPriority(-1)
        }
        .padding(.horizontal, AppSkin.isMono ? 10 : 8)
        .padding(.vertical, 5)
        .hmGlass(cornerRadius: 22)
        .padding(.horizontal, AppSkin.isMono ? 8 : 0)
        .padding(.bottom, AppSkin.isMono ? 6 : 0)
        .sheet(item: $utilitySheet) { destination in
            switch destination {
            case .overlay: OverlaySettingsSheet().environmentObject(engine)
            case .scheduler: SchedulerSheet(scheduler: engine.scheduler).environmentObject(engine)
            case .captions: CaptionsSheet(captions: engine.captions).environmentObject(engine)
            case .preflight: PreflightSheet().environmentObject(engine)
            case .monitoring: MonitoringSheet(srt: engine.srtMonitor, box: engine.blackbox).environmentObject(engine)
            case .multiCorder: MultiCorderSheet().environmentObject(engine)
            case .allOutputs: OutputsSheet().environmentObject(engine)
            }
        }
    }
}

/// "Record ⚙" style toggle: main part starts/stops, gear opens settings.
struct OutputBarButton: View {
    @EnvironmentObject var engine: SwitcherEngine
    let title: String
    let kind: OutputKind
    var alsoKind: OutputKind? = nil
    @Binding var outputsSheet: OutputKind?

    private var kinds: [OutputKind] { [kind] + (alsoKind.map { [$0] } ?? []) }
    @ViewState private var preflight = false
    @ViewState private var streamMonitor = false

    /// Monochrome: capsule with live status — "● REC 00:12:31 · 30.0 Mb/s".
    @ViewBuilder private func monoLabel(on: Bool, error: Bool) -> some View {
        let short: String = kind == .record ? "REC" : (kind == .stream ? "STREAM" : title.uppercased())
        let running = engine.outputs.filter { kinds.contains($0.config.kind) && $0.running }
        if !on {
            // idle: no 1 s timer
            Text(short).foregroundColor(.white)
                .font(.system(size: 12, weight: .semibold))
                .padding(.horizontal, 14)
                .frame(height: 30)
                .background(Color.white.opacity(0.07))
        } else {
        TimelineView(.periodic(from: .now, by: 1)) { ctx in
            HStack(spacing: 7) {
                if on {
                    let diskWarn = kind == .record && engine.recordingSafety.diskWarning
                    Text("● " + short).foregroundColor(error || diskWarn ? .orange : Color(red: 1, green: 0.42, blue: 0.38))
                    let since = running.compactMap { $0.liveSince }.min()
                    let t = since.map { Int(ctx.date.timeIntervalSince($0)) } ?? 0
                    let mbps = running.map { $0.lastKbps }.reduce(0, +) / 1000
                    // REC also shows the disk time left ("· 38 min left"), orange once below the warning threshold
                    let left = kind == .record ? engine.recordingSafety.lowestRemainingSeconds.flatMap { $0 < 24 * 3600 ? $0 : nil } : nil
                    Text(String(format: "%02d:%02d:%02d", t / 3600, (t / 60) % 60, t % 60) +
                         (left != nil ? " · " + RecordingSafety.remainingText(left) : (mbps > 0 ? String(format: " · %.1f Mb/s", mbps) : "")))
                        .foregroundColor(diskWarn ? .orange : Color(white: 0.72))
                        .monospacedDigit()
                } else {
                    Text(short).foregroundColor(.white)
                }
            }
            .font(.system(size: 12, weight: .semibold))
            .lineLimit(1)
            .padding(.horizontal, 14)
            .frame(height: 30)
            .background(on ? Theme.program.opacity(error ? 0.10 : 0.16) : Color.white.opacity(0.07))
        }
        }
    }

    var body: some View {
        let configured = engine.outputs.contains { kinds.contains($0.config.kind) }
        let on = kinds.contains { engine.anyRunning(kind: $0) }
        let error = engine.outputs.contains { kinds.contains($0.config.kind) && $0.running && $0.state == Int32(MC_STATE_ERROR) }
        // stream: running but not connected (failed / reconnecting) → blinking orange instead of red
        let disconnected = kind == .stream && engine.outputs.contains {
            kinds.contains($0.config.kind) && $0.running && $0.state != Int32(MC_STATE_RUNNING)
        }
        HStack(spacing: 0) {
            Button {
                if !configured {
                    outputsSheet = kind
                } else if !on && kind == .stream && engine.preflight().contains(where: { $0.level != .ok }) {
                    preflight = true          // something needs a look before going live
                } else {
                    for k in kinds { engine.setOutputs(kind: k, running: !on) }
                }
            } label: {
                if disconnected {
                    BlinkingOrangeLabel(text: AppSkin.isMono ? "● STREAM" : title, mono: AppSkin.isMono)
                } else if AppSkin.isMono {
                    monoLabel(on: on, error: error)
                } else {
                    Text(title)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(.white)
                        .padding(.horizontal, 14)
                        .frame(height: 30)
                        .background(on ? (error || (kind == .record && engine.recordingSafety.diskWarning) ? Color.orange : Theme.live) : Theme.button)
                }
            }
            .buttonStyle(.plain)
            Button {
                outputsSheet = kind
            } label: {
                Image(systemName: "gearshape.fill")
                    .font(.system(size: 10))
                    .foregroundColor(.white.opacity(0.8))
                    .frame(width: AppSkin.isMono ? 28 : 22, height: 30)
                    .background(AppSkin.isMono ? Color.white.opacity(0.06) : Theme.button.opacity(0.8))
            }
            .buttonStyle(.plain)
            .help(Lf("%@ 설정", "\(title)"))
            if kind == .stream {
                Button { streamMonitor = true } label: {
                    Image(systemName: "chart.bar.xaxis")
                        .font(.system(size: 10))
                        .foregroundColor(.white.opacity(0.8))
                        .frame(width: AppSkin.isMono ? 28 : 22, height: 30)
                        .background(AppSkin.isMono ? Color.white.opacity(0.06) : Theme.button.opacity(0.8))
                }
                .buttonStyle(.plain)
                .help(L("송출 모니터"))
                .popover(isPresented: $streamMonitor, arrowEdge: .top) { StreamMonitorView().environmentObject(engine) }
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: AppSkin.isMono ? 15 : 3, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: AppSkin.isMono ? 15 : 3, style: .continuous)
            .stroke(AppSkin.isMono ? (disconnected ? Color.orange.opacity(0.8) : on ? Theme.program.opacity(0.55) : Color.white.opacity(0.10)) : .clear, lineWidth: 1))
        .help(disconnected ? L("송출 연결 안 됨 — 다시 연결하는 중 (설정에서 상태 확인)") : "")
        .sheet(isPresented: $preflight) {
            PreflightSheet(proceedTitle: L("그래도 송출 시작"), onProceed: {
                for k in kinds { engine.setOutputs(kind: k, running: true) }
            })
            .environmentObject(engine)
        }
    }
}

struct FullscreenBarButton: View {
    @EnvironmentObject var engine: SwitcherEngine
    @ViewState private var showSettings = false

    var body: some View {
        let output = FullscreenOutput.shared
        let on = output.isShowing
        let mono = AppSkin.isMono
        HStack(spacing: 0) {
            Button {
                output.toggle(engine: engine)
                engine.objectWillChange.send()
            } label: {
                HStack(spacing: 6) {
                    if mono && on { Text("●").foregroundColor(Color(red: 1, green: 0.42, blue: 0.38)) }
                    Text(mono ? "DISPLAY" : "Display")
                    if mono && on {
                        Text(output.source.label).foregroundColor(Color(white: 0.72)).lineLimit(1)
                    }
                    if DisplayMap.shared.showingCount > 0 {
                        Text("+\(DisplayMap.shared.showingCount)")
                            .foregroundColor(Color(white: 0.85))
                            .help(Lf("모니터별 출력 %@개 켜짐", "\(DisplayMap.shared.showingCount)"))
                    }
                }
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(.white)
                .padding(.horizontal, 14)
                .frame(height: 30)
                .background(mono ? (on ? Theme.program.opacity(0.16) : Color.white.opacity(0.07)) : (on ? Theme.live : Theme.button))
            }
            .buttonStyle(.plain)
            .help(L("디스플레이 출력 켜기/끄기"))
            Button { showSettings.toggle() } label: {
                Image(systemName: "gearshape.fill")
                    .font(.system(size: 10))
                    .foregroundColor(.white.opacity(0.8))
                    .frame(width: mono ? 28 : 22, height: 30)
                    .background(mono ? Color.white.opacity(0.06) : Theme.button.opacity(0.8))
            }
            .buttonStyle(.plain)
            .help(L("디스플레이 출력 설정"))
            .popover(isPresented: $showSettings, arrowEdge: .top) {
                DisplaySettingsPanel().environmentObject(engine)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: mono ? 15 : Theme.radius, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: mono ? 15 : Theme.radius, style: .continuous)
            .stroke(mono ? (on ? Theme.program.opacity(0.55) : Color.white.opacity(0.10)) : .clear, lineWidth: 1))
    }
}

/// Display ⚙: mode, monitor, source and window options for the display output.
struct DisplaySettingsPanel: View {
    @EnvironmentObject var engine: SwitcherEngine

    private var sources: [BusSource] {
        [.program, .clean, .preview, .multiview] + engine.inputs.map { .input($0.id) }
    }

    private func sourceTitle(_ src: BusSource) -> String {
        if case .input(let id) = src, let i = engine.input(withID: id) { return "Input \(engine.number(of: i)) — \(i.name)" }
        return src.label
    }

    var body: some View {
        let output = FullscreenOutput.shared
        VStack(alignment: .leading, spacing: 12) {
            Text(L("디스플레이 출력")).font(.headline)
            Picker(L("방식"), selection: Binding(get: { output.mode }, set: { output.open($0, engine: engine) })) {
                ForEach(DisplayOutputMode.allCases, id: \.rawValue) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            Picker(L("디스플레이"), selection: Binding(get: { output.displayID }, set: { output.setDisplay($0, engine: engine) })) {
                Text(L("자동 (스위처가 없는 화면)")).tag(CGDirectDisplayID(0))
                ForEach(FullscreenOutput.screens(), id: \.id) { Text($0.name).tag($0.id) }
            }
            Picker(L("소스"), selection: Binding(get: { output.source }, set: { output.setSource($0, engine: engine) })) {
                ForEach(sources, id: \.self) { Text(sourceTitle($0)).tag($0) }
            }
            if output.mode == .window {
                Toggle(L("항상 위에 표시"), isOn: Binding(get: { output.alwaysOnTop },
                                                     set: { output.alwaysOnTop = $0; engine.objectWillChange.send() }))
                Toggle(L("16:9 비율 고정"), isOn: Binding(get: { output.lockAspect },
                                                     set: { output.lockAspect = $0; engine.objectWillChange.send() }))
                Text(L("출력 창의 초록 버튼을 누르면 그 창이 있는 디스플레이를 꽉 채웁니다. Esc · 더블클릭 · 우클릭으로 창으로 돌아옵니다."))
                    .font(.caption).foregroundColor(.secondary).fixedSize(horizontal: false, vertical: true)
            } else {
                Picker(L("데스크탑"), selection: Binding(get: { output.pin },
                                                     set: { output.pin = $0; engine.objectWillChange.send() })) {
                    ForEach(DesktopPin.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                .help(DesktopPin.help)
                Text(L("지정한 디스플레이를 방송 화면으로 채웁니다. 스위처와 같은 화면이면 Esc · 더블클릭 · 우클릭으로 닫습니다."))
                    .font(.caption).foregroundColor(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                if output.isShowing {
                    Button(L("디스플레이 끄기")) {
                        output.hide(); engine.objectWillChange.send()
                    }
                    Spacer()
                    Button(output.mode == .window ? L("전체화면으로 전환") : L("출력 창으로 전환")) {
                        output.open(output.mode == .window ? .fullscreen : .window, engine: engine)
                    }
                } else {
                    Button(L("출력 창 열기")) { output.open(.window, engine: engine) }
                    Spacer()
                    Button(L("전체화면 열기")) { output.open(.fullscreen, engine: engine) }
                }
            }
            if NSScreen.screens.count > 1 || !DisplayMap.shared.waiting.isEmpty {
                Divider()
                MonitorOutputsSection(sources: sources, title: sourceTitle)
            }
        }
        .padding(16)
        .frame(width: 460)
    }
}

/// Bottom-bar shortcut to a tool window (Instant Replay, Scopes).
struct ToolBarWindowButton: View {
    @Environment(\.openWindow) private var openWindow
    let title: String
    let symbol: String
    let windowID: String
    let help: String

    var body: some View {
        let mono = AppSkin.isMono
        Button { openWindow(id: windowID) } label: {
            HStack(spacing: 5) {
                Image(systemName: symbol).font(.system(size: 11, weight: .semibold))
                Text(title).font(.system(size: 12, weight: .semibold))
            }
            .foregroundColor(.white)
            .padding(.horizontal, 12)
            .frame(height: 30)
            .background(mono ? Color.white.opacity(0.07) : Theme.button)
            .clipShape(RoundedRectangle(cornerRadius: mono ? 15 : Theme.radius, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: mono ? 15 : Theme.radius, style: .continuous)
                .stroke(mono ? Color.white.opacity(0.10) : .clear, lineWidth: 1))
        }
        .buttonStyle(.plain)
        .help(help)
    }
}

struct MultiCorderBarButton: View {
    @EnvironmentObject var engine: SwitcherEngine
    @ViewState private var showSettings = false

    var body: some View {
        HStack(spacing: 0) {
            Button {
                if engine.multiCorderOn { engine.stopMultiCorder() } else { engine.startMultiCorder() }
            } label: {
                Text("MultiCorder")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(.white)
                    .padding(.horizontal, 14)
                    .frame(height: 30)
                    .background(engine.multiCorderOn ? (engine.multiCorderError != nil ? Color.orange : Theme.live) : Theme.button)
            }
            .buttonStyle(.plain)
            .help(engine.multiCorderError ?? "")
            Button {
                showSettings = true
            } label: {
                Image(systemName: "gearshape.fill")
                    .font(.system(size: 10))
                    .foregroundColor(.white.opacity(0.8))
                    .frame(width: 22, height: 30)
                    .background(Theme.button.opacity(0.8))
            }
            .buttonStyle(.plain)
        }
        .clipShape(RoundedRectangle(cornerRadius: Theme.radius, style: .continuous))
        .sheet(isPresented: $showSettings) {
            MultiCorderSheet().environmentObject(engine)
        }
    }
}

struct MultiCorderSheet: View {
    @EnvironmentObject var engine: SwitcherEngine
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            Text(L("MultiCorder — 입력별 ISO 녹화")).font(.headline).padding()
            Form {
                Section(L("저장")) {
                    HStack {
                        TextField(L("폴더"), text: $engine.multiCorderSettings.folder)
                        Button(L("선택…")) {
                            let p = NSOpenPanel()
                            p.canChooseDirectories = true
                            p.canChooseFiles = false
                            p.canCreateDirectories = true
                            if p.runModal() == .OK, let u = p.url { engine.multiCorderSettings.folder = u.path }
                        }
                    }
                    Picker(L("코덱"), selection: $engine.multiCorderSettings.videoCodec) {
                        Text("H.264").tag("h264")
                        Text("HEVC").tag("hevc")
                        Text("ProRes 422").tag("prores")
                    }
                    Picker(L("컨테이너"), selection: $engine.multiCorderSettings.container) {
                        Text("MOV").tag("mov")
                        Text("MP4").tag("mp4")
                        Text("MPEG-TS").tag("ts")
                    }
                    .disabled(engine.multiCorderSettings.videoCodec == "prores")
                    NumberField(L("비트레이트"), value: $engine.multiCorderSettings.videoKbps, in: 2000...150000, unit: "kbps", step: 2000)
                }
                Section(L("녹화할 입력")) {
                    ForEach(engine.inputs) { i in
                        MultiCorderInputRow(input: i, number: engine.number(of: i))
                    }
                }
            }
            .formStyle(.grouped)
            .textFieldStyle(.roundedBorder)
            .disabled(engine.multiCorderOn)
            HStack {
                Text(engine.multiCorderOn ? L("녹화 중에는 설정을 바꿀 수 없습니다") : "")
                    .font(.caption).foregroundColor(.orange)
                    .lineLimit(2).fixedSize(horizontal: false, vertical: true)
                Spacer()
                Button(L("닫기")) { dismiss() }.keyboardShortcut(.defaultAction)
            }
            .padding()
        }
        .frame(width: 520, height: 560)
    }
}

struct MultiCorderInputRow: View {
    @ObservedObject var input: InputSource
    let number: Int

    var body: some View {
        Toggle("\(number). \(input.name)", isOn: $input.multiCorder)
    }
}

/// Hidden buttons that provide keyboard shortcuts.
struct KeyboardShortcuts: View {
    @EnvironmentObject var engine: SwitcherEngine

    var body: some View {
        ZStack {
            Button("Cut") { engine.cut() }.keyboardShortcut(.space, modifiers: [])
            Button("Quick Play") { engine.transition(slot: 1) }.keyboardShortcut(.return, modifiers: [])
            Button("FTB") { engine.toggleFTB() }.keyboardShortcut("b", modifiers: [.command, .shift])
            ForEach(1..<5) { n in
                Button("Transition \(n)") { engine.transition(slot: n) }
                    .keyboardShortcut(KeyEquivalent(Character("\(n)")), modifiers: [.option])
            }
            ForEach(1..<10) { n in
                Button("Preview \(n)") {
                    if engine.inputs.count >= n { engine.setPreview(engine.inputs[n - 1].id) }
                }
                .keyboardShortcut(KeyEquivalent(Character("\(n)")), modifiers: [])
                Button("Cut \(n)") {
                    if engine.inputs.count >= n { engine.cutDirect(engine.inputs[n - 1].id) }
                }
                .keyboardShortcut(KeyEquivalent(Character("\(n)")), modifiers: [.command])
            }
        }
        .frame(width: 0, height: 0)
        .opacity(0)
        .accessibilityHidden(true)
    }
}


/// Action-safe (90 %) and title-safe (80 %) guides with a centre cross (vMix Safe Areas).
struct SafeAreaGuides: View {
    var body: some View {
        GeometryReader { g in
            let w = g.size.width, h = g.size.height
            ZStack(alignment: .topLeading) {
                Rectangle().stroke(Color.white.opacity(0.6), style: StrokeStyle(lineWidth: 1, dash: [5, 4]))
                    .frame(width: w * 0.9, height: h * 0.9).offset(x: w * 0.05, y: h * 0.05)
                Rectangle().stroke(Color.yellow.opacity(0.6), style: StrokeStyle(lineWidth: 1, dash: [5, 4]))
                    .frame(width: w * 0.8, height: h * 0.8).offset(x: w * 0.1, y: h * 0.1)
                Rectangle().fill(Color.white.opacity(0.6)).frame(width: 20, height: 1).offset(x: w / 2 - 10, y: h / 2)
                Rectangle().fill(Color.white.opacity(0.6)).frame(width: 1, height: 20).offset(x: w / 2, y: h / 2 - 10)
            }
        }
    }
}

/// vMix-style alerts drawn on the Output monitor only (not in recordings or streams): one at a time.
struct OutputAlerts: View {
    @EnvironmentObject var engine: SwitcherEngine
    var body: some View {
        let text: String? = engine.ftbOn ? "FADE TO BLACK" : (engine.lowVolumeAlert ? "LOW VOLUME" : nil)
        if let t = text {
            VStack {
                Spacer()
                Text(t)
                    .font(.system(size: 16, weight: .heavy))
                    .foregroundColor(.white)
                    .padding(.horizontal, 12).padding(.vertical, 4)
                    .background(Theme.live.opacity(0.85))
                    .clipShape(RoundedRectangle(cornerRadius: 4))
                    .padding(.bottom, 12)
            }
            .allowsHitTesting(false)
        }
    }
}


/// Top bar: broadcast delay of running outputs + the DUMP button.
struct DelayStatusChips: View {
    @EnvironmentObject var engine: SwitcherEngine

    var body: some View {
        ForEach(engine.outputs.filter { $0.running && $0.config.delaySeconds > 0 }) { o in
            DelayChip(output: o)
        }
    }
}

private struct DelayChip: View {
    @ObservedObject var output: OutputChannel
    @ViewState private var confirm = false

    private var delayText: String {
        let ms = output.delayBufferedMs
        let held = ms >= 60_000 ? String(format: "%d:%02d", ms / 60_000, (ms / 1000) % 60) : String(format: "%.1fs", Double(ms) / 1000)
        let disk = output.delayOnDisk ? " · DISK " + OutputConfig.bytesText(output.delayDiskBytes) : ""
        return "DELAY \(output.config.name) · \(held)\(disk)"
    }

    var body: some View {
        HStack(spacing: 4) {
            Text(output.delayDumped ? L("DELAY 해제됨 (실시간)") : delayText)
                .font(.system(size: 11, weight: .bold).monospacedDigit())
                .lineLimit(1).truncationMode(.middle)
                .foregroundColor(.white)
                .padding(.horizontal, 6).padding(.vertical, 1)
                .background(output.delayDumped ? Color.gray : Color.purple.opacity(0.8))
                .clipShape(RoundedRectangle(cornerRadius: Theme.radius, style: .continuous))
            if !output.delayDumped {
                Button(L("DUMP")) { confirm = true }
                    .buttonStyle(.plain)
                    .font(.system(size: 11, weight: .heavy))
                    .foregroundColor(.white)
                    .padding(.horizontal, 8).padding(.vertical, 1)
                    .background(Theme.live)
                    .clipShape(RoundedRectangle(cornerRadius: Theme.radius, style: .continuous))
                    .help(L("지연 중인 구간을 버리고 바로 실시간으로 내보냅니다 (아직 안 나간 장면이 시청자에게 가지 않음)"))
                    .confirmationDialog(L("지연 구간을 버릴까요?"), isPresented: $confirm) {
                        Button(L("DUMP — 지금 실시간으로"), role: .destructive) { output.dumpDelay() }
                    }
            }
        }
    }
}

/// STREAM button while a stream is on but not connected: orange, blinking once a second.
struct BlinkingOrangeLabel: View {
    let text: String
    let mono: Bool

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.5)) { ctx in
            let lit = Int(ctx.date.timeIntervalSinceReferenceDate * 2) % 2 == 0
            HStack(spacing: 6) {
                Text(text)
                Text(L("연결 안 됨")).font(.system(size: 10, weight: .semibold))
            }
            .font(.system(size: 12, weight: .semibold))
            .foregroundColor(lit ? .white : .orange)
            .lineLimit(1)
            .padding(.horizontal, 14)
            .frame(height: 30)
            .background(lit ? Color.orange : Color.orange.opacity(0.18))
        }
    }
}
