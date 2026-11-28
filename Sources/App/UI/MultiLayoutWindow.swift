import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// Window "MultiLayouts": scenes and inputs on the left, the layout with its live picture in the middle
/// (drag boxes, drop inputs on them), the selected box and the MultiLayout's settings on the right.
/// Clicking a scene takes it (the boxes animate); keys 1–9 and ← / → do the same while this window is in front.
struct MultiLayoutWindow: View {
    @Environment(SwitcherEngine.self) var engine
    @ViewState private var chosen: UUID? = nil

    private var layouts: [MultiLayoutInput] { engine.inputs.compactMap { $0 as? MultiLayoutInput } }
    private var current: MultiLayoutInput? { layouts.first { $0.id == chosen } ?? layouts.first }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Text("MultiLayout").font(.headline)
                if layouts.count > 1 {
                    Picker("", selection: Binding(get: { current?.id }, set: { chosen = $0 })) {
                        ForEach(layouts, id: \.id) { Text($0.name).tag(Optional($0.id)) }
                    }
                    .labelsHidden().frame(width: 220)
                } else if let c = current {
                    Text(c.name).foregroundColor(.secondary)
                }
                Spacer()
                Button { addLayout() } label: { Label(L("새 MultiLayout"), systemImage: "plus") }.cueKey()
            }
            .padding(.horizontal, 14).padding(.vertical, 8)
            Divider()
            if let ml = current {
                MultiLayoutEditor(ml: ml).id(ml.id)
            } else {
                VStack(spacing: 10) {
                    Text(L("스위처에 MultiLayout 입력이 아직 없습니다.")).foregroundColor(.secondary)
                    Button(L("MultiLayout 입력 추가")) { addLayout() }.cueKey(Theme.accent, prominent: true)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(minWidth: 1280, minHeight: 720)
        .background(BrushedMetal(base: AppLook.hardware ? Theme.window : Color(white: 0.08)))
    }

    private func addLayout() {
        var c = InputConfig(kind: .multiLayout, name: layouts.isEmpty ? "MultiLayout" : "MultiLayout \(layouts.count + 1)")
        c.multiLayout = .starter
        c.category = InputCategory.current
        engine.addInput(c)
        chosen = c.id
    }
}

/// The editor of one MultiLayout input.
struct MultiLayoutEditor: View {
    @Environment(SwitcherEngine.self) var engine
    @ObservedObject var ml: MultiLayoutInput
    @ViewState private var box = 0
    @ViewState private var renaming: Int? = nil
    @ViewState private var safeArea = false
    @ViewState private var library = MLLibrary.load()

