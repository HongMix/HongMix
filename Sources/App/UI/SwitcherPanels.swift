import SwiftUI
import CoreVideo

// MARK: - Shared controls

struct FlatButton: View {
    let title: String
    var active = false
    var activeColor: Color = Theme.live
    var height: CGFloat = 26
    var fontSize: CGFloat = 11
    var weight: Font.Weight = .semibold
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: fontSize, weight: weight))
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .foregroundColor(Theme.buttonText)
                .frame(maxWidth: .infinity, minHeight: height, maxHeight: height)
                .background(active ? activeColor : Theme.button)
                .clipShape(RoundedRectangle(cornerRadius: 3))
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Transition column (Quick Play, Cut, 4 transition buttons, T-bar, FTB)

struct TransitionColumn: View {
    @EnvironmentObject var engine: SwitcherEngine

    var body: some View {
        VStack(spacing: 5) {
            Spacer().frame(height: 22)
            FlatButton(title: "Quick Play", active: engine.transitioning, activeColor: Theme.accent, height: 34,
                       fontSize: 13, weight: .bold) {
                engine.transition(slot: 1)
            }
            .help("Return")
            FlatButton(title: "Cut", height: 34, fontSize: 13, weight: .bold) { engine.cut() }
                .help("Space")

            ForEach(0..<4, id: \.self) { i in
                TransitionSlotRow(index: i)
            }
            HStack(spacing: 3) {
                StingerButton(slot: 1)
                StingerButton(slot: 2)
            }

            // one slim T-bar centred in the column, FTB underneath
            TBar(value: Binding(get: { engine.tbar }, set: { engine.setTBar($0) }))
                .frame(width: 56)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            FlatButton(title: "FTB", active: engine.ftbOn, height: 30, fontSize: 12, weight: .bold) {
                engine.toggleFTB()
            }
            .help("Fade To Black (⇧⌘B)")
        }
        .padding(.bottom, 2)
    }
}

/// Stinger button: click = run, menu = choose media input and cut point.
struct StingerButton: View {
    @EnvironmentObject var engine: SwitcherEngine
    let slot: Int

    var body: some View {
        let cfg = engine.stingers[slot - 1]
        let name = engine.input(withID: cfg.inputID)?.name
        HStack(spacing: 0) {
            FlatButton(title: "Stinger \(slot)", active: engine.stingerActive == slot, activeColor: Theme.accent,
                       height: 24, fontSize: 10) { engine.stinger(slot) }
                .help(name.map { Lf("%@ · 컷 지점 %@ms", "\($0)", "\(cfg.cutPointMs)") } ?? L("미디어 입력을 지정하세요 (▾)"))
            Menu {
                Section(L("미디어 입력")) {
                    ForEach(engine.inputs.filter { $0.kind == .media }) { i in
                        Button((cfg.inputID == i.id ? "✓ " : "") + i.name) { engine.stingers[slot - 1].inputID = i.id }
                    }
                }
                Section(L("컷 지점")) {
                    ForEach([250, 500, 750, 1000, 1500, 2000], id: \.self) { ms in
                        Button((cfg.cutPointMs == ms ? "✓ " : "") + "\(ms) ms") { engine.stingers[slot - 1].cutPointMs = ms }
                    }
                }
            } label: {
                Image(systemName: "chevron.down")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .frame(width: 14, height: 24)
        }
    }
}

/// One of the 4 transition buttons: click = run, menu = choose effect, field = duration (ms).
struct TransitionSlotRow: View {
    @EnvironmentObject var engine: SwitcherEngine
    let index: Int

