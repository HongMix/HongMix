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
                        Button { add() } label: { Image(systemName: "plus") }.disabled(input.layers.count >= 10)
                        Button(L("모두 지우기"), role: .destructive) { input.layers = [] }.disabled(input.layers.isEmpty)
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
                            ForEach(LayerLayout.allCases) { l in Button(l.label) { apply(l) } }
                        }
                        .fixedSize()
                        Button(L("입력 자동 배치")) { autoAssign() }
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
        HStack(spacing: 6) {
            Text("\(k + 1)").font(.system(size: 11, weight: .bold).monospacedDigit()).frame(width: 18)
                .foregroundColor(selected == l.id ? .yellow : .primary)
                .contentShape(Rectangle()).onTapGesture { selected = l.id }
            Toggle("", isOn: $input.layers[k].visible).labelsHidden().toggleStyle(.checkbox)
            Picker("", selection: $input.layers[k].inputID) {
                Text(L("없음")).tag(UUID?.none)
                ForEach(candidates) { i in Text("\(engine.number(of: i)). \(i.name)").tag(UUID?.some(i.id)) }
            }
            .labelsHidden()
            .frame(minWidth: 90, idealWidth: 170, maxWidth: 170)
            Picker("", selection: $input.layers[k].fill) {
                Text(L("채우기")).tag(true)
                Text(L("맞추기")).tag(false)
            }
            .labelsHidden().frame(minWidth: 64, idealWidth: 76, maxWidth: 76)
            .help(L("채우기: 칸을 꽉 채우고 넘치는 부분은 잘라냄 · 맞추기: 전체가 보이게 (여백 생김)"))
            Button { selected = l.id } label: { Image(systemName: "scope") }.buttonStyle(.borderless)
            Button {
                guard k > 0 else { return }
                input.layers.swapAt(k, k - 1)
            } label: { Image(systemName: "arrow.up") }.buttonStyle(.borderless).disabled(k == 0)
            Button(role: .destructive) { input.layers.remove(at: k) } label: { Image(systemName: "trash") }
                .buttonStyle(.borderless)
        }
        .padding(4)
        .background(selected == l.id ? Color.yellow.opacity(0.12) : Color.clear)
        .clipShape(RoundedRectangle(cornerRadius: 4))
    }

    /// The selected layer in numbers (pixels of the output) + crop + "trim transparent edges".
    @ViewBuilder private func detailPanel(_ k: Int) -> some View {
        let W = Double(engine.format.width), H = Double(engine.format.height)
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(Lf("레이어 %@", "\(k + 1)")).font(.caption.bold())
                Spacer()
                Button(L("투명 여백 자동 자르기")) { trim(k) }
                    .controlSize(.small)
                    .help(L("그래픽(PNG·자막)의 투명한 부분을 잘라 실제 그림만 남깁니다. 채우기와 함께 쓰면 칸을 그림으로 꽉 채웁니다."))
                Button(L("초기화")) {
                    input.layers[k].cropL = 0; input.layers[k].cropT = 0
                    input.layers[k].cropR = 0; input.layers[k].cropB = 0
                }
                .controlSize(.small)
            }
            Grid(alignment: .leading, horizontalSpacing: 6, verticalSpacing: 3) {
                GridRow {
                    pxField("X", Binding(get: { input.layers[k].x * W }, set: { input.layers[k].x = $0 / W }))
                    pxField("Y", Binding(get: { input.layers[k].y * H }, set: { input.layers[k].y = $0 / H }))
                }
                GridRow {
                    pxField(L("너비"), Binding(get: { input.layers[k].w * W }, set: { input.layers[k].w = max(8, $0) / W }))
                    pxField(L("높이"), Binding(get: { input.layers[k].h * H }, set: { input.layers[k].h = max(8, $0) / H }))
                }
                GridRow {
                    cropSlider(L("왼쪽"), $input.layers[k].cropL)
                    cropSlider(L("오른쪽"), $input.layers[k].cropR)
                }
                GridRow {
                    cropSlider(L("위"), $input.layers[k].cropT)
                    cropSlider(L("아래"), $input.layers[k].cropB)
                }
            }
        }
        .padding(6)
        .background(Color.yellow.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 4))
    }

    private func pxField(_ label: String, _ v: Binding<Double>) -> some View {
        HStack(spacing: 4) {
            Text(label).font(.caption).frame(width: 40, alignment: .leading)
            TextField("", value: v, format: .number.precision(.fractionLength(0)))
                .textFieldStyle(.roundedBorder).frame(width: 70)
            Text("px").font(.caption).foregroundColor(.secondary)
        }
    }

    private func trim(_ k: Int) {
        guard let id = input.layers[k].inputID, let src = engine.inputs.first(where: { $0.id == id }),
              let c = AlphaTrim.crop(of: src) else {
            engine.lastMessage = L("투명 여백을 찾지 못했습니다 (투명 배경이 있는 그래픽에서만 됩니다)")
            return
        }
        input.layers[k].cropL = c.0; input.layers[k].cropT = c.1; input.layers[k].cropR = c.2; input.layers[k].cropB = c.3
    }

    private func cropSlider(_ label: String, _ v: Binding<Float>) -> some View {
        HStack(spacing: 4) {
            Text(label).font(.caption).frame(width: 40, alignment: .leading)
            Slider(value: Binding(get: { Double(v.wrappedValue) }, set: { v.wrappedValue = Float($0) }), in: 0...0.9)
                .controlSize(.small)
            Text("\(Int((v.wrappedValue * 100).rounded()))%").font(.caption.monospacedDigit()).frame(width: 32, alignment: .trailing)
        }
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