    /// The scene in preview (being set up, not on air); nil = the live scene.
    @ViewState private var editing: Int? = nil
    private var live: Int { ml.multiLayout.scene }
    /// The scene the canvas and settings show: the preview scene, else the live one.
    private var edited: Int { editing.flatMap { ml.multiLayout.scenes.indices.contains($0) && $0 != live ? $0 : nil } ?? live }
    private var hasScene: Bool { ml.multiLayout.scenes.indices.contains(edited) }
    /// Inputs that can go in a box (not this MultiLayout itself, no audio-only inputs).
    private var sources: [InputSource] { engine.inputs.filter { $0.id != ml.id && $0.kind != .audio } }

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            VStack(alignment: .leading, spacing: 0) {
                scenes
                Divider().padding(.vertical, 8)
                inputs
            }
            .padding(12)
            .frame(width: 250)
            Divider()
            VStack(spacing: 10) {
                MLCanvas(ml: ml, scene: edited, box: $box, safeArea: safeArea, onAir: engine.tally(of: ml) == 1)
                if hasScene { layoutBar; animationBar }
                Spacer(minLength: 0)
            }
            .padding(12)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if hasScene { boxInspector }
                    Divider()
                    layoutSettings
                }
                .padding(12)
            }
            .frame(width: 320)
        }
        .background(sceneKeys)
    }

    // MARK: Left: scenes, inputs

    private var scenes: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(L("장면")).font(.system(size: 11, weight: .bold)).textCase(.uppercase).foregroundColor(.secondary)
                Spacer()
                Button { addScene() } label: { Image(systemName: "plus") }
                    .buttonStyle(.borderless).help(L("장면 추가 (지금 장면 복사)"))
            }
            ScrollView {
                VStack(spacing: 4) {
                    ForEach(Array(ml.multiLayout.scenes.enumerated()), id: \.element.id) { i, s in sceneRow(i, s) }
                }
            }
            .frame(maxHeight: 300)
            Button { takePreview() } label: {
                Text("TAKE").font(.system(size: 15, weight: .heavy)).frame(maxWidth: .infinity, minHeight: 30)
            }
            .cueKey(editing != nil && edited != live ? Theme.live : nil, prominent: true, cleanTint: .red)
            .disabled(edited == live)
            .keyboardShortcut(.return, modifiers: [])
            .help(L("미리보기 장면을 방송으로 (Enter)"))
            HStack(spacing: 6) {
                Button { ml.previous() } label: { Image(systemName: "chevron.left").frame(maxWidth: .infinity) }
                    .cueKey().help(L("이전 장면 (←)"))
                Button { ml.next() } label: { Image(systemName: "chevron.right").frame(maxWidth: .infinity) }
                    .cueKey().help(L("다음 장면 (→)"))
            }
        }
    }

    private func sceneRow(_ i: Int, _ s: MLScene) -> some View {
        let isLive = i == live, isPreview = i == edited && !isLive
        return HStack(spacing: 8) {
            Text("\(i + 1)").font(.system(size: 12, weight: .bold, design: .monospaced))
                .frame(width: 20).foregroundColor(isLive ? .white : .secondary)
            MLThumb(scene: s).frame(width: 48, height: 27)
            if renaming == i {
                TextField("", text: Binding(get: { ml.multiLayout.scenes[i].name },
                                            set: { ml.multiLayout.scenes[i].name = $0 }))
                    .textFieldStyle(.roundedBorder).onSubmit { renaming = nil }
            } else {
                Text(s.name.isEmpty ? Lf("장면 %@", "\(i + 1)") : s.name).lineLimit(1)
                Spacer(minLength: 0)
            }
            if !isLive {
                Button { take(i) } label: { Image(systemName: "play.fill").font(.system(size: 9)) }
                    .buttonStyle(.borderless).help(L("바로 방송 (애니메이션)"))
            }
        }
        .padding(.horizontal, 6).padding(.vertical, 4)
        .replayKey(isLive ? Theme.live : isPreview ? Theme.preview.opacity(0.8)
                   : (AppLook.hardware ? ReplayKey.neutral : Color.white.opacity(0.05)), radius: 5)
        .contentShape(Rectangle())
        .onTapGesture { editing = i == live ? nil : i }      // preview: set it up without going on air
        .simultaneousGesture(TapGesture(count: 2).onEnded { renaming = i })
        .contextMenu {
            Button(L("이름 바꾸기")) { renaming = i }
            Button(L("복제")) { duplicate(i) }
            if i > 0 { Button(L("위로")) { move(i, to: i - 1) } }
            if i < ml.multiLayout.scenes.count - 1 { Button(L("아래로")) { move(i, to: i + 1) } }
            if ml.multiLayout.scenes.count > 1 { Button(L("삭제"), role: .destructive) { deleteScene(i) } }
        }
        .help(L("클릭 = 미리보기에서 설정 · ▶ = 바로 방송 · 더블클릭 = 이름 바꾸기"))
    }

    private var inputs: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(L("입력 — 상자로 끌어다 놓기")).font(.system(size: 11, weight: .bold)).textCase(.uppercase).foregroundColor(.secondary)
            ScrollView {
                VStack(spacing: 3) {
                    ForEach(sources, id: \.id) { i in
                        HStack(spacing: 6) {
                            Text("\(engine.number(ofID: i.id))").font(.system(size: 10, design: .monospaced)).foregroundColor(.secondary).frame(width: 18)
                            Image(systemName: i.kind.symbol).frame(width: 16).foregroundColor(.secondary)
                            Text(i.name).lineLimit(1)
                            Spacer(minLength: 0)
                            if ml.shownInputs.contains(i.id) { Circle().fill(Theme.live).frame(width: 6, height: 6) }
                        }
                        .padding(.horizontal, 6).padding(.vertical, 3)
                        .replayKey(AppLook.hardware ? ReplayKey.neutral : Color.white.opacity(0.04), radius: 4)
                        .contentShape(Rectangle())
                        .draggable(i.id.uuidString)
                        .onTapGesture(count: 2) {
                            if edited == live { ml.setInput(i.id, box: box) } else { ml.multiLayout.scenes[edited].boxes[box].input = i.id }
                        }
                        .help(L("상자에 끌어다 놓기 · 더블클릭 = 선택한 상자에 넣기"))
                    }
                }
            }
        }
    }

    // MARK: Middle: layouts, animation

    private var layoutBar: some View {
        HStack(spacing: 6) {
            Text(L("레이아웃")).font(.system(size: 11, weight: .bold)).foregroundColor(.secondary)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(MLPreset.allCases) { p in
                        Button { applyRects(p.rects) } label: { MLThumb(rects: p.rects).frame(width: 48, height: 27) }
                            .buttonStyle(.plain).help(p.label)
                    }
                    if !library.isEmpty { Divider().frame(height: 24) }
                    ForEach(library) { l in
                        Button { applyRects(l.rects) } label: { MLThumb(rects: l.rects).frame(width: 48, height: 27) }
                            .buttonStyle(.plain).help(l.name)
                            .contextMenu {
                                Button(L("삭제"), role: .destructive) { library.removeAll { $0.id == l.id }; MLLibrary.save(library) }
                            }
                    }
                }
            }
            Button(L("내 레이아웃으로 저장")) { saveToLibrary() }.cueKey()
                .help(L("이 장면의 상자 위치를 모든 MultiLayout에서 쓸 수 있게 저장"))
        }
    }

    private var animationBar: some View {
        HStack(spacing: 12) {
            Text(L("이 장면으로 바뀔 때")).font(.system(size: 11, weight: .bold)).foregroundColor(.secondary)
            Picker("", selection: $ml.multiLayout.scenes[edited].appear) {
                Text(L("날아오기")).tag(MLAppear.fly)
                Text(L("커지기")).tag(MLAppear.grow)
                Text(L("페이드")).tag(MLAppear.fade)
                Text(L("컷")).tag(MLAppear.cut)
            }
            .pickerStyle(.segmented).labelsHidden().frame(width: 300)
            .help(L("새로 나타나거나 사라지는 상자의 움직임"))
            Text(L("시간")).foregroundColor(.secondary)
            ReplaySlider(value: Binding(get: { ml.multiLayout.scenes[edited].seconds },
                                        set: { ml.multiLayout.scenes[edited].seconds = ($0 * 10).rounded() / 10 }), range: 0...3)
                .frame(width: 140)
            Text(ml.multiLayout.scenes[edited].seconds == 0 ? L("컷") : String(format: "%.1f s", ml.multiLayout.scenes[edited].seconds))
                .font(.system(size: 11, design: .monospaced)).frame(width: 40, alignment: .leading)
            Spacer()
            Toggle(L("안전 영역"), isOn: $safeArea).toggleStyle(.checkbox)
        }
    }

    // MARK: Right: the selected box, the MultiLayout

    private var boxInspector: some View {
        let sb = $ml.multiLayout.scenes[edited].boxes[box]
        let b = $ml.multiLayout.boxes[box]
        return VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(L("상자")).font(.headline).lineLimit(1).fixedSize()   // "Box" never wraps
                Picker("", selection: $box) { ForEach(0..<MLScene.boxCount, id: \.self) { Text("\($0 + 1)").tag($0) } }
                    .pickerStyle(.segmented).labelsHidden()
            }
            Toggle(L("이 장면에서 보이기"), isOn: sb.visible)
            if edited == live {
                inputPicker(L("입력"), b.inputID)
                inputPicker(L("이 장면에서만 다른 입력"), sb.input, none: L("상자 입력 그대로"))
            } else {
                // preview: an input chosen here is this scene's own (the box's input is on air)
                inputPicker(L("이 장면의 입력"), sb.input, none: L("상자 입력 그대로"))
            }
            Group {
                Text(L("위치 · 크기 (%)")).font(.system(size: 11, weight: .bold)).foregroundColor(.secondary)
                HStack {
                    number("X", sb.rect.x); number("Y", sb.rect.y)
                    number(L("너비"), sb.rect.w); number(L("높이"), sb.rect.h)
                }
            }
            if edited != live {
                Text(L("아래 모양 설정은 모든 장면의 이 상자에 적용됩니다 (방송 중인 장면 포함)."))
                    .font(.caption).foregroundColor(Theme.preview).fixedSize(horizontal: false, vertical: true)
            }
            Picker(L("맞추기"), selection: b.fill) {
                Text(L("채우기 (잘라서)")).tag(true)
                Text(L("맞추기 (전체)")).tag(false)
            }
            .pickerStyle(.segmented)
            slider(L("확대"), b.zoom, 1...4, "%.2f×")
            slider(L("좌우 이동"), b.panX, -1...1, "%.2f")
            slider(L("상하 이동"), b.panY, -1...1, "%.2f")
            Group {
                Text(L("자르기 (%)")).font(.system(size: 11, weight: .bold)).foregroundColor(.secondary)
                HStack { number(L("왼쪽"), b.cropL); number(L("위"), b.cropT); number(L("오른쪽"), b.cropR); number(L("아래"), b.cropB) }
            }
            slider(L("모서리 둥글게"), b.radius, 0...200, "%.0f px")
            HStack {
                slider(L("테두리"), b.border, 0...40, "%.0f px")
                ColorPicker("", selection: Binding(get: { MLColor.color(b.wrappedValue.borderColor) },
                                                   set: { b.wrappedValue.borderColor = MLColor.hex($0) }), supportsOpacity: false)
                    .labelsHidden()
            }
            Button(L("이 상자 모양을 모든 상자에 적용")) {
                let s = ml.multiLayout.boxes[box]
                var m = ml.multiLayout
                for k in m.boxes.indices where k != box {
                    let input = m.boxes[k].inputID
                    m.boxes[k] = s; m.boxes[k].inputID = input
                }
                ml.multiLayout = m
            }
            .cueKey().help(L("테두리, 둥근 모서리, 맞추기를 복사 (입력은 그대로)"))
        }
    }

    private var layoutSettings: some View {
        let bg = $ml.multiLayout.background
        return VStack(alignment: .leading, spacing: 10) {
            Text(L("배경")).font(.headline)
            Picker("", selection: bg.kind) {
                Text(L("색")).tag(MLBackground.Kind.color)
                Text(L("이미지")).tag(MLBackground.Kind.image)
                Text(L("입력")).tag(MLBackground.Kind.input)
            }
            .pickerStyle(.segmented).labelsHidden()
            switch ml.multiLayout.background.kind {
            case .color:
                ColorPicker(L("배경색"), selection: Binding(get: { MLColor.color(bg.wrappedValue.color) },
                                                          set: { bg.wrappedValue.color = MLColor.hex($0) }), supportsOpacity: false)
            case .image:
                fileRow(bg.wrappedValue.path, pick: { bg.wrappedValue.path = $0 })
            case .input:
                inputPicker(L("배경 입력"), bg.inputID)
                Text(L("반복 재생 영상, 카메라, 타이틀 등 어떤 입력이든 됩니다.")).font(.caption).foregroundColor(.secondary)
            }
            Text(L("전경 (투명 PNG)")).font(.headline).padding(.top, 6)
            fileRow(ml.multiLayout.foregroundPath, pick: { ml.multiLayout.foregroundPath = $0 })
            Text(L("상자 위에 그려집니다: 프레임, 로고, 자막 바.")).font(.caption).foregroundColor(.secondary)
            slider(L("입력 바꿀 때 크로스페이드"), $ml.multiLayout.inputFade, 0...2, "%.1f s")
            Toggle(L("방송에 나갈 때 애니메이션"), isOn: $ml.multiLayout.animateOnAir)
            Text(L("Program에 나갈 때: 방금 나가던 입력의 상자가 전체 화면에서 제자리로 줄어들고 다른 상자들이 들어옵니다. 상자에 있는 입력으로 돌아갈 때: 그 상자가 전체 화면으로 커진 다음 전환됩니다."))
                .font(.caption).foregroundColor(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: Controls

    private func inputPicker(_ title: String, _ sel: Binding<UUID?>, none: String = L("없음")) -> some View {
        Picker(title, selection: sel) {
            Text(none).tag(UUID?.none)
            ForEach(sources, id: \.id) { i in Text("\(engine.number(ofID: i.id)). \(i.name)").tag(Optional(i.id)) }
        }
    }

    private func number(_ title: String, _ v: Binding<Double>) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.system(size: 10)).foregroundColor(.secondary)
            TextField("", value: Binding(get: { (v.wrappedValue * 1000).rounded() / 10 },
                                         set: { v.wrappedValue = $0 / 100 }), format: .number)
                .textFieldStyle(.roundedBorder).frame(width: 58)
        }
    }

    private func slider(_ title: String, _ v: Binding<Double>, _ r: ClosedRange<Double>, _ f: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(title).font(.system(size: 11))
                Spacer()
                Text(String(format: f, v.wrappedValue)).font(.system(size: 10, design: .monospaced)).foregroundColor(.secondary)
            }
            ReplaySlider(value: v, range: r)
        }
    }

    private func fileRow(_ path: String, pick: @escaping (String) -> Void) -> some View {
        HStack {
            Text(path.isEmpty ? L("없음") : (path as NSString).lastPathComponent).lineLimit(1).truncationMode(.middle)
                .foregroundColor(path.isEmpty ? .secondary : .primary)
            Spacer()
            if !path.isEmpty { Button { pick("") } label: { Image(systemName: "xmark.circle") }.buttonStyle(.borderless) }
            Button(L("선택…")) {
                let p = NSOpenPanel()
                p.allowedContentTypes = [.image]
                if p.runModal() == .OK, let u = p.url { pick(u.path) }
            }
        }
    }

    // MARK: Actions

    private func take(_ i: Int) { ml.take(scene: i); editing = nil }

    private func takePreview() {
        if let f = typingField() { f.window?.makeFirstResponder(nil); renaming = nil; return }   // Enter ends the typing
        guard edited != live else { return }
        take(edited)
    }

    private func applyRects(_ rects: [MLRect]) {
        guard hasScene else { return }
        var m = ml.multiLayout
        m.scenes[edited].apply(rects)
        ml.multiLayout = m
        if box >= rects.count { box = 0 }
    }

    private func addScene() {
        var m = ml.multiLayout
        var s = hasScene ? m.scenes[edited] : MLScene(name: "")
        s.id = UUID()
        s.name = Lf("장면 %@", "\(m.scenes.count + 1)")
        m.scenes.append(s)
        ml.multiLayout = m
        editing = m.scenes.count - 1                        // set it up in preview first
    }

    private func duplicate(_ i: Int) {
        var m = ml.multiLayout
        var s = m.scenes[i]
        s.id = UUID(); s.name += " 2"
        m.scenes.insert(s, at: i + 1)
        if m.scene > i { m.scene += 1 }
        if let e = editing, e > i { editing = e + 1 }
        ml.multiLayout = m
    }

    private func deleteScene(_ i: Int) {
        var m = ml.multiLayout
        m.scenes.remove(at: i)
        let wasLive = m.scene == i
        if m.scene > i || m.scene >= m.scenes.count { m.scene = max(0, m.scene - 1) }
        ml.apply(m, animateLive: wasLive)        // the scene that takes over animates in
        editing = nil
        renaming = nil
    }

    /// Swap two scenes in one change (live and preview follow their scene), so nothing on air moves.
    private func move(_ i: Int, to j: Int) {
        var m = ml.multiLayout
        m.scenes.swapAt(i, j)
        if m.scene == i { m.scene = j } else if m.scene == j { m.scene = i }
        if let e = editing { editing = e == i ? j : e == j ? i : e }
        if let r = renaming { renaming = r == i ? j : r == j ? i : r }
        ml.multiLayout = m
    }

    private func saveToLibrary() {
        guard hasScene else { return }
        let s = ml.multiLayout.scenes[edited]
        let rects = s.boxes.prefix { $0.visible }.map(\.rect)
        let all = s.boxes.filter(\.visible).map(\.rect)
        library.append(MLLayout(name: s.name, rects: rects.count == all.count ? rects : all))
        MLLibrary.save(library)
    }

    // MARK: Keys: 1–9 take a scene, ← / → previous / next (typing in a field keeps the key)

    private var sceneKeys: some View {
        ZStack {
            ForEach(0..<9, id: \.self) { k in
                Button("") { key(Character("\(k + 1)")) { take(k) } }
                    .keyboardShortcut(KeyEquivalent(Character("\(k + 1)")), modifiers: [])
            }
            Button("") { arrow(left: true) }.keyboardShortcut(.leftArrow, modifiers: [])
            Button("") { arrow(left: false) }.keyboardShortcut(.rightArrow, modifiers: [])
        }
        .opacity(0).allowsHitTesting(false)
    }

    private func typingField() -> NSTextView? {
        guard let field = NSApp.keyWindow?.firstResponder as? NSTextView, field.isFieldEditor else { return nil }
        return field
    }

    private func key(_ c: Character, _ action: () -> Void) {
        if let f = typingField() { f.insertText(String(c), replacementRange: f.selectedRange()); return }
        action()
    }

    private func arrow(left: Bool) {
        if let f = typingField() { if left { f.moveLeft(nil) } else { f.moveRight(nil) }; return }
        if left { ml.previous() } else { ml.next() }
        editing = nil
    }
}