    var body: some View {
        let slot = engine.transitionSlots[index]
        HStack(spacing: 3) {
            FlatButton(title: slot.type.label, height: 26) { engine.transition(slot: index + 1) }
                .help("⌥\(index + 1)")
            Menu {
                ForEach(TransitionType.allCases) { t in
                    Button(t.label) { engine.transitionSlots[index].type = t }
                }
            } label: {
                Image(systemName: "chevron.down")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .frame(width: 16, height: 26)
            Menu {
                ForEach([250, 500, 750, 1000, 1500, 2000, 3000, 5000], id: \.self) { ms in
                    Button("\(ms) ms") { engine.transitionSlots[index].durationMs = ms }
                }
            } label: {
                Text("\(slot.durationMs)")
                    .font(.system(size: 10).monospacedDigit())
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .frame(width: 40, height: 22)
            .background(Theme.panelDark)
            .clipShape(RoundedRectangle(cornerRadius: 2))
                .help(L("전환 시간 (ms)"))
        }
    }
}

/// Vertical T-bar (0 at bottom … 1 at top). Reaching the top completes the transition.
struct TBar: View {
    @Binding var value: Double
    /// After a completed pull the bar ignores the rest of the drag until release.
    private final class Latch { var on = false }
    private let latch = Latch()

    init(value: Binding<Double>) {
        self._value = value
    }

    var body: some View {
        GeometryReader { geo in
            let h = geo.size.height
            let handleH: CGFloat = 14
            let y = (h - handleH) * CGFloat(1 - value)
            ZStack(alignment: .top) {
                // slim track with the pulled part lit
                Capsule().fill(Color.black.opacity(0.55))
                    .frame(width: 4)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                Capsule().fill(Theme.accent)
                    .frame(width: 4, height: max(0, h - handleH / 2 - y))
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                // quarter ticks
                ForEach(1..<4, id: \.self) { k in
                    Rectangle().fill(Color.white.opacity(0.18))
                        .frame(width: 14, height: 1)
                        .offset(y: handleH / 2 + (h - handleH) * CGFloat(k) / 4)
                }
                // handle
                RoundedRectangle(cornerRadius: 4)
                    .fill(LinearGradient(colors: [Color(white: 0.92), Color(white: 0.62)], startPoint: .top, endPoint: .bottom))
                    .frame(width: 44, height: handleH)
                    .overlay(Rectangle().fill(Color.black.opacity(0.45)).frame(width: 30, height: 1.5))
                    .shadow(color: .black.opacity(0.5), radius: 2, y: 1)
                    .offset(y: y)
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { g in
                        if latch.on { return }
                        let v = Double(max(0, min(1, 1 - (g.location.y - handleH / 2) / max(1, h - handleH))))
                        value = v
                        if v >= 0.999 { latch.on = true }
                    }
                    .onEnded { _ in latch.on = false }
            )
        }
        .frame(minHeight: 56)
        .help(L("T-Bar — 위로 밀면 첫 번째 트랜지션 효과로 수동 전환"))
    }
}

// MARK: - Inputs

/// Red "SIGNAL LOST mm:ss" banner (live inputs that stopped delivering frames).
struct SignalLostBadge: View {
    @ObservedObject var input: InputSource
    var big = false

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { _ in
            let secs = Int(Date().timeIntervalSince(input.lostSince ?? Date()))
            Text(String(format: "SIGNAL LOST %d:%02d", secs / 60, secs % 60))
                .font(.system(size: big ? 13 : 10, weight: .heavy).monospacedDigit())
                .foregroundColor(.white)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Theme.live)
                .clipShape(RoundedRectangle(cornerRadius: 3))
                .padding(4)
                .allowsHitTesting(false)
        }
    }
}

/// Measured format of an input, e.g. "1080p59.94" (refreshed once a second).
struct InputFormatLabel: View {
    @EnvironmentObject var engine: SwitcherEngine
    let slot: VideoSlot
    var size: CGFloat = 9

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { _ in
            let st = slot.stats
            if let label = VideoSlot.formatLabel(st, ntsc: engine.format.fpsDen == 1001) {
                Text(label)
                    .font(.system(size: size, weight: .semibold).monospacedDigit())
                    .foregroundColor(.white.opacity(0.85))
                    .padding(.horizontal, 3)
                    .background(Color.black.opacity(0.3))
                    .clipShape(RoundedRectangle(cornerRadius: 2))
                    .lineLimit(1)
                    .fixedSize()
                    .help(slot.followsProgramRate
                          ? String(format: L("%d×%d · 프로그램 레이트로 출력 (페이지 실제 갱신 %.0f fps)"), st.width, st.height, st.updateFPS)
                          : String(format: L("%d×%d · 측정 %.2f fps · 늦게 도착한 프레임 %d"), st.width, st.height, st.fps, st.late))
            }
        }
    }
}

struct InputGrid: View {
    @EnvironmentObject var engine: SwitcherEngine
    @Binding var sheet: SheetRequest?
    /// 0 small, 1 medium, 2 large (input preview size)
    @AppStorage("inputSize") private var inputSize = 1

    private var widths: (CGFloat, CGFloat) {
        switch inputSize {
        case 0: return (160, 190)
        case 2: return (300, 360)
        default: return (214, 260)
        }
    }

    @AppStorage("inputCategory") private var category = 0      // 0 = all
    @ViewState private var search = ""

    private var shown: [InputSource] {
        engine.inputs.filter { i in
            (category == 0 || i.category == category) &&
            (search.isEmpty || i.name.localizedCaseInsensitiveContains(search) || "\(engine.number(of: i))" == search)
        }
    }

