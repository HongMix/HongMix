import SwiftUI
import CoreVideo

// MARK: - Shared controls

struct FlatButton: View {
    enum Style { case normal, primary, outline }
    let title: String
    var active = false
    var activeColor: Color = Theme.live
    var height: CGFloat = 26
    var fontSize: CGFloat = 11
    var weight: Font.Weight = .semibold
    /// Monochrome only: primary = white fill (CUT), outline = white border (transition).
    var style: Style = .normal
    let action: () -> Void

    var body: some View {
        let mono = AppSkin.isMono
        let primary = mono && style == .primary && !active
        let outline = mono && style == .outline && !active
        Button(action: action) {
            Text(title)
                .font(.system(size: fontSize, weight: weight))
                .tracking(mono && style != .normal ? 0.5 : 0)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .foregroundColor(primary ? .black : Theme.buttonText)
                .frame(maxWidth: .infinity, minHeight: height, maxHeight: height)
                .background(active ? activeColor : (primary ? Theme.primaryFill : (outline ? Color.clear : Theme.button)))
                .overlay(RoundedRectangle(cornerRadius: Theme.radius, style: .continuous)
                    .stroke(outline ? Color.white.opacity(0.6) : .clear, lineWidth: 1.5))
                .clipShape(RoundedRectangle(cornerRadius: Theme.radius, style: .continuous))
        }
        .buttonStyle(.plain)
    }
}

/// Numbered overlay control. The channel color remains visible while idle and brightens
/// when the channel is on air, so operators can distinguish simultaneous layers quickly.
private struct OverlayChannelButton: View {
    let channel: Int
    let active: Bool
    var height: CGFloat = 20
    var fontSize: CGFloat = 9
    let action: () -> Void

    private var color: Color { Theme.overlayChannel(channel) }

