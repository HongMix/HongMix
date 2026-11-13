import SwiftUI

/// Input Settings › Layers (vMix Layers / MultiView): up to 10 inputs on top of this one.
/// Pick a template (2/3/4/9/16 split, 1+3, 1+5, PIP …), choose the input for each box, then drag the
/// boxes in the preview to fine-tune (corner = resize).
struct LayersEditor: View {
    @EnvironmentObject var engine: SwitcherEngine
    @ObservedObject var input: InputSource
    @ViewState private var gap: Double = 0.01
    @ViewState private var border: Double = 0
    @ViewState private var selected: UUID? = nil
    /// Two or more selected layers (⇧-click / ⌘A); first = selected first. Empty = single selection.
    @ViewState private var group: [UUID] = []
    @ViewState private var alignRef: AlignReference = .selection
    @ObservedObject private var presets = LayerPresetStore.shared
    @ViewState private var trimAvailable: [UUID: Bool] = [:]
    @ViewState private var trimNote: [UUID: String] = [:]
    /// "Copy position" (shared between inputs, like vMix's Layer Designer copy / paste)
    static var clipboard: InputLayer?
    /// Screenshots (SnapshotView "layers-<n>"): open with layer 1 selected.
    var previewCropMode = false
    /// Screenshots (SnapshotView "props-<n>-6-all"): the next Layers editor opens with every layer selected.
    static var snapshotSelectAll = false

    private var target: Binding<PlacementTarget> {
        Binding(get: { selected.map { .layer($0) } ?? .input },
                set: { t in if case .layer(let id) = t { selected = id } })
    }