    var body: some View {
        HStack(spacing: 0) {
            CategoryBar(category: $category, search: $search)
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: widths.0, maximum: widths.1), spacing: 6, alignment: .top)],
                          alignment: .leading, spacing: 6) {
                    ForEach(shown) { input in
                        InputBox(input: input, number: engine.number(of: input), sheet: $sheet)
                    }
                }
                .padding(6)
            }
            .overlay(alignment: .top) {
                if category != 0 { Rectangle().fill(InputCategory.color(category)).frame(height: 2) }
            }
        }
        .background(Theme.window)
        .contextMenu {
            Picker(L("입력 크기"), selection: $inputSize) {
                Text(L("작게")).tag(0)
                Text(L("보통")).tag(1)
                Text(L("크게")).tag(2)
            }
            Divider()
            Button(L("모든 입력 접기")) { engine.inputs.forEach { $0.collapsed = true } }
            Button(L("모든 입력 펼치기")) { engine.inputs.forEach { $0.collapsed = false } }
            Button(L("오디오 전용 입력만 접기")) {
                engine.inputs.forEach { if $0.kind == .audio { $0.collapsed = true } }
            }
        }
    }
}

/// vMix input categories: colour tabs to the left of the input bar (+ search).
enum InputCategory {
    static let colors: [Color] = [.gray, Color(red: 0.86, green: 0.2, blue: 0.2), Color(red: 0.2, green: 0.7, blue: 0.3),
                                  Color(red: 0.95, green: 0.55, blue: 0.1), Color(red: 0.6, green: 0.3, blue: 0.85),
                                  Color(red: 0.1, green: 0.75, blue: 0.8), Color(red: 0.2, green: 0.45, blue: 0.95)]
    static let defaultNames = ["", "RED", "GREEN", "ORANGE", "PURPLE", "AQUA", "BLUE"]
    static func color(_ i: Int) -> Color { colors[max(0, min(colors.count - 1, i))] }
    static func name(_ i: Int) -> String {
        let n = UserDefaults.standard.string(forKey: "categoryName\(i)") ?? ""
        return n.isEmpty ? defaultNames[max(0, min(6, i))] : n
    }
}

struct CategoryBar: View {
    @EnvironmentObject var engine: SwitcherEngine
    @Binding var category: Int
    @Binding var search: String
    @ViewState private var searching = false
    @ViewState private var renaming: Int? = nil
    @ViewState private var newName = ""

    var body: some View {
        VStack(spacing: 4) {
            tab(0, label: "ALL")
            ForEach(1...6, id: \.self) { k in
                let n = engine.inputs.filter { $0.category == k }.count
                tab(k, label: n > 0 ? "\(n)" : "")
                    .contextMenu {
                        Button(L("이름 바꾸기…")) { newName = InputCategory.name(k); renaming = k }
                    }
            }
            Spacer()
            Button { searching.toggle(); if !searching { search = "" } } label: {
                Image(systemName: "magnifyingglass").font(.system(size: 11, weight: .bold))
                    .frame(width: 26, height: 24)
                    .background(search.isEmpty ? Theme.button : Theme.accent)
                    .clipShape(RoundedRectangle(cornerRadius: 3))
            }
            .buttonStyle(.plain)
            .help(L("입력 이름/번호로 찾기"))
            .popover(isPresented: $searching, arrowEdge: .trailing) {
                TextField(L("입력 이름 또는 번호"), text: $search)
                    .textFieldStyle(.roundedBorder).frame(width: 200).padding(8)
            }
        }
        .padding(.vertical, 6).padding(.horizontal, 3)
        .frame(width: 34)
        .background(Theme.panelDark)
        .alert(L("카테고리 이름"), isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("", text: $newName)
            Button(L("저장")) { if let k = renaming { UserDefaults.standard.set(newName, forKey: "categoryName\(k)") }; renaming = nil }
            Button(L("취소"), role: .cancel) { renaming = nil }
        }
    }

    private func tab(_ k: Int, label: String) -> some View {
        Button { category = k } label: {
            Text(label)
                .font(.system(size: 9, weight: .bold))
                .foregroundColor(.white)
                .frame(width: 26, height: 24)
                .background(InputCategory.color(k).opacity(category == k ? 1 : 0.55))
                .overlay(RoundedRectangle(cornerRadius: 3).stroke(Color.white, lineWidth: category == k ? 2 : 0))
                .clipShape(RoundedRectangle(cornerRadius: 3))
        }
        .buttonStyle(.plain)
        .help(k == 0 ? L("모든 입력") : Lf("%@ 카테고리 (우클릭: 이름 바꾸기 · 입력 우클릭 메뉴에서 지정)", InputCategory.name(k)))
    }
}

