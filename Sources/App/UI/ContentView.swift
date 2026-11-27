import SwiftUI
import CoreVideo
import AppKit

/// Colours follow vMix conventions for Preview/Program. Overlay channels have their own
/// control-surface colors; these are UI indicators and never tint the broadcast picture.
/// Settings › General › "Hardware look": raised keys, aluminium relief, hardware mixer strips and the
/// designed transition column. Off = the clean flat look HongMix had before. Cached like AppSkin.
enum AppLook {
    static let key = "appLookHardware"
    private static var cached: Bool?
    static var hardware: Bool {
        if let c = cached { return c }
        let v = UserDefaults.standard.object(forKey: key) as? Bool ?? true
        cached = v
        return v
    }
    static func sync(_ v: Bool) { if cached != v { cached = v } }

    /// Hardware look option: brushed-metal grain on the window backgrounds (off by default).
    static let textureKey = "appLookMetalTexture"
    private static var cachedTexture: Bool?
    static var metalTexture: Bool {
        if let c = cachedTexture { return c }
        let v = UserDefaults.standard.bool(forKey: textureKey)
        cachedTexture = v
        return v
    }
    static func syncTexture(_ v: Bool) { if cachedTexture != v { cachedTexture = v } }
}

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
    // Hardware look on Black & White: a touch of grey (anodised panel) instead of near-black; the clean look keeps its values.
    static var window: Color {
        switch AppSkin.current {
        case .mono: return Color(white: AppLook.hardware ? 0.095 : 0.043)
        case .classic: return Color(red: 0.13, green: 0.14, blue: 0.16)
        }
    }
    static var panel: Color {
        switch AppSkin.current {
        case .mono: return Color(white: AppLook.hardware ? 0.135 : 0.082)
        case .classic: return Color(red: 0.18, green: 0.19, blue: 0.21)
        }
    }
    static var panelDark: Color {
        switch AppSkin.current {
        case .mono: return Color(white: AppLook.hardware ? 0.105 : 0.06)
        case .classic: return Color(red: 0.10, green: 0.11, blue: 0.12)
        }
    }
    static var button: Color {
        switch AppSkin.current {
        case .mono: return Color(white: AppLook.hardware ? 0.17 : 0.135)
        case .classic: return Color(red: 0.27, green: 0.28, blue: 0.31)
        }
    }
    static let buttonText = Color(white: 0.92)
    /// Selected / active state. Monochrome uses a light grey instead of blue.
    static var accent: Color { AppSkin.isMono ? Color(white: 0.36) : Color(red: 0.20, green: 0.50, blue: 0.85) }
    /// Monochrome primary action (CUT): white fill, black text.
    static let primaryFill = Color(white: 0.96)
    /// HongMix orange (the logo): AUTO, the selected transition, the T-bar.
    static let brand = Color(red: 1.0, green: 0.48, blue: 0.18)
    /// Quick Play blue.
    static let quickPlay = Color(red: 0.17, green: 0.20, blue: 0.42)
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

/// Very subtle brushed-aluminium relief on top of a button's own colour: a faint sheen at the top, a
/// slightly darker bottom and a fine light top edge — so the flat buttons read as physical keys.
struct HMBevel: ViewModifier {
    var cornerRadius: CGFloat

    @ViewBuilder func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        if !AppLook.hardware {
            content
        } else {
        content
            .overlay(shape.fill(LinearGradient(stops: [
                .init(color: .white.opacity(0.11), location: 0),
                .init(color: .white.opacity(0.03), location: 0.48),
                .init(color: .black.opacity(0.02), location: 0.52),
                .init(color: .black.opacity(0.13), location: 1),
            ], startPoint: .top, endPoint: .bottom)).allowsHitTesting(false))
            .overlay(shape.strokeBorder(LinearGradient(colors: [.white.opacity(0.18), .white.opacity(0.04), .black.opacity(0.28)],
                                                       startPoint: .top, endPoint: .bottom), lineWidth: 0.75)
                .allowsHitTesting(false))
            .hwDrop(shape, opacity: 0.55, y: 1.2)   // raised key
        }
    }
}

/// Raised-key drop shadow for the hardware look, drawn as two plain offset fills under the shape.
/// SwiftUI's `.shadow` is rendered off-screen on every redraw: ~100 of them (tile keys, mixer strips)
/// kept the GPU so busy in 2.3.7 that Program frames were dropped on every cut, fade and at launch.
struct HWDrop<S: Shape>: ViewModifier {
    let shape: S
    var opacity: Double
    var y: CGFloat
    @ViewBuilder func body(content: Content) -> some View {
        content.background(ZStack {
            shape.fill(Color.black.opacity(opacity * 0.45)).offset(y: y + 0.5)
            shape.fill(Color.black.opacity(opacity * 0.75)).offset(y: y * 0.6)
        }.allowsHitTesting(false))
    }
}