/// The layout with the MultiLayout's live picture under it: drag a box to move it, its corner to resize
/// (Shift keeps 16:9), drop an input on a box. Edges snap to the screen, its centre and the other boxes.
struct MLCanvas: View {
    @Environment(SwitcherEngine.self) var engine
    @ObservedObject var ml: MultiLayoutInput
    /// The scene shown: the live one (its real picture) or one in preview (drawn from the inputs).
    var scene: Int
    @Binding var box: Int
    var safeArea: Bool
    var onAir: Bool
    @ViewState private var dragStart: MLRect? = nil
    @ViewState private var dropTarget: Int? = nil

    private var live: Int { scene }
    private var isLive: Bool { scene == ml.multiLayout.scene }

    var body: some View {
        GeometryReader { geo in
            let size = fitted(geo.size)
            ZStack(alignment: .topLeading) {
                if isLive {
                    MonitorView(fps: 30) { [weak ml] in ml?.monitorFrame() }
                        .frame(width: size.width, height: size.height)
                } else {
                    MLPreviewPicture(ml: ml, scene: scene, size: size)
                }
                if safeArea { safeGuides(size) }
                if ml.multiLayout.scenes.indices.contains(live) {
                    let boxes = ml.multiLayout.scenes[live].boxes
                    ForEach(0..<MLScene.boxCount, id: \.self) { k in
                        if boxes[k].visible { boxView(k, boxes[k].rect, size) }
                    }
                }
            }
            .frame(width: size.width, height: size.height)
            .contentShape(Rectangle())   // a box dragged past the edge doesn't take clicks outside the canvas
            // One drop target for the whole picture: the box under the pointer gets the input. (A drop target
            // per box sat at the box's un-offset place — top left — so drops went to the wrong box.)
            .onDrop(of: [.utf8PlainText, .plainText], delegate: MLBoxDrop(ml: ml, scene: scene, isLive: isLive, size: size,
                                                                          box: $box, target: $dropTarget))
            .overlay(alignment: .topLeading) {
                if !isLive {
                    Text(L("미리보기")).font(.system(size: 11, weight: .heavy)).foregroundColor(.white)
                        .padding(.horizontal, 6).padding(.vertical, 2).background(Theme.preview).padding(6)
                }
            }
            .overlay(alignment: .topTrailing) {
                if onAir && isLive {
                    Text("LIVE").font(.system(size: 11, weight: .heavy)).foregroundColor(.white)
                        .padding(.horizontal, 6).padding(.vertical, 2).background(Theme.live).padding(6)
                }
            }
            .overlay(Rectangle().stroke(!isLive ? Theme.preview : onAir ? Theme.live : Color.white.opacity(0.2),
                                        lineWidth: !isLive || onAir ? 3 : 1))
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .aspectRatio(16.0 / 9.0, contentMode: .fit)
        .help(!isLive ? L("미리보기: 방송에는 영향 없음. TAKE로 방송에 보냅니다.")
              : onAir ? L("이 MultiLayout은 지금 방송 중입니다: 바꾸는 것이 바로 보입니다.") : "")
    }

    private func fitted(_ s: CGSize) -> CGSize {
        let w = min(s.width, s.height * 16 / 9)
        return CGSize(width: w, height: w * 9 / 16)
    }

    private func safeGuides(_ size: CGSize) -> some View {
        ZStack(alignment: .topLeading) {
            Rectangle().stroke(Color.yellow.opacity(0.5), style: StrokeStyle(lineWidth: 1, dash: [4, 4]))
                .frame(width: size.width * 0.9, height: size.height * 0.9).offset(x: size.width * 0.05, y: size.height * 0.05)
            Rectangle().fill(Color.yellow.opacity(0.35)).frame(width: 1, height: size.height).offset(x: size.width / 2)
            Rectangle().fill(Color.yellow.opacity(0.35)).frame(width: size.width, height: 1).offset(y: size.height / 2)
        }
        .allowsHitTesting(false)
    }

    private func name(_ k: Int) -> String {
        let s = ml.multiLayout.scenes[live].boxes[k]
        let id = s.input ?? ml.multiLayout.boxes[k].inputID
        return engine.input(withID: id)?.name ?? L("입력 없음")
    }

    private func boxView(_ k: Int, _ r: MLRect, _ size: CGSize) -> some View {
        let sel = k == box
        let frame = CGRect(x: r.x * size.width, y: r.y * size.height, width: r.w * size.width, height: r.h * size.height)
        return ZStack(alignment: .topLeading) {
            Rectangle().fill(dropTarget == k ? Color.accentColor.opacity(0.3) : Color.white.opacity(0.001))
            Rectangle().stroke(sel ? Color.yellow : Color.white.opacity(0.55), lineWidth: sel ? 2 : 1)
            Text("\(k + 1)  \(name(k))").font(.system(size: 10, weight: .semibold)).foregroundColor(.white).lineLimit(1)
                .padding(.horizontal, 4).padding(.vertical, 1).background(Color.black.opacity(0.6)).padding(3)
            if sel {
                Rectangle().fill(Color.yellow).frame(width: 10, height: 10)
                    .offset(x: frame.width - 6, y: frame.height - 6)
                    .gesture(DragGesture(minimumDistance: 1, coordinateSpace: .global)
                        .onChanged { g in resize(k, g.translation, size) }
                        .onEnded { _ in dragStart = nil })
            }
        }
        .frame(width: max(4, frame.width), height: max(4, frame.height))
        .offset(x: frame.minX, y: frame.minY)
        .gesture(DragGesture(minimumDistance: 2, coordinateSpace: .global)
            .onChanged { g in box = k; move(k, g.translation, size) }
            .onEnded { _ in dragStart = nil })
        .simultaneousGesture(TapGesture().onEnded { box = k })
    }

    private func move(_ k: Int, _ t: CGSize, _ size: CGSize) {
        let start = dragStart ?? ml.multiLayout.scenes[live].boxes[k].rect
        dragStart = start
        var r = start
        r.x = start.x + t.width / size.width
        r.y = start.y + t.height / size.height
        r = MLSnap.move(r, others: others(k))
        ml.multiLayout.scenes[live].boxes[k].rect = r
    }

    private func resize(_ k: Int, _ t: CGSize, _ size: CGSize) {
        let start = dragStart ?? ml.multiLayout.scenes[live].boxes[k].rect
        dragStart = start
        var r = start
        r.w = max(0.03, start.w + t.width / size.width)
        r.h = max(0.03, start.h + t.height / size.height)
        if NSEvent.modifierFlags.contains(.shift) { r.h = r.w }      // 16:9 box on a 16:9 output
        else { r = MLSnap.resize(r, others: others(k)) }
        ml.multiLayout.scenes[live].boxes[k].rect = r
    }

    private func others(_ k: Int) -> [MLRect] {
        ml.multiLayout.scenes[live].boxes.enumerated().filter { $0.offset != k && $0.element.visible }.map(\.element.rect)
    }
}

/// Snapping while dragging: box edges and centre to the screen edges, its centre, the 5 % safe margin
/// and the other boxes' edges (within 1 %).
enum MLSnap {
    static let reach = 0.01