/// Catches a right-click on the view it covers (vMix: right-click an input title to collapse it).
struct RightClickCatcher: NSViewRepresentable {
    let action: () -> Void
    func makeNSView(context: Context) -> RightClickView {
        let v = RightClickView()
        v.action = action
        return v
    }
    func updateNSView(_ v: RightClickView, context: Context) { v.action = action }

    final class RightClickView: NSView {
        var action: (() -> Void)?
        override func hitTest(_ point: NSPoint) -> NSView? {
            // only claim right-clicks; everything else falls through to SwiftUI
            guard let e = NSApp.currentEvent, e.type == .rightMouseDown || e.type == .rightMouseUp else { return nil }
            return super.hitTest(point)
        }
        override func rightMouseDown(with event: NSEvent) { action?() }
    }
}

struct InputBox: View {
    @EnvironmentObject var engine: SwitcherEngine
    @ObservedObject var input: InputSource
    let number: Int
    @Binding var sheet: SheetRequest?

    private var isProgram: Bool { engine.programID == input.id }
    private var isPreview: Bool { engine.previewID == input.id }
    private var overlayChannels: [Int] { engine.overlayChannels(of: input.id) }

    private var headerColor: Color {
        if isProgram { return Theme.program }
        if isPreview { return Theme.preview }
        if !overlayChannels.isEmpty { return Theme.overlay }
        return Theme.panel
    }

