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

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            VStack(alignment: .leading, spacing: 8) {
                LayersCanvas(input: input, selected: $selected)
                    .frame(width: 400, height: 225)
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
                    Slider(value: $gap, in: 0...0.04).frame(width: 110)
                    Text(L("테두리")).font(.caption)
                    Slider(value: $border, in: 0...12, step: 1).frame(width: 90)
                    Button(L("모든 칸에")) {
                        for k in input.layers.indices { input.layers[k].border = border }
                    }
                    .controlSize(.small)
                }
                Text(L("템플릿을 고르면 간격·테두리가 적용됩니다. 칸을 드래그해 옮기고 노란 모서리로 크기를 바꿉니다."))
                    .font(.caption).foregroundColor(.secondary)
            }
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(Lf("레이어 (%@/10)", "\(input.layers.count)")).font(.subheadline.bold())
                    Spacer()
                    Button { add() } label: { Image(systemName: "plus") }.disabled(input.layers.count >= 10)
                    Button(L("모두 지우기"), role: .destructive) { input.layers = [] }.disabled(input.layers.isEmpty)
                }
                ScrollView {
                    VStack(spacing: 4) {
                        ForEach(Array(input.layers.enumerated()), id: \.element.id) { k, _ in row(k) }
                    }
                }
            }
        }
        .padding(.vertical, 6)
    }

    private var candidates: [InputSource] { engine.inputs.filter { $0.id != input.id && $0.kind != .audio } }

    @ViewBuilder private func row(_ k: Int) -> some View {
        let l = input.layers[k]
        HStack(spacing: 6) {
            Text("\(k + 1)").font(.system(size: 11, weight: .bold).monospacedDigit()).frame(width: 18)
                .foregroundColor(selected == l.id ? .yellow : .primary)
            Toggle("", isOn: $input.layers[k].visible).labelsHidden().toggleStyle(.checkbox)
            Picker("", selection: $input.layers[k].inputID) {
                Text(L("없음")).tag(UUID?.none)
                ForEach(candidates) { i in Text("\(engine.number(of: i)). \(i.name)").tag(UUID?.some(i.id)) }
            }
            .labelsHidden()
            .frame(width: 170)
            Picker("", selection: $input.layers[k].fill) {
                Text(L("채우기")).tag(true)
                Text(L("맞추기")).tag(false)
            }
            .labelsHidden().frame(width: 76)
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

/// Live preview of the composed input with draggable layer boxes.
private struct LayersCanvas: View {
    @ObservedObject var input: InputSource
    @Binding var selected: UUID?
    @ViewState private var start: InputLayer? = nil

    var body: some View {
        GeometryReader { g in
            let size = g.size
            ZStack(alignment: .topLeading) {
                Color.black
                MonitorView(fps: 30) { input.currentFrame() }
                ForEach(Array(input.layers.enumerated()), id: \.element.id) { k, l in
                    let r = CGRect(x: l.x * size.width, y: l.y * size.height, width: l.w * size.width, height: l.h * size.height)
                    let sel = selected == l.id
                    ZStack(alignment: .topLeading) {
                        Rectangle().fill(Color.yellow.opacity(sel ? 0.1 : 0.001))
                        Rectangle().stroke(sel ? Color.yellow : Color.white.opacity(0.5),
                                           style: StrokeStyle(lineWidth: sel ? 2 : 1, dash: sel ? [] : [4, 3]))
                        Text("\(k + 1)").font(.system(size: 10, weight: .bold)).foregroundColor(.black)
                            .padding(.horizontal, 3).background(sel ? Color.yellow : Color.white.opacity(0.8))
                    }
                    .frame(width: max(6, r.width), height: max(6, r.height))
                    .offset(x: r.minX, y: r.minY)
                    .gesture(move(k, size))
                    .onTapGesture { selected = l.id }
                    if sel {
                        Rectangle().fill(Color.yellow).frame(width: 9, height: 9)
                            .offset(x: r.maxX - 4.5, y: r.maxY - 4.5)
                            .gesture(resize(k, size))
                    }
                }
            }
            .clipped()
        }
    }

    private func move(_ k: Int, _ size: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 1)
            .onChanged { v in
                guard input.layers.indices.contains(k) else { return }
                if start == nil { start = input.layers[k]; selected = input.layers[k].id }
                guard let l0 = start else { return }
                input.layers[k].x = snap(l0.x + Double(v.translation.width / size.width), l0.w)
                input.layers[k].y = snap(l0.y + Double(v.translation.height / size.height), l0.h)
            }
            .onEnded { _ in start = nil }
    }

    private func resize(_ k: Int, _ size: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 1)
            .onChanged { v in
                guard input.layers.indices.contains(k) else { return }
                if start == nil { start = input.layers[k] }
                guard let l0 = start else { return }
                // keep 16:9 boxes 16:9 (aspect of the box in frame fractions stays the same)
                let s = max(0.03, l0.w + Double(v.translation.width / size.width)) / max(0.0001, l0.w)
                input.layers[k].w = l0.w * s
                input.layers[k].h = l0.h * s
            }
            .onEnded { _ in start = nil }
    }

    /// snap position (left/top edge or far edge) to 0, centre, 1
    private func snap(_ v: Double, _ len: Double) -> Double {
        for t in [0.0, 0.5 - len / 2, 1 - len] where abs(v - t) < 0.01 { return t }
        return v
    }
}
