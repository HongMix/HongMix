import SwiftUI
import CoreVideo
import AppKit

/// Colours follow vMix: Output (program) = green, Preview = orange, active overlay = light green,
/// red = live record/stream/alarm states.
enum Theme {
    static let program = Color(red: 0.20, green: 0.66, blue: 0.22)
    static let preview = Color(red: 0.93, green: 0.52, blue: 0.10)
    static let overlay = Color(red: 0.42, green: 0.80, blue: 0.36)
    static let live = Color(red: 0.86, green: 0.16, blue: 0.16)
    static let window = Color(red: 0.13, green: 0.14, blue: 0.16)
    static let panel = Color(red: 0.18, green: 0.19, blue: 0.21)
    static let panelDark = Color(red: 0.10, green: 0.11, blue: 0.12)
    static let button = Color(red: 0.27, green: 0.28, blue: 0.31)
    static let buttonText = Color(white: 0.92)
    static let accent = Color(red: 0.20, green: 0.50, blue: 0.85)
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
    @ViewState private var dragStartFraction: Double? = nil

    var body: some View {
        VStack(spacing: 0) {
            TopBar()
            GeometryReader { geo in
                let lay = SwitcherLayout(size: geo.size, mixerVisible: engine.mixerVisible,
                                       strips: 1 + engine.visibleBuses.count + engine.inputs.filter { $0.audioFX.visibleInMixer }.count,
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
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                        if engine.mixerVisible {
                            Rectangle().fill(Color.black).frame(width: 1)
                            AudioMixerPanel(sheet: $sheet)
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
        .background(Theme.window)
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

    let monitorWidth: CGFloat
    let topHeight: CGFloat
    let mixerWidth: CGFloat

    init(size: CGSize, mixerVisible: Bool, strips: Int, topFraction: Double = 0.58) {
        let maxTop = max(200, size.height * CGFloat(topFraction))
        var mw = max(200, (size.width - Self.transitionWidth - Self.gap * 4) / 2)
        var h = mw * 9 / 16 + Self.header + Self.transport
        if h > maxTop {                       // short window: shrink monitors, keep aspect
            h = maxTop
            mw = (h - Self.header - Self.transport) * 16 / 9
        }
        monitorWidth = mw
        topHeight = h
        let want = CGFloat(strips) * Self.stripWidth + 12
        mixerWidth = mixerVisible ? min(max(300, want), size.width * 0.45) : 0
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
            Text(engine.format.name)
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(.secondary)
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
                    .clipShape(RoundedRectangle(cornerRadius: 3))
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
                    .clipShape(RoundedRectangle(cornerRadius: 3))
            }
            if !engine.recordRemaining.isEmpty {
                Text(engine.recordRemaining)
                    .font(.system(size: 11, weight: .semibold).monospacedDigit())
                    .foregroundColor(engine.recordRemaining.contains(L("분")) ? .orange : .secondary)
                    .help(L("녹화 폴더 디스크에 남은 녹화 가능 시간 (현재 비트레이트 기준)"))
            }
            DelayStatusChips()
            EngineStatsChips(stats: engine.stats)
            if engine.ftbOn {
                Text("FTB")
                    .font(.system(size: 11, weight: .heavy))
                    .padding(.horizontal, 6)
                    .background(Theme.live)
                    .clipShape(RoundedRectangle(cornerRadius: 3))
            }
            SettingsLink {
                Image(systemName: "gearshape")
            }
            .buttonStyle(.plain)
            .help(L("설정"))
        }
        .padding(.horizontal, 10)
        .frame(height: 26)
        .background(Theme.panelDark)
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
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Text(title)
                    .font(.system(size: 12, weight: .bold))
                Text(input?.name ?? "")
                    .font(.system(size: 12))
                    .lineLimit(1)
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
            .padding(.horizontal, 8)
            .frame(height: 22)
            .background(color)
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
        .overlay(Rectangle().stroke(color, lineWidth: 2))
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
    @Binding var sheet: SheetRequest?
    @Binding var outputsSheet: OutputKind?
    @ViewState private var showStats = false

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
                    .clipShape(RoundedRectangle(cornerRadius: 3))
            }
            .buttonStyle(.plain)
            .keyboardShortcut("i", modifiers: [.command])
            .help(L("입력 추가 (⌘I)"))

            Spacer().frame(width: 10)
            OutputBarButton(title: "Record", kind: .record, outputsSheet: $outputsSheet)
            OutputBarButton(title: "External", kind: .ndi, alsoKind: .decklink, outputsSheet: $outputsSheet)
            OutputBarButton(title: "Stream", kind: .stream, outputsSheet: $outputsSheet)
            MultiCorderBarButton()
            FullscreenBarButton()
            OverlaySettingsButton()
            RundownButton()
            SchedulerButton()
            CaptionsButton()
            PreflightButton()
            MonitoringButton()
            ScopesButton()
            Button {
                engine.snapshot()
            } label: {
                Image(systemName: "camera.fill")
                    .foregroundColor(.white)
                    .frame(width: 30, height: 30)
                    .background(Theme.button)
                    .clipShape(RoundedRectangle(cornerRadius: 3))
            }
            .buttonStyle(.plain)
            .help("Snapshot (~/Pictures/BraceletMix)")
            Button {
                engine.mixerVisible.toggle()
            } label: {
                Image(systemName: "slider.vertical.3")
                    .foregroundColor(.white)
                    .frame(width: 30, height: 30)
                    .background(engine.mixerVisible ? Theme.accent : Theme.button)
                    .clipShape(RoundedRectangle(cornerRadius: 3))
            }
            .buttonStyle(.plain)
            .help(L("Audio Mixer 보이기/숨기기"))

            Spacer()
            Button {
                showStats = true
            } label: {
                Image(systemName: "chart.bar.xaxis")
                    .foregroundColor(.white)
                    .frame(width: 30, height: 30)
                    .background(Theme.button)
                    .clipShape(RoundedRectangle(cornerRadius: 3))
            }
            .buttonStyle(.plain)
            .help(L("Statistics — 입력별 프레임레이트·드롭, 출력 비트레이트, 렌더 시간"))
            .sheet(isPresented: $showStats) {
                StatisticsSheet().environmentObject(engine)
            }
            VStack(alignment: .trailing, spacing: 1) {
                Text(engine.apiStatus)
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
                    .textSelection(.enabled)
                if !engine.lastMessage.isEmpty {
                    Text(engine.lastMessage)
                        .font(.system(size: 10))
                        .foregroundColor(.orange)
                        .lineLimit(1)
                }
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(Theme.panelDark)
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

    var body: some View {
        let configured = engine.outputs.contains { kinds.contains($0.config.kind) }
        let on = kinds.contains { engine.anyRunning(kind: $0) }
        let error = engine.outputs.contains { kinds.contains($0.config.kind) && $0.running && $0.state == Int32(MC_STATE_ERROR) }
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
                Text(title)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(.white)
                    .padding(.horizontal, 14)
                    .frame(height: 30)
                    .background(on ? (error ? Color.orange : Theme.live) : Theme.button)
            }
            .buttonStyle(.plain)
            Button {
                outputsSheet = kind
            } label: {
                Image(systemName: "gearshape.fill")
                    .font(.system(size: 10))
                    .foregroundColor(.white.opacity(0.8))
                    .frame(width: 22, height: 30)
                    .background(Theme.button.opacity(0.8))
            }
            .buttonStyle(.plain)
            .help(Lf("%@ 설정", "\(title)"))
        }
        .clipShape(RoundedRectangle(cornerRadius: 3))
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

    private func fsButton(_ title: String, _ src: BusSource) -> some View {
        Button((FullscreenOutput.shared.source == src ? "✓ " : "") + title) {
            FullscreenOutput.shared.setSource(src, engine: engine)
        }
    }

    var body: some View {
        let on = FullscreenOutput.shared.isShowing
        HStack(spacing: 0) {
            Button {
                FullscreenOutput.shared.toggle(engine: engine)
                engine.objectWillChange.send()
            } label: {
                Text("Fullscreen")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(.white)
                    .padding(.horizontal, 14)
                    .frame(height: 30)
                    .background(on ? Theme.live : Theme.button)
            }
            .buttonStyle(.plain)
            Menu {
                Section(L("디스플레이")) {
                    Button((FullscreenOutput.shared.displayID == 0 ? "✓ " : "") + L("자동 (스위처가 없는 화면)")) {
                        FullscreenOutput.shared.setDisplay(0, engine: engine)
                    }
                    ForEach(FullscreenOutput.screens(), id: \.id) { s in
                        Button((FullscreenOutput.shared.displayID == s.id ? "✓ " : "") + s.name) {
                            FullscreenOutput.shared.setDisplay(s.id, engine: engine)
                        }
                    }
                }
                Section(L("소스")) {
                    fsButton("Output", .program)
                    fsButton("Output (Clean)", .clean)
                    fsButton("Preview", .preview)
                    fsButton("MultiView", .multiview)
                    ForEach(engine.inputs) { i in
                        fsButton("Input \(engine.number(of: i)) — \(i.name)", .input(i.id))
                    }
                }
            } label: {
                Image(systemName: "display")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .frame(width: 26, height: 30)
            .background(Theme.button.opacity(0.8))
            .help(L("풀스크린 출력 디스플레이 선택"))
        }
        .clipShape(RoundedRectangle(cornerRadius: 3))
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
                    .background(engine.multiCorderOn ? Theme.live : Theme.button)
            }
            .buttonStyle(.plain)
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
        .clipShape(RoundedRectangle(cornerRadius: 3))
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
                    Stepper(Lf("비트레이트: %@ kbps", "\(engine.multiCorderSettings.videoKbps)"),
                            value: $engine.multiCorderSettings.videoKbps, in: 2000...150000, step: 2000)
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

    var body: some View {
        HStack(spacing: 4) {
            Text(output.delayDumped ? L("DELAY 해제됨 (실시간)") :
                    String(format: "DELAY %@ · %.1fs", output.config.name, Double(output.delayBufferedMs) / 1000))
                .font(.system(size: 11, weight: .bold).monospacedDigit())
                .foregroundColor(.white)
                .padding(.horizontal, 6).padding(.vertical, 1)
                .background(output.delayDumped ? Color.gray : Color.purple.opacity(0.8))
                .clipShape(RoundedRectangle(cornerRadius: 3))
            if !output.delayDumped {
                Button(L("DUMP")) { confirm = true }
                    .buttonStyle(.plain)
                    .font(.system(size: 11, weight: .heavy))
                    .foregroundColor(.white)
                    .padding(.horizontal, 8).padding(.vertical, 1)
                    .background(Theme.live)
                    .clipShape(RoundedRectangle(cornerRadius: 3))
                    .help(L("지연 중인 구간을 버리고 바로 실시간으로 내보냅니다 (아직 안 나간 장면이 시청자에게 가지 않음)"))
                    .confirmationDialog(L("지연 구간을 버릴까요?"), isPresented: $confirm) {
                        Button(L("DUMP — 지금 실시간으로"), role: .destructive) { output.dumpDelay() }
                    }
            }
        }
    }
}