    private var stateColor: Color {
        switch input.state {
        case Int32(MC_STATE_RUNNING): return .green
        case Int32(MC_STATE_CONNECTING): return .yellow
        case Int32(MC_STATE_ERROR): return .red
        default: return .gray
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            // Title bar: number + name, settings / close
            HStack(spacing: 5) {
                Text("\(number)")
                    .font(.system(size: 12, weight: .heavy))
                Text(input.name)
                    .font(.system(size: 11, weight: .semibold))
                    .lineLimit(1)
                Spacer(minLength: 2)
                if !input.collapsed { InputFormatLabel(slot: input.video) }
                Circle().fill(stateColor).frame(width: 7, height: 7)
                    .help(input.status)
                Menu {
                    if input.kind == .title {
                        Button(L("타이틀 편집…")) { sheet = SheetRequest(kind: input.kind, editing: input, mode: .title) }
                    }
                    Button(input.collapsed ? L("펼치기") : L("접기 (제목만 표시)")) { input.collapsed.toggle() }
                    Button(L("속성 (위치·색보정·오디오·재생)…")) {
                        sheet = SheetRequest(kind: input.kind, editing: input, mode: .properties)
                    }
                    Button(L("소스 설정…")) { sheet = SheetRequest(kind: input.kind, editing: input) }
                    Button(L("스냅샷 저장")) { engine.snapshot(input: input) }
                    if input.supportsTransport { Button(L("처음부터 (Restart)")) { input.restart() } }
                    Divider()
                    Button(L("앞으로 이동")) { engine.moveInput(from: number - 1, to: number - 2) }
                    Button(L("뒤로 이동")) { engine.moveInput(from: number - 1, to: number) }
                    Menu(L("카테고리")) {
                        ForEach(0...6, id: \.self) { k in
                            Button((input.category == k ? "✓ " : "   ") + (k == 0 ? L("없음") : InputCategory.name(k))) { input.category = k }
                        }
                    }
                    Divider()
                    Button(L("입력 닫기"), role: .destructive) { engine.requestRemove(input) }
                } label: {
                    Image(systemName: "gearshape.fill").font(.system(size: 10))
                        .foregroundColor(input.category > 0 ? InputCategory.color(input.category) : .primary)
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .frame(width: 16)
            }
            .foregroundColor(.white)
            .padding(.horizontal, 6)
            .frame(height: 20)
            .background(headerColor)
            .contentShape(Rectangle())
            .onTapGesture(count: 2) { sheet = SheetRequest(kind: input.kind, editing: input, mode: .properties) }
            .onTapGesture { if input.collapsed { engine.setPreview(input.id) } }
            .overlay(RightClickCatcher { withAnimation(.easeInOut(duration: 0.15)) { input.collapsed.toggle() } })
            .help(L("더블클릭: Input Settings · 우클릭: 접기/펼치기"))

            if !input.collapsed {
                expandedBody
            }
        }
        .background(Theme.panel)
        .clipShape(RoundedRectangle(cornerRadius: 3))
        .overlay(RoundedRectangle(cornerRadius: 3).stroke(dropTarget ? Color.white : Color.clear, lineWidth: 2))
        .overlay(Rectangle().stroke(headerColor == Theme.panel ? Color.black.opacity(0.5) : headerColor, lineWidth: 2))
        .draggable(input.id.uuidString) {
            Text("\(number). \(input.name)").padding(6).background(Theme.panel)
        }
        .dropDestination(for: String.self) { items, _ in
            // vMix: drag an input onto another to change the order
            guard let s = items.first, let id = UUID(uuidString: s),
                  let from = engine.inputs.firstIndex(where: { $0.id == id }) else { return false }
            engine.moveInput(from: from, to: number - 1)
            return true
        } isTargeted: { dropTarget = $0 }
    }

    @ViewState private var dropTarget = false

    @ViewBuilder private var expandedBody: some View {
        VStack(spacing: 0) {
            // Thumbnail: click = preview, double-click = cut to output
            ZStack(alignment: .bottomLeading) {
                MonitorView(fps: 15) { input.currentFrame() }
                    .aspectRatio(16.0 / 9.0, contentMode: .fit)
                    .background(Color.black)
                Color.clear
                    .contentShape(Rectangle())
                    .onTapGesture { engine.setPreview(input.id) }
                if input.signalLost {
                    SignalLostBadge(input: input)
                } else if input.state == Int32(MC_STATE_ERROR) || input.state == Int32(MC_STATE_CONNECTING) {
                    Text(input.status)
                        .font(.system(size: 9))
                        .lineLimit(1)
                        .padding(3)
                        .background(Color.black.opacity(0.7))
                        .foregroundColor(input.state == Int32(MC_STATE_ERROR) ? .red : .yellow)
                        .allowsHitTesting(false)
                }
            }

            // Row 1: Close / Quick Play / Cut / Loop
            HStack(spacing: 3) {
                Button {
                    engine.requestRemove(input)
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundColor(Theme.buttonText)
                        .frame(width: 22, height: 22)
                        .background(Theme.button)
                        .clipShape(RoundedRectangle(cornerRadius: 3))
                }
                .buttonStyle(.plain)
                .help(L("입력 닫기"))
                FlatButton(title: "Quick Play", height: 22, fontSize: 10) { engine.quickPlay(input.id) }
                FlatButton(title: "Cut", height: 22, fontSize: 10) { engine.cutDirect(input.id) }
                FlatButton(title: "Loop", active: input.looping, activeColor: Theme.accent, height: 22, fontSize: 10) {
                    input.looping.toggle()
                }
                .disabled(!input.supportsTransport)
                .opacity(input.supportsTransport ? 1 : 0.4)
            }
            .padding(.horizontal, 4)
            .padding(.top, 4)

            // Row 2: overlay 1-4, play/pause, audio
            HStack(spacing: 3) {
                ForEach(1...4, id: \.self) { ch in
                    FlatButton(title: "\(ch)", active: overlayChannels.contains(ch), activeColor: Theme.overlay,
                               height: 22, fontSize: 10, weight: .bold) {
                        engine.toggleOverlay(ch, input.id)
                    }
                    .help("Overlay \(ch)")
                }
                if input.supportsTransport {
                    Button {
                        input.playing.toggle()
                    } label: {
                        Image(systemName: input.playing ? "pause.fill" : "play.fill")
                            .font(.system(size: 9))
                            .foregroundColor(Theme.buttonText)
                            .frame(width: 24, height: 22)
                            .background(Theme.button)
                            .clipShape(RoundedRectangle(cornerRadius: 3))
                    }
                    .buttonStyle(.plain)
                }
                Button {
                    input.muted.toggle()
                } label: {
                    Image(systemName: input.muted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                        .font(.system(size: 9))
                        .foregroundColor(input.muted ? .white : Theme.buttonText)
                        .frame(width: 26, height: 22)
                        .background(input.muted ? Theme.live : Theme.button)
                        .clipShape(RoundedRectangle(cornerRadius: 3))
                }
                .buttonStyle(.plain)
                .help("Audio On/Off")
            }
            .padding(4)
        }
    }
}

// MARK: - Audio mixer (vertical channel strips)

struct AudioMixerPanel: View {
    @EnvironmentObject var engine: SwitcherEngine
    @Binding var sheet: SheetRequest?

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Text("Audio Mixer")
                    .font(.system(size: 11, weight: .bold))
                LoudnessBadge()
                Spacer()
                BusManagerButton()
                Image(systemName: "headphones").font(.system(size: 10))
                Slider(value: $engine.headphonesVolume, in: 0...1)
                    .controlSize(.mini)
                    .frame(width: 70)
                    .help(L("헤드폰 볼륨"))
                Toggle(isOn: $engine.monitorOn) {
                    Text(L("모니터")).font(.system(size: 10))
                }
                .toggleStyle(.button)
                .controlSize(.small)
                .help(L("헤드폰 모니터 (기본 출력 장치). Solo가 켜져 있으면 Solo 신호를 듣습니다."))
            }
            .padding(.horizontal, 8)
            .frame(height: 24)
            .background(Theme.panelDark)

            ScrollView(.horizontal) {
                HStack(alignment: .top, spacing: 2) {
                    ChannelStrip(title: "Master", volume: $engine.masterVolume, muted: $engine.masterMuted,
                                 meter: { engine.audioMixer.master }, highlight: Theme.accent) {
                        Color.clear
                    }
                    ForEach(engine.visibleBuses, id: \.self) { b in
                        BusChannelStrip(index: b)
                    }
                    AddBusColumn()
                    Rectangle().fill(Color.black).frame(width: 2)
                    ForEach(engine.inputs.filter { $0.audioFX.visibleInMixer }) { input in
                        InputChannelStrip(input: input, number: engine.number(of: input)) {
                            sheet = SheetRequest(kind: input.kind, editing: input, mode: .properties, tab: 4)
                        }
                    }
                }
                .padding(4)
                .frame(maxHeight: .infinity, alignment: .top)
            }
            .frame(maxHeight: .infinity)
        }
        .background(Theme.panel)
    }
}