    private static func lines(_ others: [MLRect], vertical: Bool) -> [Double] {
        var l = [0, 0.05, 0.5, 0.95, 1.0]
        for o in others { l += vertical ? [o.x, o.x + o.w, o.x + o.w / 2] : [o.y, o.y + o.h, o.y + o.h / 2] }
        return l
    }

    private static func snap(_ v: Double, _ lines: [Double]) -> Double? {
        lines.map { ($0, abs($0 - v)) }.filter { $0.1 < reach }.min { $0.1 < $1.1 }?.0
    }

    static func move(_ r: MLRect, others: [MLRect]) -> MLRect {
        var o = r
        let vx = lines(others, vertical: true), hy = lines(others, vertical: false)
        if let s = snap(r.x, vx) { o.x = s } else if let s = snap(r.x + r.w, vx) { o.x = s - r.w } else if let s = snap(r.x + r.w / 2, vx) { o.x = s - r.w / 2 }
        if let s = snap(r.y, hy) { o.y = s } else if let s = snap(r.y + r.h, hy) { o.y = s - r.h } else if let s = snap(r.y + r.h / 2, hy) { o.y = s - r.h / 2 }
        return o
    }

    static func resize(_ r: MLRect, others: [MLRect]) -> MLRect {
        var o = r
        if let s = snap(r.x + r.w, lines(others, vertical: true)) { o.w = s - r.x }
        if let s = snap(r.y + r.h, lines(others, vertical: false)) { o.h = s - r.y }
        return o
    }
}

/// A small drawing of a layout's boxes (scene list, layout buttons).
struct MLThumb: View {
    var rects: [MLRect]
    init(rects: [MLRect]) { self.rects = rects }
    init(scene: MLScene) { rects = scene.boxes.filter(\.visible).map(\.rect) }