extension View {
    func hwDrop<S: Shape>(_ shape: S, opacity: Double, y: CGFloat) -> some View { modifier(HWDrop(shape: shape, opacity: opacity, y: y)) }
    func hmBevel(cornerRadius: CGFloat) -> some View { modifier(HMBevel(cornerRadius: cornerRadius)) }

    func hmGlass(cornerRadius: CGFloat = 14, fallback: Color = Theme.panelDark) -> some View {
        modifier(HMGlass(cornerRadius: cornerRadius, fallback: fallback))
    }
}

struct SheetRequest: Identifiable {
    enum Mode { case source, properties, title, captions }
    let id = UUID()
    var kind: InputKind
    var editing: InputSource?
    var mode: Mode = .source
    var tab: Int = 0
}

/// The sheet a SheetRequest opens (main window and the detached audio mixer window).
struct SheetRequestView: View {
    @EnvironmentObject var engine: SwitcherEngine
    let req: SheetRequest
    @Binding var sheet: SheetRequest?

    var body: some View {
        switch req.mode {
        case .source:
            InputEditorSheet(kind: req.kind, editing: req.editing)
        case .properties:
            if let input = req.editing {
                InputPropertiesSheet(input: input, initialTab: req.tab, onChangeSource: {
                    sheet = SheetRequest(kind: input.kind, editing: input)
                })
            }
        case .title:
            if let t = req.editing as? TitleInput { TitleEditorSheet(title: t) }
        case .captions:
            CaptionsSheet(captions: engine.captions)
        }
    }
}

/// Window "Audio Mixer": the mixer on its own (e.g. on a second screen). While it is open the docked
/// mixer in the main window is hidden; closing the window docks it again.
struct AudioMixerWindow: View {
    /// Open mixer windows (a language/skin/look change rebuilds the window: new onAppear can come first)
    static var open = 0
    @EnvironmentObject var engine: SwitcherEngine
    @ViewState private var sheet: SheetRequest? = nil
    @AppStorage("audioInputStripsCollapsed") private var collapsed = false

    var body: some View {
        AudioMixerPanel(sheet: $sheet, inputStripsCollapsed: $collapsed)
            .frame(minWidth: 320, minHeight: 360)
            .background(BrushedMetal(base: Theme.window))
            .onAppear { AudioMixerWindow.open += 1; engine.mixerVisible = false }
            .onDisappear {
                AudioMixerWindow.open -= 1
                if AudioMixerWindow.open <= 0 { AudioMixerWindow.open = 0; engine.mixerVisible = true }
            }
            .sheet(item: $sheet) { req in SheetRequestView(req: req, sheet: $sheet).environmentObject(engine) }
    }
}

/// Main window, laid out like a classic software switcher:
///   [ Preview | Transitions | Output ]
///   [ Inputs ......................  | Audio mixer ]
///   [ Add Input | Record | External | Stream | Fullscreen ......... status ]
/// Whether the audio mixer is docked in the main window (see SwitcherEngine.mixerVisible).
final class MixerDock: ObservableObject {
    static let shared = MixerDock()
    @Published var visible = true
}

/// SwiftUI builds a window's view tree the first time it opens: 0.1–0.3 s on the main thread, during which
/// monitors and buttons freeze. Once built, it opens in ~15–60 ms. Shortly after launch, build the heavy
/// secondary windows once, invisibly (alpha 0, closed right away), so the operator never pays the first open.
/// (The Audio Mixer pops out of the main window: its dock state lives in MixerDock, so the main window only
/// re-lays out once while it is built here, at launch.)
enum WindowPrewarm {
    private static var done = false
    static func run(_ open: @escaping (String) -> Void) {
        guard !done, !UserDefaults.standard.bool(forKey: "disableWindowPrewarm") else { return }
        done = true
        let windows = [("replay", "Replay"), ("talentcue", "Talent Cue"), ("multiview", "MultiView"), ("scopes", "Scopes"),
                       ("audiomixer", "Audio Mixer")]
        for (k, (id, title)) in windows.enumerated() {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.0 + Double(k) * 0.5) {
                // already open (restored by macOS or opened by the operator): leave it alone
                if NSApp.windows.contains(where: { $0.isVisible && $0.title == title }) { return }
                open(id)
                guard let w = NSApp.windows.first(where: { $0.title == title }) else { return }
                w.alphaValue = 0                      // before the first display: never seen
                DispatchQueue.main.async {
                    w.performClose(nil)
                    w.alphaValue = 1
                }
            }
        }
    }
}

struct ContentView: View {
    @ObservedObject private var mixerDock = MixerDock.shared
    @EnvironmentObject var engine: SwitcherEngine
    @Environment(\.openWindow) private var openWindow
    @ViewState private var sheet: SheetRequest? = nil
    @ViewState private var outputsSheet: OutputKind? = nil
    /// vMix: drag the dividing line to give the inputs more (or fewer) rows
    @AppStorage("monitorFraction") private var monitorFraction = 0.58
    @AppStorage("audioInputStripsCollapsed") private var audioInputStripsCollapsed = false
    @AppStorage("inputDockLeft") private var inputDockLeft = false
    @AppStorage(AppSkin.defaultsKey) private var appSkin = AppSkin.mono.rawValue
    @ViewState private var dragStartFraction: Double? = nil