struct BusChannelStrip: View {
    @EnvironmentObject var engine: SwitcherEngine
    let index: Int

    var body: some View {
        let mixer = engine.audioMixer
        let b = index
        ChannelStrip(title: "Bus " + AudioBus.all[b], volume: $engine.busSettings[b].volume,
                     muted: $engine.busSettings[b].muted, meter: { mixer.busMeter(b) }, highlight: nil) {
            HStack(spacing: 2) {
                FlatButton(title: "M", active: engine.busSettings[b].sendToMaster, activeColor: Theme.accent,
                           height: 20, fontSize: 9, weight: .bold) { engine.busSettings[b].sendToMaster.toggle() }
                    .help(L("Master로 보내기 (BusXSendToMaster)"))
                FlatButton(title: "S", active: engine.busSettings[b].solo, activeColor: .yellow, height: 20,
                           fontSize: 10, weight: .bold) { engine.busSettings[b].solo.toggle() }
                    .help(L("Solo (헤드폰)"))
            }
        }
        .contextMenu {
            Button(Lf("Bus %@ 숨기기", "\(AudioBus.all[b])")) { engine.busSettings[b].enabled = false }
                .disabled(!engine.busSettings[b].enabled)
            Text(L("입력·출력이 이 버스를 쓰는 동안은 계속 표시됩니다")).font(.caption)
        }
    }
}

/// "+" column after the bus strips: enable another bus (vMix: right-click A/B to enable C–G).
struct AddBusColumn: View {
    @EnvironmentObject var engine: SwitcherEngine

    var body: some View {
        let hidden = (1..<AudioMixer.busCount).filter { !engine.busInUse($0) }
        if !hidden.isEmpty {
            Menu {
                ForEach(hidden, id: \.self) { b in
                    Button(Lf("Bus %@ 추가", "\(AudioBus.all[b])")) { engine.busSettings[b].enabled = true }
                }
            } label: {
                VStack(spacing: 4) {
                    Image(systemName: "plus").font(.system(size: 12, weight: .bold))
                    Text("Bus").font(.system(size: 9, weight: .semibold))
                }
                .foregroundColor(.secondary)
                .frame(width: 30, height: 60)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .frame(width: 30)
            .help(L("버스 A~G 추가 — 쓰는 버스만 믹서에 표시됩니다 (vMix 방식)"))
        }
    }
}

/// vMix Audio Bus Manager: inputs × buses grid in one window.
struct BusManagerButton: View {
    @EnvironmentObject var engine: SwitcherEngine
    @ViewState private var show = false