    var body: some View {
        Canvas { ctx, size in
            ctx.fill(Path(CGRect(origin: .zero, size: size)), with: .color(Color.black.opacity(0.6)))
            for (k, r) in rects.enumerated() {
                let f = CGRect(x: r.x * size.width, y: r.y * size.height, width: r.w * size.width, height: r.h * size.height)
                ctx.fill(Path(f), with: .color(Color(white: k == 0 ? 0.62 : 0.45)))
                ctx.stroke(Path(f), with: .color(.black), lineWidth: 0.5)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 2))
        .overlay(RoundedRectangle(cornerRadius: 2).stroke(Color.white.opacity(0.25), lineWidth: 0.5))
    }
}

/// The shared library of own layouts (all MultiLayouts, all projects).
enum MLLibrary {
    private static let key = "multiLayoutLibrary"
    static func load() -> [MLLayout] {
        guard let d = UserDefaults.standard.data(forKey: key) else { return [] }
        return (try? JSONDecoder().decode([MLLayout].self, from: d)) ?? []
    }
    static func save(_ l: [MLLayout]) {
        if let d = try? JSONEncoder().encode(l) { UserDefaults.standard.set(d, forKey: key) }
    }
}

enum MLColor {
    static func color(_ hex: String) -> Color {
        let c = HexColor.parse(hex) ?? (1, 1, 1, 1)
        return Color(red: c.0, green: c.1, blue: c.2)
    }
    static func hex(_ c: Color) -> String {
        let n = NSColor(c).usingColorSpace(.sRGB) ?? .white
        return String(format: "#%02X%02X%02X", Int(n.redComponent * 255), Int(n.greenComponent * 255), Int(n.blueComponent * 255))
    }
}

extension MLPreset {
    var label: String {
        switch self {
        case .full: return L("전체 화면")
        case .sideBySide: return L("나란히 2개 (16:9)")
        case .split2: return L("2분할 좌우 (꽉 채우기)")
        case .threeUp: return L("나란히 3개 (16:9)")
        case .quad: return L("4분할 (2×2)")
        case .onePlus2: return L("큰 화면 + 오른쪽 2개")
        case .onePlus3: return L("1 + 3 (큰 화면 + 오른쪽 3개)")
        case .sixGrid: return L("6분할 (3×2)")
        case .eightGrid: return L("8분할 (4×2)")
        case .pipBR: return L("PIP 오른쪽 아래")
        case .pipBL: return L("PIP 왼쪽 아래")
        case .twoPip: return L("PIP 2개 (아래 좌우)")
        }
    }
}

/// Input tile of a MultiLayout: ◀ 1 2 3 … ▶ — a click takes that scene (animated); right-click lists the names.
struct TileSceneStrip: View {
    @ObservedObject var ml: MultiLayoutInput