    /// API OpenWindow (HongMix extension): lets the control API open a window by id.
    static var apiOpenWindow: ((String) -> Void)?
    var body: some View {
        VStack(spacing: 0) {
            TopBar()
            ControlFocusBanner()
            SystemHealthBanner()
            GeometryReader { geo in
                let activeAudioInputs = engine.inputs.filter { $0.hasAudio && $0.audioFX.visibleInMixer }
                let lay = SwitcherLayout(size: geo.size, mixerVisible: mixerDock.visible,
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
                        if mixerDock.visible {
                            Rectangle().fill(Color.black).frame(width: 1)
                            AudioMixerPanel(sheet: $sheet, inputStripsCollapsed: $audioInputStripsCollapsed,
                                            onPopOut: { openWindow(id: "audiomixer") })
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
            BrushedMetal(base: Theme.window)
        )
        .onAppear {
            let open = openWindow
            ContentView.apiOpenWindow = { open(id: $0) }
            WindowPrewarm.run { open(id: $0) }
        }
        .sheet(item: $sheet) { req in SheetRequestView(req: req, sheet: $sheet).environmentObject(engine) }
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
    static var stripWidth: CGFloat { AppLook.hardware ? 92 : 72 }
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
                        Text(L("실행 취소"))
                    }
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(.white)
                    .padding(.horizontal, 8).frame(height: 20)
                    .background(Theme.button)
                    .clipShape(RoundedRectangle(cornerRadius: Theme.radius, style: .continuous))
                    .hmBevel(cornerRadius: Theme.radius)
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
            .help(L("설정 열기"))
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
            SystemLoadChips()
            SystemLagChip()
        }
    }
}

/// Whole-Mac CPU · GPU · RAM next to the render figures (SystemLoad).
struct SystemLoadChips: View {
    @ObservedObject var load = SystemLoad.shared

    var body: some View {
        let gb = 1_073_741_824.0
        HStack(spacing: 14) {
            StatusChip(label: "CPU", value: String(format: "%.0f%%", load.cpu), warn: load.cpu > 80)
                .help(L("맥 전체 CPU 사용률"))
            if let g = load.gpu {
                StatusChip(label: "GPU", value: String(format: "%.0f%%", g), warn: g > 85)
                    .help(L("맥 전체 GPU 사용률"))
            }
            StatusChip(label: "RAM", value: String(format: "%.1f/%.0f GB", load.ramUsed / gb, load.ramTotal / gb),
                       warn: load.ramUsed / max(1, load.ramTotal) > 0.9)
                .help(Lf("맥 전체 사용 메모리 · HongMix %@ GB", String(format: "%.1f", load.appRAM / gb)))
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
        .clipShape(RoundedRectangle(cornerRadius: mono ? (AppLook.hardware ? 4 : 10) : 0, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: mono ? (AppLook.hardware ? 4 : 10) : 0, style: .continuous).stroke(color, lineWidth: mono ? 1.5 : 2))   // tally at full strength: it is the on-air cue
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
    @ObservedObject private var mixerDock = MixerDock.shared
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
                    .hmBevel(cornerRadius: Theme.radius)
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
            ToolBarWindowButton(title: "Talent Cue", symbol: "timer", windowID: "talentcue",
                                help: L("Talent Cue — 발표자 화면: 메시지 · 타이머 · 사회자 원격"))
            ToolBarWindowButton(title: "MultiView", symbol: "rectangle.split.3x3", windowID: "multiview",
                                help: L("MultiView — 레이아웃 · 칸마다 화면 선택 · 여러 개 만들어 모니터에 보내기"))
            Button {
                mixerDock.visible.toggle()
            } label: {
                Image(systemName: "slider.vertical.3")
                    .foregroundColor(.white)
                    .frame(width: 30, height: 30)
                    .background(mixerDock.visible ? Theme.accent : Theme.button)
                    .clipShape(RoundedRectangle(cornerRadius: Theme.radius, style: .continuous))
                    .hmBevel(cornerRadius: Theme.radius)
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
                    .hmBevel(cornerRadius: Theme.radius)
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
                    .hmBevel(cornerRadius: Theme.radius)
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
    @ObservedObject private var displayOutput = FullscreenOutput.shared   // display output state (not via engine refresh)
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
                    let extra = DisplayMap.shared.showingCount + OutputWindows.shared.openCount
                    if extra > 0 {
                        Text("+\(extra)")
                            .foregroundColor(Color(white: 0.85))
                            .help(Lf("모니터별 출력 %@개 켜짐", "\(extra)"))
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
            .hmBevel(cornerRadius: mono ? 15 : Theme.radius)
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
                    .hmBevel(cornerRadius: Theme.radius)
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