    var body: some View {
        Button { show = true } label: {
            Image(systemName: "square.grid.3x3").font(.system(size: 10))
        }
        .buttonStyle(.plain)
        .help(L("오디오 버스 매니저 — 입력별 버스 라우팅을 한 화면에서"))
        .sheet(isPresented: $show) { BusManagerSheet().environmentObject(engine) }
    }
}

struct BusManagerSheet: View {
    @EnvironmentObject var engine: SwitcherEngine
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(L("오디오 버스 매니저")).font(.headline)
            Text(L("칸을 눌러 입력을 버스에 보내거나 뺍니다. 버스를 쓰기 시작하면 믹서에 자동으로 나타납니다."))
                .font(.caption).foregroundColor(.secondary)
            ScrollView {
                Grid(alignment: .center, horizontalSpacing: 6, verticalSpacing: 4) {
                    GridRow {
                        Text(L("입력")).font(.caption.bold()).frame(width: 180, alignment: .leading)
                        ForEach(AudioBus.all, id: \.self) { b in
                            Text(b == "M" ? "Master" : b).font(.caption.bold()).frame(width: 46)
                        }
                    }
                    Divider()
                    ForEach(engine.inputs.filter { $0.audioFX.visibleInMixer }) { i in
                        BusManagerRow(input: i, number: engine.number(of: i))
                    }
                    Divider()
                    GridRow {
                        Text(L("믹서에 항상 표시")).font(.caption).frame(width: 180, alignment: .leading)
                        Text("—").frame(width: 46).foregroundColor(.secondary)
                        ForEach(1..<AudioMixer.busCount, id: \.self) { b in
                            Toggle("", isOn: $engine.busSettings[b].enabled).labelsHidden().toggleStyle(.checkbox)
                                .frame(width: 46)
                        }
                    }
                }
            }
            HStack {
                Spacer()
                Button(L("닫기")) { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding()
        .frame(width: 660, height: 460)
    }
}

private struct BusManagerRow: View {
    @EnvironmentObject var engine: SwitcherEngine
    @ObservedObject var input: InputSource
    let number: Int

    var body: some View {
        GridRow {
            Text("\(number). \(input.name)").lineLimit(1).frame(width: 180, alignment: .leading)
            ForEach(AudioBus.all, id: \.self) { b in
                let on = input.onBus(b)
                Button {
                    input.setBus(b, !on)
                    if !on, let i = AudioBus.index(b), i > 0 { engine.busSettings[i].enabled = true }
                } label: {
                    Text(on ? "●" : "")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundColor(.white)
                        .frame(width: 46, height: 22)
                        .background(on ? Theme.accent : Theme.button)
                        .clipShape(RoundedRectangle(cornerRadius: 3))
                }
                .buttonStyle(.plain)
            }
        }
    }
}

struct InputChannelStrip: View {
    @EnvironmentObject var engine: SwitcherEngine
    @ObservedObject var input: InputSource
    let number: Int
    let openSettings: () -> Void

    var body: some View {
        let mixer = engine.audioMixer
        let id = input.id
        let hl: Color? = engine.programID == id ? Theme.program : (engine.previewID == id ? Theme.preview : nil)
        ChannelStrip(title: "\(number) \(input.name)", volume: $input.volume, muted: $input.muted,
                     meter: { mixer.meter(for: id) }, highlight: hl) {
            VStack(spacing: 2) {
                HStack(spacing: 2) {
                    busButton("M")
                    ForEach(engine.visibleBuses.prefix(2), id: \.self) { b in busButton(AudioBus.all[b]) }
                    if engine.visibleBuses.isEmpty { Color.clear.frame(maxWidth: .infinity, maxHeight: 20) }
                }
                HStack(spacing: 2) {
                    FlatButton(title: "S", active: input.solo, activeColor: .yellow, height: 20, fontSize: 10,
                               weight: .bold) { input.solo.toggle() }
                        .help(L("Solo (헤드폰)"))
                    Button {
                        input.audioFollowsVideo.toggle()
                    } label: {
                        Image(systemName: "arrow.right")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundColor(.white)
                            .frame(maxWidth: .infinity, minHeight: 20, maxHeight: 20)
                            .background(input.audioFollowsVideo ? Theme.program : Theme.button)
                            .clipShape(RoundedRectangle(cornerRadius: 3))
                    }
                    .buttonStyle(.plain)
                    .help(L("Follow: 비디오가 Output에 있을 때만 오디오 On (Audio Auto)"))
                    Menu {
                        ForEach(["A", "B", "C", "D", "E", "F", "G"], id: \.self) { bus in
                            Button((input.onBus(bus) ? "✓ " : "   ") + "Bus " + bus) {
                                let on = !input.onBus(bus)
                                input.setBus(bus, on)
                                if on, let i = AudioBus.index(bus) { engine.busSettings[i].enabled = true }
                            }
                        }
                        Divider()
                        Button("Audio Settings…", action: openSettings)
                    } label: {
                        Image(systemName: "gearshape.fill").font(.system(size: 9))
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .frame(maxWidth: .infinity, minHeight: 20, maxHeight: 20)
                    .background(extraBuses.isEmpty ? Theme.button : Theme.accent)
                    .clipShape(RoundedRectangle(cornerRadius: 3))
                    .help(extraBuses.isEmpty ? L("버스 A~G 보내기, Audio Settings") : Lf("버스 %@ · Audio Settings", "\(extraBuses)"))
                }
            }
        }
    }

    private func busButton(_ bus: String) -> some View {
        FlatButton(title: bus, active: input.onBus(bus), activeColor: Theme.accent, height: 20, fontSize: 10,
                   weight: .bold) { input.setBus(bus, !input.onBus(bus)) }
            .help(bus == "M" ? "Master" : "Bus \(bus)")
    }

    /// buses this input uses that have no inline button
    private var extraBuses: String {
        let inline = Set(engine.visibleBuses.prefix(2).map { AudioBus.all[$0] })
        return ["A", "B", "C", "D", "E", "F", "G"].filter { input.onBus($0) && !inline.contains($0) }.joined()
    }
}

struct ChannelStrip<Accessory: View>: View {
    let title: String
    @Binding var volume: Float
    @Binding var muted: Bool
    let meter: () -> (Float, Float)
    var highlight: Color?
    let accessory: Accessory