    var body: some View {
        HStack(spacing: 3) {
            Button { ml.previous() } label: { Image(systemName: "chevron.left").frame(width: 16, height: 16) }
                .help(L("이전 장면 (MultiLayoutPrevious)"))
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 3) {
                    ForEach(Array(ml.multiLayout.scenes.enumerated()), id: \.element.id) { i, s in
                        Button { ml.take(scene: i) } label: {
                            Text("\(i + 1)").font(.system(size: 10, weight: .bold)).monospacedDigit()
                                .foregroundColor(i == ml.multiLayout.scene ? .white : Theme.buttonText)
                                .frame(minWidth: 18, minHeight: 16)
                                .replayKey(i == ml.multiLayout.scene ? Theme.live : ReplayKey.neutral, radius: 3)
                        }
                        .buttonStyle(.plain)
                        .help(s.name)
                    }
                }
            }
            Button { ml.next() } label: { Image(systemName: "chevron.right").frame(width: 16, height: 16) }
                .help(L("다음 장면 (MultiLayoutNext)"))
        }
        .font(.system(size: 10))
        .buttonStyle(.borderless)
        .padding(.horizontal, 4)
        .frame(height: 20)
        .background(Theme.panel.opacity(0.9))
        .contextMenu {
            ForEach(Array(ml.multiLayout.scenes.enumerated()), id: \.element.id) { i, s in
                Button("\(i + 1). \(s.name)") { ml.take(scene: i) }
            }
        }
    }
}