    /// Selected layers that still exist, when two or more are selected.
    private var multi: [UUID] {
        let g = group.filter { id in input.layers.contains { $0.id == id } }
        return g.count > 1 ? g : []
    }

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            // left: list and values (scrolls) · right: the live picture (stays in view)
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text(Lf("레이어 (%@/10)", "\(input.layers.count)")).font(.subheadline.bold())
                        Spacer()
                        Button { PlacementHistory.push(input); add() } label: { Image(systemName: "plus") }.disabled(input.layers.count >= 10)
                        Button(L("모두 지우기"), role: .destructive) { PlacementHistory.push(input); input.layers = [] }.disabled(input.layers.isEmpty)
                    }
                    if input.layers.isEmpty {
                        Text(L("레이어가 없습니다. ＋를 눌러 입력을 올리거나, 아래에서 템플릿을 고르세요."))
                            .font(.caption).foregroundColor(.secondary)
                    }
                    ForEach(Array(input.layers.enumerated()), id: \.element.id) { k, _ in row(k) }
                    if !input.layers.isEmpty {
                        hint(L("⇧ 클릭 = 여러 레이어 선택 (목록·미리보기), ⌘A = 모두 선택. 함께 끌고 화살표 키로 함께 움직입니다."))
                    }
                    if multi.count > 1 {
                        multiPanel(multi)
                    } else if let k = input.layers.firstIndex(where: { $0.id == selected }) {
                        detailPanel(k)
                    }
                    Divider()
                    HStack {
                        Menu(L("템플릿 적용")) {
                            ForEach(LayerLayout.allCases) { l in Button(l.label) { PlacementHistory.push(input); apply(l) } }
                        }
                        .fixedSize()
                        Button(L("입력 자동 배치")) { PlacementHistory.push(input); autoAssign() }
                            .help(L("비어 있는 칸에 입력 1, 2, 3… 순서로 넣습니다"))
                    }
                    HStack {
                        Text(L("간격")).font(.caption)
                        Slider(value: $gap, in: 0...0.04).frame(width: 100)
                        Text(L("테두리")).font(.caption)
                        Slider(value: $border, in: 0...12, step: 1).frame(width: 80)
                        Button(L("모든 칸에")) {
                            for k in input.layers.indices { input.layers[k].border = border }
                        }
                        .controlSize(.small)
                    }
                }
                .padding(.trailing, 6)
            }
            .frame(width: 400)
            PlacementCanvas(input: input, target: target, layersView: true, group: $group)
                .frame(maxWidth: .infinity)
        }
        .padding(.vertical, 6)
        .onAppear {
            if previewCropMode || selected == nil { selected = input.layers.first?.id }
            if Self.snapshotSelectAll {
                Self.snapshotSelectAll = false
                group = input.layers.count > 1 ? input.layers.map(\.id) : []
            }
        }
    }

    private var candidates: [InputSource] { engine.inputs.filter { $0.id != input.id && $0.kind != .audio } }

    @ViewBuilder private func row(_ k: Int) -> some View {
        let l = input.layers[k]
        let lid = l.id   // bindings look the layer up by id: safe if it is removed while a field is focused
        HStack(spacing: 6) {
            Text("\(k + 1)").font(.system(size: 11, weight: .bold).monospacedDigit()).frame(width: 18)
                .foregroundColor(isSelected(l.id) ? .yellow : .primary)
                .contentShape(Rectangle()).onTapGesture { pick(l.id) }
            Toggle("", isOn: $input.layers[layer: lid].visible).labelsHidden().toggleStyle(.checkbox)
            Picker("", selection: $input.layers[layer: lid].inputID) {
                Text(L("없음")).tag(UUID?.none)
                ForEach(candidates) { i in Text("\(engine.number(of: i)). \(i.name)").tag(UUID?.some(i.id)) }
            }
            .labelsHidden()
            .frame(minWidth: 90, idealWidth: 170, maxWidth: 170)
            Picker("", selection: $input.layers[layer: lid].fill) {
                Text(L("채우기")).tag(true)
                Text(L("맞추기")).tag(false)
            }
            .labelsHidden().frame(minWidth: 64, idealWidth: 76, maxWidth: 76)
            .help(L("채우기: 칸을 꽉 채우고 넘치는 부분은 잘라냄 · 맞추기: 전체가 보이게 (여백 생김)"))
            Button { pick(l.id) } label: { Image(systemName: "scope") }.buttonStyle(.borderless)
                .help(L("선택 (⇧ 누르고 클릭 = 여러 개 선택)"))
            Button {
                guard k > 0 else { return }
                PlacementHistory.push(input)
                input.layers.swapAt(k, k - 1)
            } label: { Image(systemName: "arrow.up") }.buttonStyle(.borderless).disabled(k == 0)
            Button(role: .destructive) { PlacementHistory.push(input); input.layers.remove(at: k) } label: { Image(systemName: "trash") }
                .buttonStyle(.borderless)
        }
        .padding(4)
        .background(isSelected(l.id) ? Color.yellow.opacity(0.12) : Color.clear)
        .clipShape(RoundedRectangle(cornerRadius: 4))
    }

    /// The selected layer: px position / size with ± and arrow keys, opacity, rotation, crop, alignment
    /// helpers and "trim transparent background" — each with a one-line explanation (vMix Layer Designer).
    @ViewBuilder private func detailPanel(_ k: Int) -> some View {
        let W = Double(engine.format.width), H = Double(engine.format.height)
        let l = input.layers[k]
        let lid = l.id   // bindings look the layer up by id: safe if it is removed while a field is focused
        let edit = { PlacementHistory.push(input, coalesce: true) }
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text(Lf("레이어 %@", "\(k + 1)")).font(.caption.bold())
                Spacer()
                Toggle(isOn: Binding(get: { input.layers[layer: lid].locked }, set: { v in edit(); input.layers[layer: lid].locked = v })) {
                    Label(L("잠금"), systemImage: l.locked ? "lock.fill" : "lock.open")
                }
                .toggleStyle(.button).controlSize(.small)
                .help(L("잠그면 마우스·화살표 키로 실수로 움직이지 않습니다"))
            }
            Group {
                Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 3) {
                    GridRow {
                        StepperField(label: "X", value: Binding(get: { input.layers[layer: lid].x * W }, set: { input.layers[layer: lid].x = $0 / W }),
                                     range: -4 * W...5 * W, unit: "px", labelWidth: 44, onEdit: edit)
                        StepperField(label: "Y", value: Binding(get: { input.layers[layer: lid].y * H }, set: { input.layers[layer: lid].y = $0 / H }),
                                     range: -4 * H...5 * H, unit: "px", labelWidth: 44, onEdit: edit)
                    }
                    GridRow {
                        StepperField(label: L("너비"), value: Binding(get: { input.layers[layer: lid].w * W }, set: { input.layers[layer: lid].w = max(8, $0) / W }),
                                     range: 8...(W * 4), unit: "px", labelWidth: 44, onEdit: edit)
                        StepperField(label: L("높이"), value: Binding(get: { input.layers[layer: lid].h * H }, set: { input.layers[layer: lid].h = max(8, $0) / H }),
                                     range: 8...(H * 4), unit: "px", labelWidth: 44, onEdit: edit)
                    }
                }
                hint(L("숫자를 넣으면 바로 적용돼요. 칸 위에서 ↑↓ = 1px, ⇧+↑↓ = 10px, ± 버튼을 ⇧ 누르고 클릭 = 10px."))
                HStack(spacing: 4) {
                    Button(L("화면에 맞추기")) { edit(); fitInside(k) }
                        .help(L("화면 밖으로 나간 상자를 비율 그대로 줄이고 옮겨 화면 안에 넣습니다"))
                    Button(L("가운데")) {
                        edit(); input.layers[layer: lid].x = (1 - input.layers[layer: lid].w) / 2; input.layers[layer: lid].y = (1 - input.layers[layer: lid].h) / 2
                    }
                    .help(L("상자를 화면 한가운데로 옮깁니다"))
                    Button(L("원래 비율")) { edit(); sourceAspect(k) }
                        .help(L("상자 높이를 소스 화면의 비율(자르기 반영)에 맞춥니다 — 채우기에서 잘리는 부분이 없어집니다"))
                    Button(L("전체 화면")) {
                        edit(); input.layers[layer: lid].x = 0; input.layers[layer: lid].y = 0; input.layers[layer: lid].w = 1; input.layers[layer: lid].h = 1
                    }
                    .help(L("상자를 출력 화면 전체 크기로 만듭니다"))
                }
                .controlSize(.small)
                HStack(spacing: 4) {
                    Button(L("위치 복사")) { Self.clipboard = input.layers[layer: lid] }
                        .help(L("이 레이어의 위치·크기·자르기·회전을 기억합니다"))
                    Button(L("붙여넣기")) {
                        guard let c = Self.clipboard else { NSSound.beep(); return }
                        edit()
                        input.layers[layer: lid].x = c.x; input.layers[layer: lid].y = c.y; input.layers[layer: lid].w = c.w; input.layers[layer: lid].h = c.h
                        input.layers[layer: lid].cropL = c.cropL; input.layers[layer: lid].cropT = c.cropT
                        input.layers[layer: lid].cropR = c.cropR; input.layers[layer: lid].cropB = c.cropB
                        input.layers[layer: lid].rotation = c.rotation
                    }
                    .help(L("복사한 위치·크기·자르기·회전을 이 레이어에 넣습니다 (다른 입력의 레이어에도 됩니다)"))
                    presetMenu(lid)
                }
                .controlSize(.small)
                hint(L("프리셋: 자주 쓰는 배치(위치·크기·자르기·회전·불투명도·테두리)를 이름 붙여 저장합니다. 앱 전체에 저장돼 다른 입력·다른 프로젝트에서도 쓸 수 있고, 레이어에 들어간 입력은 바꾸지 않습니다."))

                Divider().padding(.vertical, 2)
                Grid(alignment: .leading, horizontalSpacing: 6, verticalSpacing: 3) {
                    GridRow {
                        Text(L("불투명도")).font(.caption).foregroundColor(.secondary)
                        Slider(value: Binding(get: { Double(input.layers[layer: lid].opacity) * 100 }, set: { input.layers[layer: lid].opacity = Float($0 / 100) }),
                               in: 0...100) { e in if e { PlacementHistory.push(input) } }
                            .controlSize(.small)
                        StepperField(label: "", value: Binding(get: { Double(input.layers[layer: lid].opacity) * 100 },
                                                               set: { input.layers[layer: lid].opacity = Float($0 / 100) }),
                                     step: 1, bigStep: 10, range: 0...100, unit: "%", onEdit: edit)
                    }
                    GridRow {
                        Text(L("회전")).font(.caption).foregroundColor(.secondary)
                        Slider(value: $input.layers[layer: lid].rotation, in: -180...180) { e in if e { PlacementHistory.push(input) } }
                            .controlSize(.small)
                        StepperField(label: "", value: $input.layers[layer: lid].rotation, step: 1, bigStep: 15, decimals: 1,
                                     range: -180...180, unit: "°", onEdit: edit)
                    }
                }
                hint(L("회전은 상자 가운데를 기준으로 시계 방향입니다. 0°로 되돌리려면 숫자칸에 0을 넣으세요."))

                Divider().padding(.vertical, 2)
                HStack {
                    Text(L("자르기")).font(.caption.bold())
                    Spacer()
                    Button(L("초기화")) {
                        edit()
                        input.layers[layer: lid].cropL = 0; input.layers[layer: lid].cropT = 0
                        input.layers[layer: lid].cropR = 0; input.layers[layer: lid].cropB = 0
                    }
                    .controlSize(.small)
                }
                cropRow(L("왼쪽"), $input.layers[layer: lid].cropL, other: input.layers[layer: lid].cropR)
                cropRow(L("오른쪽"), $input.layers[layer: lid].cropR, other: input.layers[layer: lid].cropL)
                cropRow(L("위"), $input.layers[layer: lid].cropT, other: input.layers[layer: lid].cropB)
                cropRow(L("아래"), $input.layers[layer: lid].cropB, other: input.layers[layer: lid].cropT)
                hint(L("남은 부분이 상자를 채웁니다(채우기·맞추기 기준). 미리보기의 주황 손잡이를 끌면 그쪽 가장자리만 잘리고 그림 크기는 그대로입니다."))
            }
            .disabled(l.locked)

            Divider().padding(.vertical, 2)
            let trimmable = trimAvailable[l.id] ?? false
            Button(L("투명 배경만 잘라내기")) { edit(); trim(k) }
                .controlSize(.small)
                .disabled(!trimmable || l.locked)
            if let note = trimNote[l.id] {
                Label(note, systemImage: "checkmark.circle").font(.caption).foregroundColor(.green)
            } else if trimmable {
                hint(L("투명한 바깥 부분을 잘라 그림만 남깁니다. ‘채우기’와 함께 쓰면 그래픽이 상자를 꽉 채웁니다."))
            } else {
                Label(L("이 소스에는 투명한 부분이 없어서 쓸 수 없어요. 자막·PNG처럼 배경이 투명한 그래픽에서, 빈 부분을 잘라 상자를 그림으로 채울 때 씁니다."),
                      systemImage: "info.circle")
                    .font(.caption).foregroundColor(.orange).fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(6)
        .background(Color.yellow.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 4))
        .task(id: "\(l.id)|\(l.inputID?.uuidString ?? "")") {
            // re-check every second: the source may still be loading, or its picture may change
            while !Task.isCancelled {
                checkTrim(k)
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
        }
    }

    private func isSelected(_ id: UUID) -> Bool { selected == id || multi.contains(id) }

    /// Click = this layer only; ⇧-click = add to / remove from the selection.
    private func pick(_ id: UUID) {
        guard NSEvent.modifierFlags.contains(.shift) else { group = []; selected = id; return }
        var g = multi
        if g.isEmpty, let cur = selected, input.layers.contains(where: { $0.id == cur }) { g = [cur] }
        if let k = g.firstIndex(of: id) { g.remove(at: k) } else { g.append(id) }
        selected = g.first
        group = g.count > 1 ? g : []
    }

    // MARK: Presets (app-wide, LayerPresets.swift)

    private func presetMenu(_ lid: UUID) -> some View {
        let W = Double(engine.format.width), H = Double(engine.format.height)
        return Menu {
            if presets.items.isEmpty {
                Text(L("저장된 프리셋이 없습니다"))
            }
            ForEach(presets.items) { p in
                Button("\(p.name)  —  \(Int((p.w * W).rounded()))×\(Int((p.h * H).rounded()))") {
                    PlacementHistory.push(input)
                    p.apply(to: &input.layers[layer: lid])
                }
            }
            Divider()
            Button(L("현재 위치를 프리셋으로 저장…")) { savePreset(lid) }
            if !presets.items.isEmpty {
                Menu(L("이름 바꾸기")) {
                    ForEach(presets.items) { p in Button(p.name) { renamePreset(p) } }
                }
                Menu(L("삭제")) {
                    ForEach(presets.items) { p in Button(p.name, role: .destructive) { presets.remove(p.id) } }
                }
            }
        } label: {
            Label(L("프리셋"), systemImage: "bookmark")
        }
        .fixedSize()
        .help(L("저장해 둔 배치를 이 레이어에 적용하거나, 지금 배치를 저장합니다"))
    }

    private func askName(title: String, initial: String) -> String? {
        let a = NSAlert()
        a.messageText = title
        a.addButton(withTitle: L("저장"))
        a.addButton(withTitle: L("취소"))
        let f = NSTextField(string: initial)
        f.frame = NSRect(x: 0, y: 0, width: 260, height: 24)
        a.accessoryView = f
        a.window.initialFirstResponder = f
        guard a.runModal() == .alertFirstButtonReturn else { return nil }
        let n = f.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        return n.isEmpty ? nil : String(n.prefix(60))
    }

    private func savePreset(_ lid: UUID) {
        let l = input.layers[layer: lid]
        let W = Double(engine.format.width), H = Double(engine.format.height)
        let initial = Lf("프리셋 %@ (%@)", "\(presets.items.count + 1)", "\(Int((l.w * W).rounded()))×\(Int((l.h * H).rounded()))")
        guard let name = askName(title: L("프리셋 이름"), initial: initial) else { return }
        if presets.preset(named: name) != nil {
            let c = NSAlert()
            c.messageText = Lf("‘%@’ 프리셋이 이미 있습니다. 바꿀까요?", name)
            c.addButton(withTitle: L("바꾸기"))
            c.addButton(withTitle: L("취소"))
            guard c.runModal() == .alertFirstButtonReturn else { return }
        }
        presets.add(LayerPreset(name: name, from: l))
    }

    private func renamePreset(_ p: LayerPreset) {
        guard let name = askName(title: L("새 이름"), initial: p.name) else { return }
        if !presets.rename(p.id, to: name) {
            let c = NSAlert()
            c.messageText = Lf("‘%@’ 프리셋이 이미 있습니다. 바꿀까요?", name)
            c.informativeText = L("같은 이름의 프리셋은 하나만 둘 수 있습니다. 바꾸면 그 프리셋은 지워집니다.")
            c.addButton(withTitle: L("바꾸기"))
            c.addButton(withTitle: L("취소"))
            guard c.runModal() == .alertFirstButtonReturn else { return }
            if let other = presets.preset(named: name), other.id != p.id { presets.remove(other.id) }
            _ = presets.rename(p.id, to: name)
        }
    }

    // MARK: Several layers: align, distribute, same size

    enum AlignReference: String, CaseIterable, Identifiable {
        case selection, frame, first
        var id: String { rawValue }
        var label: String {
            switch self {
            case .selection: return L("선택한 상자들")
            case .frame: return L("화면")
            case .first: return L("처음 선택한 상자")
            }
        }
    }

    private enum AlignOp { case left, hCenter, right, top, vCenter, bottom }

    @ViewBuilder private func multiPanel(_ ids: [UUID]) -> some View {
        let locked = input.layers.filter { ids.contains($0.id) && $0.locked }.count
        VStack(alignment: .leading, spacing: 6) {
            Text(Lf("레이어 %@개 선택됨", "\(ids.count)")).font(.caption.bold())
            HStack {
                Text(L("기준")).font(.caption).foregroundColor(.secondary)
                Picker("", selection: $alignRef) {
                    ForEach(AlignReference.allCases) { r in Text(r.label).tag(r) }
                }
                .labelsHidden().fixedSize()
            }
            HStack(spacing: 4) {
                alignButton("align.horizontal.left", L("왼쪽 맞춤"), .left, ids)
                alignButton("align.horizontal.center", L("가로 가운데 맞춤"), .hCenter, ids)
                alignButton("align.horizontal.right", L("오른쪽 맞춤"), .right, ids)
                Divider().frame(height: 16)
                alignButton("align.vertical.top", L("위 맞춤"), .top, ids)
                alignButton("align.vertical.center", L("세로 가운데 맞춤"), .vCenter, ids)
                alignButton("align.vertical.bottom", L("아래 맞춤"), .bottom, ids)
            }
            HStack(spacing: 4) {
                Button { distribute(ids, horizontal: true) } label: {
                    Label(L("가로 간격 같게"), systemImage: "distribute.horizontal.center")
                }
                Button { distribute(ids, horizontal: false) } label: {
                    Label(L("세로 간격 같게"), systemImage: "distribute.vertical.center")
                }
            }
            .controlSize(.small)
            HStack(spacing: 4) {
                Menu(L("크기 같게")) {
                    Button(L("너비와 높이")) { sameSize(ids, w: true, h: true) }
                    Button(L("너비만")) { sameSize(ids, w: true, h: false) }
                    Button(L("높이만")) { sameSize(ids, w: false, h: true) }
                }
                .fixedSize()
                Text(L("처음 선택한 상자 크기로 맞춥니다")).font(.caption).foregroundColor(.secondary)
            }
            .controlSize(.small)
            hint(L("기준: ‘선택한 상자들’ = 선택한 상자 전체의 범위, ‘화면’ = 출력 화면, ‘처음 선택한 상자’ = 그 상자는 그대로. 간격 같게는 화면 기준이면 2개부터, 아니면 3개부터 됩니다. 잠긴 레이어는 움직이지 않습니다."))
            if locked > 0 {
                Label(Lf("잠긴 레이어 %@개는 그대로 둡니다", "\(locked)"), systemImage: "lock").font(.caption).foregroundColor(.orange)
            }
            Button(L("선택 해제")) { group = [] }.controlSize(.small)
        }
        .padding(6)
        .background(Color.yellow.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 4))
    }

    private func alignButton(_ icon: String, _ help: String, _ op: AlignOp, _ ids: [UUID]) -> some View {
        Button { align(ids, op) } label: { Image(systemName: icon).frame(width: 18) }
            .controlSize(.small)
            .help(help)
    }

    /// The rectangle to align to (fractions of the output).
    private func reference(_ ids: [UUID]) -> CGRect {
        let boxes = input.layers.filter { ids.contains($0.id) }.map { CGRect(x: $0.x, y: $0.y, width: $0.w, height: $0.h) }
        switch alignRef {
        case .frame: return CGRect(x: 0, y: 0, width: 1, height: 1)
        case .first:
            if let f = input.layers.first(where: { $0.id == ids.first }) { return CGRect(x: f.x, y: f.y, width: f.w, height: f.h) }
            return boxes.reduce(CGRect.null) { $0.union($1) }
        case .selection: return boxes.reduce(CGRect.null) { $0.union($1) }
        }
    }

    /// Layers that may move: selected, unlocked, and (for "first selected") not the reference itself.
    private func movable(_ ids: [UUID]) -> [Int] {
        input.layers.indices.filter { k in
            let l = input.layers[k]
            return ids.contains(l.id) && !l.locked && !(alignRef == .first && l.id == ids.first)
        }
    }

    private func align(_ ids: [UUID], _ op: AlignOp) {
        let r = reference(ids)
        let ks = movable(ids)
        guard !r.isNull, !ks.isEmpty else { NSSound.beep(); return }
        PlacementHistory.push(input)
        for k in ks {
            let l = input.layers[k]
            switch op {
            case .left: input.layers[k].x = r.minX
            case .hCenter: input.layers[k].x = r.midX - l.w / 2
            case .right: input.layers[k].x = r.maxX - l.w
            case .top: input.layers[k].y = r.minY
            case .vCenter: input.layers[k].y = r.midY - l.h / 2
            case .bottom: input.layers[k].y = r.maxY - l.h
            }
        }
    }

    /// Equal gaps between the boxes. Boxes that can't move are fixed points: locked layers, the first
    /// selected box with "First selected box", and the outermost boxes (or the frame edges with "Frame").
    /// The boxes between two fixed points are spaced evenly in that stretch.
    private func distribute(_ ids: [UUID], horizontal: Bool) {
        var ks = input.layers.indices.filter { ids.contains(input.layers[$0].id) }
        ks.sort { horizontal ? input.layers[$0].x < input.layers[$1].x : input.layers[$0].y < input.layers[$1].y }
        let pos = { (k: Int) -> Double in horizontal ? self.input.layers[k].x : self.input.layers[k].y }
        let len = { (k: Int) -> Double in horizontal ? self.input.layers[k].w : self.input.layers[k].h }
        let frame = alignRef == .frame
        guard ks.count >= (frame ? 2 : 3) else { NSSound.beep(); return }
        func fixed(_ k: Int) -> Bool {
            input.layers[k].locked || (alignRef == .first && input.layers[k].id == ids.first)
        }
        // fixed points: (start, end, index or nil for a frame edge)
        var anchors: [(Double, Double, Int?)] = []
        var runs: [[Int]] = [[]]
        if frame { anchors.append((0, 0, nil)) }
        for (n, k) in ks.enumerated() {
            let outer = !frame && (n == 0 || n == ks.count - 1)
            if fixed(k) || outer {
                anchors.append((pos(k), pos(k) + len(k), k)); runs.append([])
            } else {
                runs[runs.count - 1].append(k)
            }
        }
        if frame { anchors.append((1, 1, nil)) } else { runs.removeLast() }
        // runs[i] lies between anchors[i] and anchors[i + 1]
        guard runs.contains(where: { !$0.isEmpty }), anchors.count == runs.count + 1 else { NSSound.beep(); return }
        PlacementHistory.push(input)
        for (i, run) in runs.enumerated() where !run.isEmpty {
            let a = anchors[i].1, b = anchors[i + 1].0
            let gap = (b - a - run.map(len).reduce(0, +)) / Double(run.count + 1)
            var p = a + gap
            for k in run {
                if horizontal { input.layers[k].x = p } else { input.layers[k].y = p }
                p += len(k) + gap
            }
        }
    }

    /// Size of the layer selected first; top-left corners stay.
    private func sameSize(_ ids: [UUID], w: Bool, h: Bool) {
        guard let f = input.layers.first(where: { $0.id == ids.first }) else { return }
        let ks = input.layers.indices.filter { ids.contains(input.layers[$0].id) && !input.layers[$0].locked && input.layers[$0].id != f.id }
        guard !ks.isEmpty else { NSSound.beep(); return }
        PlacementHistory.push(input)
        for k in ks {
            if w { input.layers[k].w = f.w }
            if h { input.layers[k].h = f.h }
        }
    }

    private func hint(_ s: String) -> some View {
        Text(s).font(.caption).foregroundColor(.secondary).fixedSize(horizontal: false, vertical: true)
    }

    /// `other`: the opposite side — together they never cut more than 95 % (something must remain).
    private func cropRow(_ label: String, _ raw: Binding<Float>, other: Float) -> some View {
        let v = Binding<Float>(get: { raw.wrappedValue }, set: { raw.wrappedValue = max(0, min($0, 0.95 - other)) })
        return HStack(spacing: 4) {
            Text(label).font(.caption).foregroundColor(.secondary).frame(width: 40, alignment: .leading)
            Slider(value: Binding(get: { Double(v.wrappedValue) * 100 }, set: { v.wrappedValue = Float($0 / 100) }), in: 0...90) { e in
                if e { PlacementHistory.push(input) }
            }
            .controlSize(.small)
            StepperField(label: "", value: Binding(get: { Double(v.wrappedValue) * 100 }, set: { v.wrappedValue = Float($0 / 100) }),
                         step: 0.5, bigStep: 5, decimals: 1, range: 0...90, unit: "%",
                         onEdit: { PlacementHistory.push(input, coalesce: true) })
        }
    }

    private func checkTrim(_ k: Int) {
        guard input.layers.indices.contains(k) else { return }
        guard input.layers.indices.contains(k) else { return }
        let l = input.layers[k]
        let ok: Bool
        if let id = l.inputID, let src = engine.inputs.first(where: { $0.id == id }) {
            ok = AlphaTrim.crop(ifUseful: src) != nil
        } else {
            ok = false
        }
        if trimAvailable[l.id] != ok { trimAvailable[l.id] = ok }
    }

    private func trim(_ k: Int) {
        guard input.layers.indices.contains(k) else { return }
        guard let id = input.layers[k].inputID, let src = engine.inputs.first(where: { $0.id == id }),
              let c = AlphaTrim.crop(ifUseful: src) else {
            trimAvailable[input.layers[k].id] = false
            return
        }
        input.layers[k].cropL = c.0; input.layers[k].cropT = c.1; input.layers[k].cropR = c.2; input.layers[k].cropB = c.3
        trimNote[input.layers[k].id] = Lf("잘라냈어요 · 왼쪽 %@ 위 %@ 오른쪽 %@ 아래 %@",
                                          pct(c.0), pct(c.1), pct(c.2), pct(c.3))
    }

    private func pct(_ v: Float) -> String { String(format: "%.0f%%", v * 100) }

    /// Shrink (aspect kept) and move the box so all of it is inside the picture.
    private func fitInside(_ k: Int) {
        guard input.layers.indices.contains(k) else { return }
        var l = input.layers[k]
        let s = min(1, 1 / max(l.w, 0.0001), 1 / max(l.h, 0.0001))
        l.w *= s; l.h *= s
        l.x = min(max(0, l.x), 1 - l.w)
        l.y = min(max(0, l.y), 1 - l.h)
        input.layers[k] = l
    }

    /// Box height = source aspect (after crop), centre kept.
    private func sourceAspect(_ k: Int) {
        guard input.layers.indices.contains(k) else { return }
        let l = input.layers[k]
        guard let id = l.inputID, let src = engine.inputs.first(where: { $0.id == id }) else { NSSound.beep(); return }
        let st = src.video.stats
        guard st.width > 0, st.height > 0 else { NSSound.beep(); return }
        let W = Double(engine.format.width), H = Double(engine.format.height)
        let sa = Double(st.width) * Double(1 - l.cropL - l.cropR) / max(1, Double(st.height) * Double(1 - l.cropT - l.cropB))
        let cy = l.y + l.h / 2
        let h = l.w * W / max(0.01, sa) / H
        input.layers[k].h = h
        input.layers[k].y = cy - h / 2
    }

    private func add() {
        let n = input.layers.count
        var l = InputLayer(x: 0.6 - Double(n % 4) * 0.04, y: 0.6 - Double(n % 4) * 0.04, w: 0.3, h: 0.3)
        l.inputID = candidates.first { c in !input.layers.contains { $0.inputID == c.id } }?.id
        input.layers.append(l)
        selected = l.id
    }

    private func apply(_ layout: LayerLayout) {
        let rects = layout.rects(gap: gap)
        var out: [InputLayer] = []
        for (k, r) in rects.enumerated() {
            var l = k < input.layers.count ? input.layers[k] : InputLayer(x: 0, y: 0, w: 0, h: 0)
            l.x = r.0; l.y = r.1; l.w = r.2; l.h = r.3; l.fill = r.4; l.visible = true
            l.border = border
            out.append(l)
        }
        input.layers = out
        if out.allSatisfy({ $0.inputID == nil }) { autoAssign() }
    }

    private func autoAssign() {
        var pool = candidates.filter { c in !input.layers.contains { $0.inputID == c.id } }
        for k in input.layers.indices where input.layers[k].inputID == nil {
            guard !pool.isEmpty else { break }
            input.layers[k].inputID = pool.removeFirst().id
        }
    }
}

extension Array where Element == InputLayer {
    /// The layer with `id`; reading a removed layer gives a placeholder, writing to it does nothing.
    subscript(layer id: UUID) -> InputLayer {
        get { first { $0.id == id } ?? InputLayer(x: 0, y: 0, w: 0.5, h: 0.5) }
        set { if let i = firstIndex(where: { $0.id == id }) { self[i] = newValue } }
    }
}