    init(title: String, volume: Binding<Float>, muted: Binding<Bool>, meter: @escaping () -> (Float, Float),
         highlight: Color?, @ViewBuilder accessory: () -> Accessory) {
        self.title = title
        self._volume = volume
        self._muted = muted
        self.meter = meter
        self.highlight = highlight
        self.accessory = accessory()
    }

    var body: some View {
        VStack(spacing: 4) {
            Text(title)
                .font(.system(size: 10, weight: .semibold))
                .lineLimit(1)
                .frame(width: 62)
                .padding(.vertical, 2)
                .background(highlight ?? Theme.panelDark)
                .clipShape(RoundedRectangle(cornerRadius: 2))
            HStack(spacing: 3) {
                LayerMeter(meter: meter)
                    .frame(width: 11)
                VerticalFader(value: $volume)
                    .frame(width: 26)
            }
            .frame(minHeight: 70, maxHeight: .infinity)
            Text(volume <= 0.0001 ? "-inf" : String(format: "%.1f", 20 * log10(Double(volume * volume))))
                .font(.system(size: 9).monospacedDigit())
                .foregroundColor(.secondary)
            Button {
                muted.toggle()
            } label: {
                Image(systemName: muted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                    .font(.system(size: 10))
                    .frame(width: 58, height: 20)
                    .foregroundColor(.white)
                    .background(muted ? Theme.live : Theme.button)
                    .clipShape(RoundedRectangle(cornerRadius: 3))
            }
            .buttonStyle(.plain)
            .help("Mute")
            accessory
                .frame(width: 58, height: 44, alignment: .top)   // same height on every strip → faders line up
        }
        .padding(4)
        .frame(width: 70)
        .frame(maxHeight: .infinity)
        .background(Theme.panelDark.opacity(0.6))
    }
}

/// Vertical fader 0...1 (unity at top), drag or scroll to change, double-click resets to 0 dB.
struct VerticalFader: View {
    @Binding var value: Float

    var body: some View {
        GeometryReader { geo in
            let h = geo.size.height
            let capH: CGFloat = 14
            let y = (h - capH) * CGFloat(1 - value)
            ZStack(alignment: .top) {
                Rectangle()
                    .fill(Color.black)
                    .frame(width: 4)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                RoundedRectangle(cornerRadius: 2)
                    .fill(LinearGradient(colors: [Color(white: 0.85), Color(white: 0.5)], startPoint: .top, endPoint: .bottom))
                    .frame(height: capH)
                    .overlay(Rectangle().fill(Color.black.opacity(0.7)).frame(height: 1))
                    .offset(y: y)
            }
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 1).onChanged { g in
                let v = 1 - (g.location.y - capH / 2) / max(1, h - capH)
                value = Float(max(0, min(1, v)))
            })
            .simultaneousGesture(TapGesture(count: 2).onEnded { value = 1 })
        }
    }
}

struct VerticalMeter: View {
    let level: Float

    var body: some View {
        GeometryReader { geo in
            let db = level > 0 ? 20 * log10(Double(level)) : -90
            let frac = max(0, min(1, (db + 60) / 60))
            ZStack(alignment: .bottom) {
                Rectangle().fill(Color.black)
                Rectangle()
                    .fill(LinearGradient(stops: [
                        .init(color: .green, location: 0),
                        .init(color: .green, location: 0.7),
                        .init(color: .yellow, location: 0.85),
                        .init(color: .red, location: 1),
                    ], startPoint: .bottom, endPoint: .top))
                    .mask(alignment: .bottom) {
                        Rectangle().frame(height: geo.size.height * CGFloat(frac))
                    }
            }
        }
    }
}