/// Under the Preview / Output monitors when a MultiLayout is there: its scenes by name.
struct MLSceneControls: View {
    @ObservedObject var ml: MultiLayoutInput

    var body: some View {
        HStack(spacing: 4) {
            Button { ml.previous() } label: { Image(systemName: "chevron.left") }.buttonStyle(.borderless)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 4) {
                    ForEach(Array(ml.multiLayout.scenes.enumerated()), id: \.element.id) { i, s in
                        Button { ml.take(scene: i) } label: {
                            Text("\(i + 1) \(s.name)").font(.system(size: 10, weight: .semibold)).lineLimit(1)
                                .foregroundColor(i == ml.multiLayout.scene ? .white : Theme.buttonText)
                                .padding(.horizontal, 6).frame(minHeight: 18)
                                .replayKey(i == ml.multiLayout.scene ? Theme.live : ReplayKey.neutral, radius: 3)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            Button { ml.next() } label: { Image(systemName: "chevron.right") }.buttonStyle(.borderless)
        }
        .padding(.horizontal, 6)
    }
}

/// A scene that is not on air, drawn from the inputs' own pictures (background, boxes, foreground). Close to
/// what goes on air; rounded corners show as the outline only.
struct MLPreviewPicture: View {
    @Environment(SwitcherEngine.self) var engine
    @ObservedObject var ml: MultiLayoutInput
    var scene: Int
    var size: CGSize

    var body: some View {
        let m = ml.multiLayout
        let sc = m.scenes.indices.contains(scene) ? m.scenes[scene] : MLScene(name: "")
        let px = size.width / max(1, CGFloat(engine.format.width))       // output pixels → canvas points
        ZStack(alignment: .topLeading) {
            switch m.background.kind {
            case .color: MLColor.color(m.background.color)
            case .image: MLImageCache.image(m.background.path).map { Image(nsImage: $0).resizable().scaledToFill() }
            case .input: picture(m.background.inputID, fill: true)
            }
            ForEach(0..<MLScene.boxCount, id: \.self) { k in
                let b = sc.boxes[k]
                if b.visible {
                    let f = MLBoxFrame(box: k, input: b.input ?? m.boxes[k].inputID, rect: b.rect)
                    let l = MultiLayoutInput.layer(f, m.boxes[k])
                    picture(f.input, fill: m.boxes[k].fill, crop: l)
                        .frame(width: b.rect.w * size.width, height: b.rect.h * size.height)
                        .overlay(RoundedRectangle(cornerRadius: m.boxes[k].radius * px)
                            .stroke(MLColor.color(m.boxes[k].borderColor), lineWidth: m.boxes[k].border * px))
                        .offset(x: b.rect.x * size.width, y: b.rect.y * size.height)
                }
            }
            if let fg = MLImageCache.image(m.foregroundPath) { Image(nsImage: fg).resizable().scaledToFill() }
        }
        .frame(width: size.width, height: size.height)
        .clipped()
    }

    @ViewBuilder private func picture(_ id: UUID?, fill: Bool, crop l: InputLayer? = nil) -> some View {
        if let i = engine.input(withID: id) {
            MonitorView(fps: 15, placement: {
                var a = VideoAdjust(); a.fitMode = fill ? 1 : 0
                if let l { a.cropL = l.cropL; a.cropT = l.cropT; a.cropR = l.cropR; a.cropB = l.cropB }
                return a
            }) { [weak i] in i?.monitorFrame() }
        } else {
            Color.black.opacity(0.5)
        }
    }
}

/// Background / foreground pictures for the preview drawing (read once per path).
enum MLImageCache {
    private static var store: [String: NSImage] = [:]
    static func image(_ path: String) -> NSImage? {
        guard !path.isEmpty else { return nil }
        if let i = store[path] { return i }
        let i = NSImage(contentsOfFile: (path as NSString).expandingTildeInPath)
        if let i { store[path] = i }
        return i
    }
}

/// Drop an input (dragged from the list) on the box under the pointer.
private struct MLBoxDrop: DropDelegate {
    let ml: MultiLayoutInput
    let scene: Int
    let isLive: Bool
    let size: CGSize
    @Binding var box: Int
    @Binding var target: Int?

    private func boxAt(_ p: CGPoint) -> Int? {
        guard size.width > 0, size.height > 0, ml.multiLayout.scenes.indices.contains(scene) else { return nil }
        return ml.multiLayout.scenes[scene].box(atX: Double(p.x / size.width), y: Double(p.y / size.height))
    }
    func validateDrop(info: DropInfo) -> Bool { info.hasItemsConforming(to: [.utf8PlainText, .plainText]) }
    func dropUpdated(info: DropInfo) -> DropProposal? {
        let k = boxAt(info.location)
        if target != k { target = k }
        return DropProposal(operation: k == nil ? .forbidden : .copy)
    }
    func dropExited(info: DropInfo) { target = nil }
    func performDrop(info: DropInfo) -> Bool {
        target = nil
        guard let k = boxAt(info.location),
              let provider = info.itemProviders(for: [.utf8PlainText, .plainText]).first else { return false }
        let ml = ml, scene = scene, isLive = isLive, box = $box
        _ = provider.loadObject(ofClass: NSString.self) { obj, _ in
            guard let s = obj as? String, let id = UUID(uuidString: s.trimmingCharacters(in: .whitespacesAndNewlines)) else { return }
            DispatchQueue.main.async {
                // live: the box's input; preview: this scene's own input for the box (nothing on air changes)
                if isLive { ml.setInput(id, box: k) } else if ml.multiLayout.scenes.indices.contains(scene) {
                    ml.multiLayout.scenes[scene].boxes[k].input = id
                }
                box.wrappedValue = k
            }
        }
        return true
    }
}