    var body: some View {
        Button(action: action) {
            ZStack(alignment: .topTrailing) {
                Text("\(channel)")
                    .font(.system(size: fontSize, weight: .heavy).monospacedDigit())
                    .foregroundColor(.white)
                    .frame(maxWidth: .infinity, minHeight: height, maxHeight: height)
                if active {
                    Circle().fill(Color.white.opacity(0.95))
                        .frame(width: 4, height: 4)
                        .padding(2)
                }
            }
            .background(active ? color : color.opacity(0.24))
            .clipShape(RoundedRectangle(cornerRadius: Theme.radius, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: Theme.radius, style: .continuous)
                .stroke(color.opacity(active ? 1 : 0.65), lineWidth: active ? 1.2 : 0.8))
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
                       fontSize: 13, weight: .bold, style: .outline) {
                engine.transition(slot: 1)
            }
            .help("Return")
            FlatButton(title: AppSkin.isMono ? "CUT" : "Cut", height: 34, fontSize: 13, weight: .heavy, style: .primary) { engine.cut() }
                .help("Space")

            ForEach(0..<4, id: \.self) { i in
                TransitionSlotRow(index: i)
            }
            StingerButton(slot: 1)

            // vMix-style overlay bank: each channel recalls its saved input, independent of Preview.
            VStack(spacing: 3) {
                Text(L("OVERLAY 1–8"))
                    .font(.system(size: 8, weight: .bold))
                    .foregroundColor(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                ForEach(0..<2, id: \.self) { row in
                    HStack(spacing: 3) {
                        ForEach(1...4, id: \.self) { col in
                            let channel = row * 4 + col
                            let active = engine.overlayOn[channel - 1]
                            let savedInput = engine.input(withID: engine.overlayIDs[channel - 1])
                            OverlayChannelButton(channel: channel, active: active, height: 20, fontSize: 9) {
                                engine.toggleOverlayChannel(channel)
                            }
                            .disabled(savedInput == nil)
                            .help(savedInput.map { Lf("Overlay %@ · 저장된 입력: %@", "\(channel)", $0.name) }
                                  ?? Lf("Overlay %@ · 입력 타일에서 소스를 먼저 지정하세요", "\(channel)"))
                        }
                    }
                }
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
                .clipShape(RoundedRectangle(cornerRadius: Theme.radius, style: .continuous))
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
            // A paused file (e.g. waiting in Preview) delivers no frames, so the measured rate is 0;
            // fall back to the file's declared rate so the format is still shown.
            let shown: VideoSlot.Stats = {
                var s = st
                if s.fps <= 0.5, slot.nominalFPS > 0, s.height > 0 { s.fps = slot.nominalFPS }
                return s
            }()
            if let label = VideoSlot.formatLabel(shown, ntsc: engine.format.fpsDen == 1001) {
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
    @AppStorage("compactInputTiles") private var compactInputTiles = false
    @AppStorage("inputDockLeft") private var inputDockLeft = false
    @ViewState private var fileDropTarget = false

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

    private var foldedInputs: [InputSource] { shown.filter(\.folded) }
    private var expandedInputs: [InputSource] { shown.filter { !$0.folded } }

    var body: some View {
        HStack(spacing: 0) {
            CategoryBar(category: $category, search: $search)
            VStack(spacing: 0) {
                HStack(spacing: 6) {
                    Text(L("입력"))
                        .font(.system(size: 10, weight: .bold)).foregroundColor(.secondary)
                    Text("\(shown.count)").font(.system(size: 10, weight: .medium).monospacedDigit()).foregroundColor(.secondary)
                    Spacer()
                    Button {
                        compactInputTiles.toggle()
                        engine.inputs.forEach { $0.collapsed = compactInputTiles }
                    } label: {
                        Label(compactInputTiles ? L("타일 펼치기") : L("컴팩트 타일"),
                              systemImage: compactInputTiles ? "rectangle.expand.vertical" : "rectangle.compress.vertical")
                            .font(.system(size: 10, weight: .semibold))
                    }
                    .buttonStyle(.borderless)
                    .help(L("vMix 스타일의 입력 타일 보기 전환. 접은 상태에서도 미리보기, 컷, 오버레이, 오디오 버튼을 표시합니다."))
                    Button { withAnimation(.easeInOut(duration: 0.18)) { inputDockLeft.toggle() } } label: {
                        Image(systemName: inputDockLeft ? "rectangle.rightthird.inset.filled" : "sidebar.left")
                            .font(.system(size: 10, weight: .semibold))
                    }
                    .buttonStyle(.borderless)
                    .help(inputDockLeft ? L("입력 패널을 아래 전체 폭으로 펼치기") : L("입력 패널을 왼쪽 세로 도크로 배치"))
                }
                .padding(.horizontal, 8).frame(height: 26)
                Divider().overlay(Color.black.opacity(0.35))
                ScrollView {
                    HStack(alignment: .top, spacing: 6) {
                        if !foldedInputs.isEmpty {
                            VStack(spacing: 5) {
                                Image(systemName: "rectangle.compress.vertical")
                                    .font(.system(size: 10, weight: .bold))
                                    .foregroundColor(.secondary)
                                    .overlay(alignment: .topTrailing) {
                                        Text("\(foldedInputs.count)")
                                            .font(.system(size: 7, weight: .bold).monospacedDigit())
                                            .foregroundColor(.white)
                                            .offset(x: 7, y: -4)
                                    }
                                    .frame(height: 18)
                                    .help(L("접힌 입력"))

                                ForEach(foldedInputs) { input in
                                    FoldedInputRow(input: input, number: engine.number(of: input), sheet: $sheet)
                                }
                                Spacer(minLength: 0)
                            }
                            .frame(width: 54)
                            .padding(.vertical, 5)
                            .background(Theme.panel.opacity(0.72))
                            .clipShape(RoundedRectangle(cornerRadius: 4))
                        }

                        LazyVGrid(columns: inputDockLeft
                                  ? [GridItem(.flexible(minimum: 180, maximum: 260), spacing: 6, alignment: .top)]
                                  : [GridItem(.adaptive(minimum: widths.0, maximum: widths.1), spacing: 6, alignment: .top)],
                                  alignment: .leading, spacing: 6) {
                            ForEach(expandedInputs) { input in
                                InputBox(input: input, number: engine.number(of: input), sheet: $sheet, compactDock: inputDockLeft)
                            }
                        }
                    }
                    .padding(6)
                    .frame(maxWidth: .infinity, minHeight: 120, alignment: .topLeading)
                }
                // Finder → empty input area: new inputs from the dropped files (⌥ = several videos as one List)
                .onDrop(of: [.fileURL], isTargeted: Binding(get: { fileDropTarget }, set: { fileDropTarget = $0 })) { providers in
                    FileDrop.add(providers, engine: engine)
                }
                .overlay {
                    if fileDropTarget {
                        RoundedRectangle(cornerRadius: 6).stroke(Color.white.opacity(0.85), style: StrokeStyle(lineWidth: 2, dash: [6, 4]))
                            .overlay(Text(L("놓으면 새 입력으로 추가 · ⌥ 여러 영상 = List · ⌘ 타일 위 = 파일 교체")).font(.caption)
                                .padding(6).background(Color.black.opacity(0.7)).clipShape(RoundedRectangle(cornerRadius: 4)))
                            .padding(4)
                            .allowsHitTesting(false)
                    }
                }
            }
            .overlay(alignment: .top) {
                if category != 0 { Rectangle().fill(InputCategory.color(category)).frame(height: 2) }
            }
        }
        .frame(width: inputDockLeft ? 290 : nil)
        .background(Theme.window)
        .contextMenu {
            Picker(L("입력 크기"), selection: $inputSize) {
                Text(L("작게")).tag(0)
                Text(L("보통")).tag(1)
                Text(L("크게")).tag(2)
            }
            Divider()
            Button(L("모든 입력 접기")) { engine.inputs.forEach { $0.folded = true } }
            Button(L("모든 입력 펼치기")) { engine.inputs.forEach { $0.folded = false } }
            Button(L("컴팩트 타일 모드 전환")) {
                compactInputTiles.toggle()
                engine.inputs.forEach { $0.collapsed = compactInputTiles }
            }
            Button(L("오디오 전용 입력만 접기")) {
                engine.inputs.forEach { if $0.kind == .audio { $0.collapsed = true } }
            }
        }
    }
}

/// A folded source becomes a narrow vertical tab in the input area's left rail.
private struct FoldedInputRow: View {
    @EnvironmentObject var engine: SwitcherEngine
    @ObservedObject var input: InputSource
    let number: Int
    @Binding var sheet: SheetRequest?

    private var stateColor: Color {
        switch input.state {
        case Int32(MC_STATE_RUNNING): return .green
        case Int32(MC_STATE_CONNECTING): return .yellow
        case Int32(MC_STATE_ERROR): return .red
        default: return .gray
        }
    }

    private var selectedColor: Color {
        if engine.programID == input.id { return Theme.program }
        if engine.previewID == input.id { return Theme.preview }
        if let channel = engine.overlayChannels(of: input.id).first { return Theme.overlayChannel(channel) }
        return Theme.button
    }

    private var overlayChannels: [Int] { engine.overlayChannels(of: input.id) }

    var body: some View {
        VStack(spacing: 5) {
            Text("\(number)")
                .font(.system(size: 12, weight: .heavy).monospacedDigit())
                .foregroundColor(.white)
            Circle().fill(stateColor).frame(width: 7, height: 7)
            Text(input.name)
                .font(.system(size: 8, weight: .semibold))
                .lineLimit(3).multilineTextAlignment(.center)
                .foregroundColor(.white.opacity(0.88))
                .frame(maxHeight: .infinity)
            if !overlayChannels.isEmpty {
                VStack(spacing: 2) {
                    ForEach(0..<2, id: \.self) { row in
                        HStack(spacing: 2) {
                            ForEach(0..<4, id: \.self) { col in
                                let index = row * 4 + col
                                if overlayChannels.indices.contains(index) {
                                    let channel = overlayChannels[index]
                                    Text("\(channel)")
                                        .font(.system(size: 7, weight: .heavy).monospacedDigit())
                                        .foregroundColor(.white)
                                        .frame(width: 8, height: 9)
                                        .background(Theme.overlayChannel(channel))
                                        .clipShape(RoundedRectangle(cornerRadius: 2))
                                }
                            }
                        }
                    }
                }
            }
            Button {
                withAnimation(.easeInOut(duration: 0.15)) { input.folded = false }
            } label: {
                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundColor(.white.opacity(0.9))
                    .frame(width: 26, height: 20)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(L("입력 타일 펼치기"))
        }
        .padding(.vertical, 6)
        // minHeight (not a fixed height): number + dot + name + overlay chips + chevron need more
        // than 76 pt once overlay chips appear; a fixed frame clipped the chevron/number.
        .frame(width: 46)
        .frame(minHeight: 76)
        .background(selectedColor.opacity(0.88))
        .clipShape(RoundedRectangle(cornerRadius: 4))
        .contentShape(Rectangle())
        .onTapGesture { engine.setPreview(input.id) }
        .contextMenu {
            Button(L("미리보기로 선택")) { engine.setPreview(input.id) }
            Button(L("펼치기")) { withAnimation(.easeInOut(duration: 0.15)) { input.folded = false } }
            Button(L("속성…")) { sheet = SheetRequest(kind: input.kind, editing: input, mode: .properties) }
            Button(L("입력 설정…")) { sheet = SheetRequest(kind: input.kind, editing: input) }
        }
        .draggable(input.id.uuidString) { Text("\(number). \(input.name)").padding(6).background(Theme.panel) }
        .onDrop(of: FileDrop.dropTypes, isTargeted: nil) { providers in
            // a file from Finder replaces this input's source; a dragged tile reorders
            FileDrop.dropOnTile(providers, input: input, number: number, engine: engine)
        }
        .help(L("번호는 원래 입력 번호를 유지 · 클릭: Preview 선택 · 화살표: 타일 펼치기 · 우클릭: 추가 작업"))
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
                    .clipShape(RoundedRectangle(cornerRadius: Theme.radius, style: .continuous))
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
                .overlay(RoundedRectangle(cornerRadius: Theme.radius, style: .continuous).stroke(Color.white, lineWidth: category == k ? 2 : 0))
                .clipShape(RoundedRectangle(cornerRadius: Theme.radius, style: .continuous))
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
    var compactDock = false

    private var isProgram: Bool { engine.programID == input.id }
    private var isPreview: Bool { engine.previewID == input.id }
    private var overlayChannels: [Int] { engine.overlayChannels(of: input.id) }

    private var headerColor: Color {
        if isProgram { return Theme.program }
        if isPreview { return Theme.preview }
        if let channel = overlayChannels.first { return Theme.overlayChannel(channel) }
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

    @ViewBuilder private var listNowPlaying: some View {
        if let media = input as? FFmpegInput, media.isList,
           media.playlist.indices.contains(media.playlistIndex) {
            HStack(spacing: 5) {
                Image(systemName: media.playing ? "play.fill" : "pause.fill")
                    .foregroundColor(media.playing ? Theme.program : .secondary)
                Text("\(media.playlistIndex + 1)/\(media.playlist.count)")
                    .fontWeight(.semibold).monospacedDigit().foregroundColor(.secondary)
                Text((media.playlist[media.playlistIndex] as NSString).lastPathComponent)
                    .lineLimit(1).truncationMode(.middle)
                    .foregroundColor(Theme.buttonText)
                Spacer(minLength: 0)
                Button { media.previousItem() } label: { Image(systemName: "backward.end.fill") }
                    .help(L("이전 리스트 항목"))
                Button { media.nextItem() } label: { Image(systemName: "forward.end.fill") }
                    .help(L("다음 리스트 항목"))
            }
            .font(.system(size: 9))
            .buttonStyle(.borderless)
            .padding(.horizontal, 6)
            .frame(height: 20)
            .background(Theme.panel.opacity(0.9))
            .help(L("현재 재생 중인 리스트 항목 · 속성 › List에서 전체 순서 관리"))
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            // Title bar: number + name, settings / close
            HStack(spacing: 4) {
                Text("\(number)")
                    .font(.system(size: 12, weight: .heavy))
                Text(input.name)
                    .font(.system(size: 12, weight: .semibold))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .help(input.name)
                fillKeyBadge
                if !(input is ReplayInput) { ReplaySlotChip(input: input) }
                Circle().fill(stateColor).frame(width: 7, height: 7)
                    .help(input.status)
                Menu {
                    if input.kind == .title {
                        Button(L("타이틀 편집…")) { sheet = SheetRequest(kind: input.kind, editing: input, mode: .title) }
                    }
                    Button(input.folded ? L("펼치기") : L("접기 (제목만 표시)")) { input.folded.toggle() }
                    Button(input.collapsed ? L("타일 펼치기") : L("컴팩트 타일")) { input.collapsed.toggle() }
                    Button(L("속성 (위치·색보정·오디오·재생)…")) {
                        sheet = SheetRequest(kind: input.kind, editing: input, mode: .properties)
                    }
                    Button(L("소스 설정…")) { sheet = SheetRequest(kind: input.kind, editing: input) }
                    Button(L("스냅샷 저장")) { engine.snapshot(input: input) }
                    if input.supportsTransport { Button(L("처음부터 (Restart)")) { input.restart() } }
                    if let media = input as? FFmpegInput, media.kind == .media, !media.config.url.isEmpty {
                        Button(media.isSoftwareDecoded ? L("최적화 미디어 만들기 (ProRes) — 권장: CPU 디코딩 중")
                                                       : L("최적화 미디어 만들기 (ProRes)")) {
                            let path = media.config.url
                            let name = (path as NSString).lastPathComponent
                            engine.lastMessage = Lf("ProRes 변환 시작: %@", name)
                            OptimizedMedia.makeProRes(from: path, progress: { p in
                                engine.lastMessage = Lf("ProRes 변환 중 %@%% · %@", "\(Int(p * 100))", name)
                            }, done: { result in
                                switch result {
                                case .success(let out):
                                    media.replaceFile(with: out)
                                    engine.lastMessage = Lf("✓ 최적화 미디어로 교체: %@", (out as NSString).lastPathComponent)
                                case .failure(let err):
                                    engine.lastMessage = Lf("ProRes 변환 실패: %@", err.localizedDescription)
                                }
                            })
                        }
                    }
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
                Button {
                    withAnimation(.easeInOut(duration: 0.15)) { input.folded.toggle() }
                } label: {
                    Image(systemName: input.folded ? "chevron.down" : "chevron.up")
                        .font(.system(size: 9, weight: .bold))
                        .frame(width: 18, height: 18)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(input.folded ? L("펼치기") : L("접기 (제목만 표시)"))
            }
            .foregroundColor(.white)
            .padding(.horizontal, 6)
            .frame(height: 20)
            .background(AppSkin.isMono ? Theme.panelDark : headerColor)
            .contentShape(Rectangle())
            .onTapGesture(count: 2) { sheet = SheetRequest(kind: input.kind, editing: input, mode: .properties) }
            .onTapGesture { if input.collapsed || input.folded { engine.setPreview(input.id) } }
            .overlay(RightClickCatcher { withAnimation(.easeInOut(duration: 0.15)) { input.folded.toggle() } })
            .help(L("더블클릭: Input Settings · 우클릭: 접기/펼치기"))

            if input.folded {
                EmptyView()
            } else if !input.collapsed && !compactDock {
                expandedBody
            } else {
                compactBody
            }
        }
        .background(Theme.panel)
        .clipShape(RoundedRectangle(cornerRadius: Theme.radius, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Theme.radius, style: .continuous).stroke(dropTarget ? Color.white : Color.clear, lineWidth: 2))
        .overlay(RoundedRectangle(cornerRadius: Theme.radius, style: .continuous)
            .stroke(headerColor == Theme.panel ? (AppSkin.isMono ? Theme.hairline : Color.black.opacity(0.5)) : headerColor, lineWidth: 2))
        .draggable(input.id.uuidString) {
            Text("\(number). \(input.name)").padding(6).background(Theme.panel)
        }
        .onDrop(of: FileDrop.dropTypes, isTargeted: Binding(get: { dropTarget }, set: { dropTarget = $0 })) { providers in
            // vMix: drag an input onto another to change the order · a file from Finder replaces the source
            FileDrop.dropOnTile(providers, input: input, number: number, engine: engine)
        }
    }

    @ViewState private var dropTarget = false

    @ViewBuilder private var fillKeyBadge: some View {
        if input.alphaKey.mode == "key",
           let key = engine.inputs.first(where: { $0.id.uuidString == input.alphaKey.keyInputID }) {
            Text("F+K \(engine.number(of: key))")
                .font(.system(size: 8, weight: .bold)).padding(.horizontal, 4).frame(height: 14)
                .background(Color.purple.opacity(0.9), in: RoundedRectangle(cornerRadius: Theme.radius, style: .continuous))
                .help(Lf("Fill 입력 · Key = 입력 %@", "\(engine.number(of: key))"))
        } else if let fill = engine.inputs.first(where: {
            $0.id != input.id && $0.alphaKey.mode == "key" && $0.alphaKey.keyInputID == input.id.uuidString
        }) {
            Text("KEY→\(engine.number(of: fill))")
                .font(.system(size: 8, weight: .bold)).padding(.horizontal, 4).frame(height: 14)
                .background(Color.blue.opacity(0.9), in: RoundedRectangle(cornerRadius: Theme.radius, style: .continuous))
                .help(Lf("입력 %@의 Key 신호", "\(engine.number(of: fill))"))
        }
    }

    /// vMix-style compact input tile: retain source identity and useful live controls while
    /// removing the large settings-heavy presentation from the input grid.
    /// Explicitly constrain the monitor viewport to 16:9. LazyVGrid equalizes row heights,
    /// so an unconstrained monitor can otherwise inherit a taller neighbor's height and
    /// make the picture look vertically offset or undersized in only some tiles.
    private var inputMonitor: some View {
        ZStack(alignment: .center) {
            MonitorView(fps: 6, onActiveChange: { input.setInputTileVisible($0) }) { input.monitorFrame() }
                .background(Color.black)
            Color.clear.contentShape(Rectangle())
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
        .frame(maxWidth: .infinity)
        .aspectRatio(16.0 / 9.0, contentMode: .fit)
        .fixedSize(horizontal: false, vertical: true)
    }

    // One tile layout for every size and input kind (compact or expanded), so buttons never
    // appear or disappear depending on tile width. Transport buttons stay in place and dim when
    // the input has no transport (camera, title, NDI …).
    private var compactBody: some View { tileBody }
    private var expandedBody: some View { tileBody }

    private func tileIcon(_ symbol: String, enabled: Bool = true, active: Bool = false,
                          help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 9, weight: .bold))
                .foregroundColor(active ? .white : Theme.buttonText)
                .frame(width: 24, height: 22)
                .background(active ? Theme.live : Theme.button)
                .clipShape(RoundedRectangle(cornerRadius: Theme.radius, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.35)
        .help(help)
    }

    private var tileBody: some View {
        let transport = input.supportsTransport
        return VStack(spacing: 3) {
            inputMonitor.help(L("클릭: Preview"))

            listNowPlaying

            // Row 1: Close · Restart · Play/Pause · Cut · Loop  (Quick Play removed)
            HStack(spacing: 3) {
                tileIcon("xmark", help: L("입력 닫기")) { engine.requestRemove(input) }
                tileIcon("backward.end.fill", enabled: transport, help: L("처음부터 (Restart)")) { input.restart() }
                tileIcon(input.playing ? "pause.fill" : "play.fill", enabled: transport,
                         help: input.playing ? L("일시정지") : L("재생")) { input.playing.toggle() }
                FlatButton(title: L("Cut"), height: 22, fontSize: 10) { engine.cutDirect(input.id) }
                FlatButton(title: L("Loop"), active: input.looping, activeColor: Theme.accent, height: 22, fontSize: 10) {
                    input.looping.toggle()
                }
                .disabled(!transport)
                .opacity(transport ? 1 : 0.35)
            }
            .padding(.horizontal, 3)

            // Row 2: Audio (left) · Overlay 1–8
            HStack(spacing: 3) {
                Button { input.muted.toggle() } label: {
                    Image(systemName: input.muted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(input.muted ? .white : Theme.buttonText)
                        .frame(width: 24, height: 34)
                        .background(input.muted ? Theme.live : Theme.button)
                        .clipShape(RoundedRectangle(cornerRadius: Theme.radius, style: .continuous))
                }
                .buttonStyle(.plain)
                .help(input.muted ? L("오디오 켜기") : L("오디오 끄기"))
                VStack(spacing: 2) {
                    ForEach(0..<2, id: \.self) { row in
                        HStack(spacing: 2) {
                            ForEach(1...4, id: \.self) { col in
                                let channel = row * 4 + col
                                let assigned = overlayChannels.contains(channel)
                                let onAir = engine.overlayOn[channel - 1] && engine.overlayIDs[channel - 1] == input.id
                                OverlayChannelButton(channel: channel, active: onAir || assigned, height: 16, fontSize: 8) {
                                    engine.toggleOverlay(channel, input.id)
                                }
                                .help(Lf("Overlay %@ · %@", "\(channel)", onAir ? L("출력 중 · 클릭해 종료") : assigned ? L("지정됨 · 클릭해 출력") : L("이 입력을 지정하고 출력")))
                            }
                        }
                    }
                }
            }
            .padding(.horizontal, 3).padding(.bottom, 3)
        }
    }
}

// MARK: - Audio mixer (vertical channel strips)

struct AudioMixerPanel: View {
    @EnvironmentObject var engine: SwitcherEngine
    @Binding var sheet: SheetRequest?
    @Binding var inputStripsCollapsed: Bool
    @ViewState private var showAudioOutputs = false
    @AppStorage("audioMetersCollapsed") private var metersCollapsed = false

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                HStack(spacing: 6) {
                    Image(systemName: "slider.horizontal.3")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(Theme.accent)
                    Text(inputStripsCollapsed ? "Audio" : "Audio Mixer")
                        .font(.system(size: 11, weight: .bold))
                        .lineLimit(1)
                        .fixedSize(horizontal: true, vertical: false)
                }
                if !inputStripsCollapsed {
                    Slider(value: $engine.headphonesVolume, in: 0...1)
                        .controlSize(.mini)
                        .frame(width: 54)
                        .help(L("헤드폰 볼륨"))
                }
                Spacer(minLength: 4)
                Button { withAnimation(.easeInOut(duration: 0.15)) { metersCollapsed.toggle() } } label: {
                    Image(systemName: metersCollapsed ? "waveform" : "waveform.path")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(metersCollapsed ? .secondary : Theme.accent)
                        .frame(width: 26, height: 24)
                        .background(metersCollapsed ? Color.clear : Theme.button.opacity(0.7), in: RoundedRectangle(cornerRadius: 5))
                }
                .buttonStyle(.plain)
                .help(metersCollapsed ? L("오디오 레벨 미터 펼치기") : L("오디오 레벨 미터 접기"))
                BusManagerButton()
                // Keep output routing reachable even when the mixer is collapsed or narrow.
                Button { showAudioOutputs = true } label: {
                    Image(systemName: "cable.connector.horizontal")
                        .font(.system(size: 11, weight: .semibold))
                        .frame(width: 26, height: 24)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .background(Theme.button.opacity(0.55), in: RoundedRectangle(cornerRadius: 5))
                .help(L("Audio Outputs — Master, Headphones, Bus A–G의 CoreAudio 장치와 채널 지정"))
                Toggle(isOn: $engine.monitorOn) {
                    Image(systemName: engine.monitorOn ? "headphones" : "headphones")
                        .font(.system(size: 11, weight: .semibold))
                        .frame(width: 27, height: 24)
                }
                .toggleStyle(.button)
                .controlSize(.small)
                .help(L("헤드폰 모니터. Solo가 켜져 있으면 Solo 신호를 듣습니다."))
                Button { withAnimation(.easeInOut(duration: 0.18)) { inputStripsCollapsed.toggle() } } label: {
                    Image(systemName: inputStripsCollapsed ? "chevron.left" : "chevron.right")
                        .font(.system(size: 10, weight: .bold))
                        .frame(width: 24, height: 24)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(inputStripsCollapsed ? L("오디오 입력 채널 펼치기") : L("오디오 입력 채널 접기"))
            }
            .padding(.horizontal, 8)
            .frame(height: 30)
            .background(LinearGradient(colors: [Theme.panelDark, Theme.panel], startPoint: .top, endPoint: .bottom))
            .overlay(alignment: .bottom) { Rectangle().fill(Color.white.opacity(0.06)).frame(height: 1) }
            .sheet(isPresented: $showAudioOutputs) { AudioOutputsSheet().environmentObject(engine) }

            ScrollView(.horizontal, showsIndicators: true) {
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
                    if !inputStripsCollapsed {
                        ForEach(engine.inputs.filter { $0.hasAudio && $0.audioFX.visibleInMixer }) { input in
                            InputChannelStrip(input: input, number: engine.number(of: input)) {
                                sheet = SheetRequest(kind: input.kind, editing: input, mode: .properties, tab: 4)
                            }
                        }
                    }
                }
                .padding(4)
                .frame(maxHeight: .infinity, alignment: .top)
            }
            .scrollIndicators(.visible)   // always show: the last strips can be off-screen
            .frame(maxHeight: .infinity)
        }
        .background(Theme.panel)
    }
}

struct AudioOutputsSheet: View {
    @EnvironmentObject var engine: SwitcherEngine
    @Environment(\.dismiss) private var dismiss
    private let devices = CoreAudioOutputs.devices()

    private var names: [String] { ["Master", "Bus A", "Bus B", "Bus C", "Bus D", "Bus E", "Bus F", "Bus G", "Headphones"] }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(L("Audio Outputs")).font(.title2.bold())
            Text(L("각 믹스를 실제 CoreAudio 장치와 스테레오 채널 쌍으로 보냅니다. Headphones는 Solo가 켜지면 Solo 믹스를 출력합니다."))
                .font(.caption).foregroundColor(.secondary)
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 8) {
                GridRow {
                    Text(L("믹스")).bold(); Text(L("사용")).bold(); Text(L("출력 장치")).bold(); Text(L("채널")).bold()
                }.font(.caption)
                ForEach(0..<9, id: \.self) { index in
                    routeRow(index)
                }
            }
            Divider()
            Text(L("같은 다채널 인터페이스에서 Master=1–2, Bus A=3–4처럼 지정할 수 있습니다. 동일 장치·채널을 여러 믹스에 중복 지정하면 신호가 합산될 수 있습니다."))
                .font(.caption).foregroundColor(.orange)
            HStack { Spacer(); Button(L("닫기")) { dismiss() }.keyboardShortcut(.defaultAction) }
        }
        .padding(18).frame(width: 720)
    }

    @ViewBuilder private func routeRow(_ index: Int) -> some View {
        let route = engine.audioOutputRoutes[index]
        let selected = devices.first { $0.uid == route.deviceUID }
        GridRow {
            Text(names[index]).font(.system(size: 12, weight: .semibold)).frame(width: 90, alignment: .leading)
            Toggle("", isOn: index == 8 ? $engine.monitorOn : binding(index, \.enabled)).labelsHidden()
            Picker("", selection: binding(index, \.deviceUID)) {
                Text(L("시스템 기본 출력")).tag("")
                ForEach(devices) { Text($0.name).tag($0.uid) }
            }.labelsHidden().frame(width: 360)
            Picker("", selection: binding(index, \.firstChannel)) {
                let channels = max(2, selected?.channels ?? 2)
                ForEach(Array(stride(from: 0, to: channels, by: 2)), id: \.self) { c in
                    Text("\(c + 1)–\(min(c + 2, channels))").tag(c)
                }
            }.labelsHidden().frame(width: 90).disabled(route.deviceUID.isEmpty)
        }
    }

    private func binding<T>(_ index: Int, _ keyPath: WritableKeyPath<AudioOutputRoute, T>) -> Binding<T> {
        Binding(get: { engine.audioOutputRoutes[index][keyPath: keyPath] }, set: { value in
            var routes = engine.audioOutputRoutes
            routes[index][keyPath: keyPath] = value
            engine.audioOutputRoutes = routes
        })
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
                        .clipShape(RoundedRectangle(cornerRadius: Theme.radius, style: .continuous))
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
        let onAir = engine.programID == id || !engine.overlayChannels(of: id).isEmpty
        let state: InputAudioState = input.muted ? .mute : (!input.audioFollowsVideo ? .on : (onAir ? .onAir : .auto))
        ChannelStrip(title: "\(number) \(input.name)", volume: $input.volume, muted: $input.muted,
                     meter: { mixer.meter(for: id) }, highlight: hl, meterSupported: input.hasAudio,
                     audioState: state, onAudioState: { press(state) },
                     meterDim: { !mixer.reachesMaster(id) }) {
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
                            .background(input.audioFollowsVideo ? (AppSkin.isMono ? Color(white: 0.36) : Theme.program) : Theme.button)
                            .clipShape(RoundedRectangle(cornerRadius: Theme.radius, style: .continuous))
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
                    .clipShape(RoundedRectangle(cornerRadius: Theme.radius, style: .continuous))
                    .help(extraBuses.isEmpty ? L("버스 A~G 보내기, Audio Settings") : Lf("버스 %@ · Audio Settings", "\(extraBuses)"))
                }
            }
        }
    }

    /// vMix-style audio button: AUTO → manual ON (Follow off), ON / ON AIR → MUTE, MUTE → back.
    private func press(_ state: InputAudioState) {
        switch state {
        case .auto: input.audioFollowsVideo = false; input.muted = false
        case .on, .onAir: input.muted = true
        case .mute: input.muted = false
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

/// Input channel audio state shown on its strip button (vMix: Audio On / Audio Auto).
enum InputAudioState: Equatable {
    case onAir, auto, on, mute

    var label: String {
        switch self {
        case .onAir: return "ON AIR"
        case .auto: return "AUTO"
        case .on: return "ON"
        case .mute: return "MUTE"
        }
    }
    var symbol: String {
        switch self {
        case .mute: return "speaker.slash.fill"
        case .auto: return "speaker.fill"
        default: return "speaker.wave.2.fill"
        }
    }
    var color: Color {
        switch self {
        case .onAir: return Theme.program
        case .auto: return Theme.panelDark
        case .on: return AppSkin.isMono ? Theme.primaryFill : Theme.accent
        case .mute: return AppSkin.isMono ? Color(white: 0.2) : Theme.live
        }
    }
    var textColor: Color {
        switch self {
        case .auto: return Color(white: 0.75)
        case .on: return AppSkin.isMono ? .black : .white
        case .mute: return AppSkin.isMono ? Color(red: 1, green: 0.42, blue: 0.38) : .white
        case .onAir: return .white
        }
    }
    var help: String {
        switch self {
        case .onAir: return L("Follow 로 지금 마스터에 나가는 중 — 누르면 MUTE")
        case .auto: return L("Follow 대기 — 출력되면 자동으로 켜짐. 누르면 수동 ON (Follow 꺼짐)")
        case .on: return L("수동 ON — 출력과 관계없이 항상 마스터로. 누르면 MUTE")
        case .mute: return L("음소거 — 누르면 다시 켜짐 (→ 가 켜져 있으면 AUTO)")
        }
    }
}

struct ChannelStrip<Accessory: View>: View {
    let title: String
    @Binding var volume: Float
    @Binding var muted: Bool
    let meter: () -> (Float, Float)
    var highlight: Color?
    var meterSupported = true
    var audioState: InputAudioState? = nil
    var onAudioState: (() -> Void)? = nil
    var meterDim: (() -> Bool)? = nil
    @AppStorage("audioMetersCollapsed") private var metersCollapsed = false
    let accessory: Accessory

    init(title: String, volume: Binding<Float>, muted: Binding<Bool>, meter: @escaping () -> (Float, Float),
         highlight: Color?, meterSupported: Bool = true, audioState: InputAudioState? = nil,
         onAudioState: (() -> Void)? = nil, meterDim: (() -> Bool)? = nil, @ViewBuilder accessory: () -> Accessory) {
        self.title = title
        self._volume = volume
        self._muted = muted
        self.meter = meter
        self.highlight = highlight
        self.meterSupported = meterSupported
        self.audioState = audioState
        self.onAudioState = onAudioState
        self.meterDim = meterDim
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
                if !metersCollapsed && meterSupported {
                    LayerMeter(meter: meter, dim: meterDim).frame(width: 11)
                } else {
                    Spacer(minLength: 0)
                }
                VerticalFader(value: $volume)
                    .frame(width: 26)
                if metersCollapsed || !meterSupported { Spacer(minLength: 0) }
            }
            .frame(minHeight: 70, maxHeight: .infinity)
            Text(volume <= 0.0001 ? "-inf" : String(format: "%.1f", 20 * log10(Double(volume * volume))))
                .font(.system(size: 9).monospacedDigit())
                .foregroundColor(.secondary)
            if let st = audioState, let press = onAudioState {
                Button(action: press) {
                    HStack(spacing: 3) {
                        Image(systemName: st.symbol).font(.system(size: 9))
                        Text(st.label).font(.system(size: 9, weight: .heavy)).lineLimit(1).minimumScaleFactor(0.7)
                    }
                    .frame(width: 58, height: 20)
                    .foregroundColor(st.textColor)
                    .background(st.color)
                    .overlay(RoundedRectangle(cornerRadius: Theme.radius, style: .continuous).stroke(st == .auto ? Color(white: 0.45) : .clear, lineWidth: 1))
                    .clipShape(RoundedRectangle(cornerRadius: Theme.radius, style: .continuous))
                }
                .buttonStyle(.plain)
                .help(st.help)
            } else {
                Button {
                    muted.toggle()
                } label: {
                    Image(systemName: muted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                        .font(.system(size: 10))
                        .frame(width: 58, height: 20)
                        .foregroundColor(.white)
                        .background(muted ? Theme.live : Theme.button)
                        .clipShape(RoundedRectangle(cornerRadius: Theme.radius, style: .continuous))
                }
                .buttonStyle(.plain)
                .help("Mute")
            }
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
