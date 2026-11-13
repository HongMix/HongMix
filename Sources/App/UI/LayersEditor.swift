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
    @ViewState private var trimAvailable: [UUID: Bool] = [:]
    @ViewState private var trimNote: [UUID: String] = [:]
    /// "Copy position" (shared between inputs, like vMix's Layer Designer copy / paste)
    static var clipboard: InputLayer?
    /// Screenshots (SnapshotView "layers-<n>"): open with layer 1 selected.
    var previewCropMode = false

    private var target: Binding<PlacementTarget> {
        Binding(get: { selected.map { .layer($0) } ?? .input },
                set: { t in if case .layer(let id) = t { selected = id } })
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
                    if let k = input.layers.firstIndex(where: { $0.id == selected }) { detailPanel(k) }
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
            PlacementCanvas(input: input, target: target, layersView: true)
                .frame(maxWidth: .infinity)
        }
        .padding(.vertical, 6)
        .onAppear {
            if previewCropMode || selected == nil { selected = input.layers.first?.id }
        }
    }

    private var candidates: [InputSource] { engine.inputs.filter { $0.id != input.id && $0.kind != .audio } }

    @ViewBuilder private func row(_ k: Int) -> some View {
        let l = input.layers[k]
        let lid = l.id   // bindings look the layer up by id: safe if it is removed while a field is focused
        HStack(spacing: 6) {
            Text("\(k + 1)").font(.system(size: 11, weight: .bold).monospacedDigit()).frame(width: 18)
                .foregroundColor(selected == l.id ? .yellow : .primary)
                .contentShape(Rectangle()).onTapGesture { selected = l.id }
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
            Button { selected = l.id } label: { Image(systemName: "scope") }.buttonStyle(.borderless)
            Button {
                guard k > 0 else { return }
                PlacementHistory.push(input)
                input.layers.swapAt(k, k - 1)
            } label: { Image(systemName: "arrow.up") }.buttonStyle(.borderless).disabled(k == 0)
            Button(role: .destructive) { PlacementHistory.push(input); input.layers.remove(at: k) } label: { Image(systemName: "trash") }
                .buttonStyle(.borderless)
        }
        .padding(4)
        .background(selected == l.id ? Color.yellow.opacity(0.12) : Color.clear)
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
                }
                .controlSize(.small)

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
                cropRow(L("왼쪽"), $input.layers[layer: lid].cropL)
                cropRow(L("오른쪽"), $input.layers[layer: lid].cropR)
                cropRow(L("위"), $input.layers[layer: lid].cropT)
                cropRow(L("아래"), $input.layers[layer: lid].cropB)
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

    private func hint(_ s: String) -> some View {
        Text(s).font(.caption).foregroundColor(.secondary).fixedSize(horizontal: false, vertical: true)
    }

    private func cropRow(_ label: String, _ v: Binding<Float>) -> some View {
        HStack(spacing: 4) {
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
