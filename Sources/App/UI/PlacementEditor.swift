import SwiftUI
import AppKit
import CoreVideo
import QuartzCore

/// What the placement canvas edits: the input's own Position (zoom / pan / crop), or one of its layers.
enum PlacementTarget: Equatable {
    case input
    case layer(UUID)
}

// MARK: - Undo (⌘Z) for Position and Layers

/// Undo history of an input's placement (Position values + layers), shared by the canvas, the number fields
/// and the sliders of Input Settings. Field edits and arrow-key nudges within 0.8 s count as one step.
enum PlacementHistory {
    private struct Snap { var adjust: VideoAdjust; var layers: [InputLayer] }
    private static var stacks: [UUID: [Snap]] = [:]
    private static var lastPush: [UUID: CFTimeInterval] = [:]

    static func push(_ i: InputSource, coalesce: Bool = false) {
        let now = CACurrentMediaTime()
        if coalesce, let t = lastPush[i.id], now - t < 0.8 { lastPush[i.id] = now; return }
        var s = stacks[i.id] ?? []
        let snap = Snap(adjust: i.adjust, layers: i.layers)
        if let last = s.last, last.adjust == snap.adjust, last.layers == snap.layers { lastPush[i.id] = now; return }
        s.append(snap)
        if s.count > 100 { s.removeFirst(s.count - 100) }
        stacks[i.id] = s
        lastPush[i.id] = now
    }

    static func undo(_ i: InputSource) {
        guard var s = stacks[i.id], let snap = s.popLast() else { NSSound.beep(); return }
        stacks[i.id] = s
        lastPush[i.id] = 0
        i.adjust = snap.adjust
        i.layers = snap.layers
    }
}

// MARK: - Number field with ± and arrow keys (vMix-style value entry)

/// A number field: type a value (applied while typing), ↑ / ↓ = one step, ⇧↑ / ⇧↓ = ten steps.
struct NudgeField: NSViewRepresentable {
    @Binding var value: Double
    var step: Double = 1
    var bigStep: Double = 10
    var decimals: Int = 0
    var range: ClosedRange<Double>? = nil
    var width: CGFloat = 56
    /// called before every change (undo)
    var onEdit: () -> Void = {}

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSTextField {
        let tf = NSTextField()
        tf.delegate = context.coordinator
        tf.alignment = .right
        tf.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        tf.bezelStyle = .roundedBezel
        tf.controlSize = .small
        tf.stringValue = format(value)
        tf.toolTip = L("숫자를 넣으면 바로 적용 · ↑↓ = 한 칸, ⇧+↑↓ = 열 칸")
        tf.translatesAutoresizingMaskIntoConstraints = false
        tf.widthAnchor.constraint(equalToConstant: width).isActive = true
        return tf
    }

    func updateNSView(_ tf: NSTextField, context: Context) {
        context.coordinator.parent = self
        if tf.currentEditor() == nil {
            let s = format(value)
            if tf.stringValue != s { tf.stringValue = s }
        }
    }

    func format(_ v: Double) -> String { String(format: "%.\(decimals)f", v) }

    func clamp(_ v: Double) -> Double {
        guard let r = range else { return v }
        return min(r.upperBound, max(r.lowerBound, v))
    }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: NudgeField
        init(_ p: NudgeField) { parent = p }

        func controlTextDidChange(_ n: Notification) {
            guard let tf = n.object as? NSTextField else { return }
            let t = tf.stringValue.replacingOccurrences(of: ",", with: ".")
                .trimmingCharacters(in: CharacterSet(charactersIn: " %°px"))
            guard let v = Double(t), v.isFinite else { return }
            parent.onEdit()
            parent.value = parent.clamp(v)
        }

        func controlTextDidEndEditing(_ n: Notification) {
            guard let tf = n.object as? NSTextField else { return }
            tf.stringValue = parent.format(parent.value)
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy sel: Selector) -> Bool {
            let d: Double
            switch sel {
            case #selector(NSResponder.moveUp(_:)): d = parent.step
            case #selector(NSResponder.moveDown(_:)): d = -parent.step
            case #selector(NSResponder.moveUpAndModifySelection(_:)): d = parent.bigStep
            case #selector(NSResponder.moveDownAndModifySelection(_:)): d = -parent.bigStep
            default: return false
            }
            parent.onEdit()
            let v = parent.clamp(parent.value + d)
            parent.value = v
            textView.string = parent.format(v)
            textView.selectAll(nil)
            return true
        }
    }
}

/// Label, −, number, +, unit. ⇧-click on − / + = ten steps.
struct StepperField: View {
    let label: String
    @Binding var value: Double
    var step: Double = 1
    var bigStep: Double = 10
    var decimals: Int = 0
    var range: ClosedRange<Double>? = nil
    var unit: String = ""
    var labelWidth: CGFloat = 40
    var onEdit: () -> Void = {}

    var body: some View {
        HStack(spacing: 2) {
            if !label.isEmpty {
                Text(label).font(.caption).foregroundColor(.secondary).frame(width: labelWidth, alignment: .leading)
            }
            bump("minus", -1)
            NudgeField(value: $value, step: step, bigStep: bigStep, decimals: decimals, range: range, onEdit: onEdit)
            bump("plus", 1)
            if !unit.isEmpty { Text(unit).font(.caption).foregroundColor(.secondary).frame(width: 18, alignment: .leading) }
        }
    }

    private func bump(_ icon: String, _ sign: Double) -> some View {
        Button {
            onEdit()
            let d = (NSEvent.modifierFlags.contains(.shift) ? bigStep : step) * sign
            var v = value + d
            if let r = range { v = min(r.upperBound, max(r.lowerBound, v)) }
            value = v
        } label: {
            Image(systemName: icon).font(.system(size: 9, weight: .bold)).frame(width: 14, height: 16)
        }
        .buttonStyle(.bordered)
        .controlSize(.mini)
        .help(L("⇧ 누르고 클릭 = 열 칸"))
    }
}

// MARK: - The canvas

/// Input Settings › Position and › Layers share this canvas (vMix Layer Designer + Position in one):
/// a fixed live preview on the right; in a single mode the selected box is moved by dragging inside,
/// resized from the yellow corners (aspect kept, ⇧ = free for layers), cropped from the orange edge handles,
/// and ⌥-drag inside slides the visible part. Green guides snap to centre, edges and the safe areas.
/// A grey margin around the picture keeps handles of boxes that stick out of the frame reachable.
/// Arrow keys move the selection by 1 px (⇧ = 10 px); ⌘Z undoes.
struct PlacementCanvas: View {
    @EnvironmentObject var engine: SwitcherEngine
    @ObservedObject var input: InputSource
    @Binding var target: PlacementTarget
    /// true = the input's own picture with its layers (Layers tab); false = the input as placed in Program.
    let layersView: Bool
    /// Layers tab: all selected layers when two or more are selected (first = the one selected first;
    /// `target` is then that one). Empty = single selection.
    var group: Binding<[UUID]> = .constant([])

    @ViewState private var startGroup: [InputLayer] = []
    @ViewState private var startAdjust: VideoAdjust? = nil
    @ViewState private var startRect: CGRect = .zero
    @ViewState private var startLayer: InputLayer? = nil
    @ViewState private var guides: [CGFloat] = []
    @FocusState private var focused: Bool

    /// margin around the picture, as a fraction of the picture width (each side)
    private static let margin: CGFloat = 0.08
    private var out: CGSize { CGSize(width: engine.format.width, height: engine.format.height) }
    private var me: EditableLayer { EditableLayer(input: input, label: input.name) }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            GeometryReader { g in
                let pw = g.size.width / (1 + 2 * Self.margin)
                let size = CGSize(width: pw, height: pw * 9 / 16)
                let m = pw * Self.margin
                ZStack(alignment: .topLeading) {
                    Color(white: 0.22)
                    picture(size).frame(width: size.width, height: size.height).clipped().offset(x: m, y: m)
                    Rectangle().stroke(Color.white.opacity(0.55), lineWidth: 1)
                        .frame(width: size.width, height: size.height).offset(x: m, y: m)
                        .allowsHitTesting(false)
                    editing(size).frame(width: size.width, height: size.height, alignment: .topLeading).offset(x: m, y: m)
                }
                .coordinateSpace(name: "placement")
                .clipped()
            }
            .aspectRatio((1 + 2 * Self.margin) / (9.0 / 16 + 2 * Self.margin), contentMode: .fit)
            .focusable()
            .focusEffectDisabled()
            .focused($focused)
            .onKeyPress(keys: [.upArrow, .downArrow, .leftArrow, .rightArrow], phases: [.down, .repeat]) { press in
                let n: CGFloat = press.modifiers.contains(.shift) ? 10 : 1
                switch press.key {
                case .upArrow: nudge(0, -n)
                case .downArrow: nudge(0, n)
                case .leftArrow: nudge(-n, 0)
                default: nudge(n, 0)
                }
                return .handled
            }
            // a drag whose handle disappeared mid-drag (selection changed) never ends: start fresh
            .onChange(of: groupIDs) { _, _ in startGroup = [] }
            .onChange(of: target) { _, _ in startLayer = nil }
            .onKeyPress(keys: ["a"], phases: .down) { press in
                // ⌘A: select every layer
                guard layersView, press.modifiers.contains(.command), !input.layers.isEmpty else { return .ignored }
                let ids = input.layers.map(\.id)
                target = .layer(ids[0])
                group.wrappedValue = ids.count > 1 ? ids : []
                return .handled
            }
            .overlay(alignment: .topTrailing) {
                if focused {
                    Text(L("화살표 키로 이동 중")).font(.caption2).padding(.horizontal, 5).padding(.vertical, 1)
                        .background(Color.accentColor.opacity(0.85)).foregroundColor(.white)
                        .clipShape(RoundedRectangle(cornerRadius: 3)).padding(4)
                        .allowsHitTesting(false)
                }
            }

            HStack(spacing: 12) {
                legend(Color.yellow.opacity(0.5), L("안쪽 끌기 = 이동"))
                legend(.yellow, L("모서리 = 크기"))
                legend(.orange, L("변 가운데 = 자르기"))
                Spacer()
                Button {
                    PlacementHistory.undo(input)
                } label: {
                    Label(L("되돌리기"), systemImage: "arrow.uturn.backward")
                }
                .controlSize(.small)
                .keyboardShortcut("z", modifiers: .command)
                .help(L("마지막 변경을 되돌립니다 (⌘Z)"))
            }
            Text(L("화면을 한 번 클릭한 뒤 ←→↑↓ = 1px 이동, ⇧+화살표 = 10px · ⌥ 끌기 = 보이는 부분 옮기기 · ⇧ 모서리 = 비율 무시 · 회색 여백 = 화면 밖"))
                .font(.caption).foregroundColor(.secondary).fixedSize(horizontal: false, vertical: true)
            Text(readout).font(.system(size: 11).monospacedDigit()).foregroundColor(.secondary)
            if let o = overflowText {
                Label(o, systemImage: "exclamationmark.triangle").font(.caption).foregroundColor(.orange)
            }
        }
    }

    @ViewBuilder private func picture(_ size: CGSize) -> some View {
        ZStack {
            Color.black
            if layersView {
                MonitorView(fps: 30) { [weak input] in input?.monitorFrame() }
            } else {
                MonitorView(fps: 30, placement: { [weak input] in input?.videoAdjust }) { [weak input] in input?.monitorFrame() }
            }
            Color.black.opacity(0.001)
                .onTapGesture { loc in
                    focused = true
                    select(at: CGPoint(x: loc.x / size.width, y: loc.y / size.height))
                }
        }
    }

    @ViewBuilder private func editing(_ size: CGSize) -> some View {
        ZStack(alignment: .topLeading) {
            if layersView {
                let multi = groupIDs
                ForEach(Array(input.layers.enumerated()), id: \.element.id) { k, l in
                    let r = CGRect(x: l.x, y: l.y, width: l.w, height: l.h)
                    box(r, size: size, label: "\(k + 1)", locked: l.locked,
                        selected: target == .layer(l.id) || multi.contains(l.id), rotation: l.rotation)
                        .onTapGesture { click(l.id) }
                }
                if multi.count > 1 {
                    // several layers: dashed outline of the whole selection; drag any selected box to move them all
                    let b = bounds(of: multi)
                    Rectangle().stroke(Color.yellow, style: StrokeStyle(lineWidth: 1, dash: [5, 4]))
                        .frame(width: max(6, b.width * size.width + 8), height: max(6, b.height * size.height + 8))
                        .offset(x: b.minX * size.width - 4, y: b.minY * size.height - 4)
                        .allowsHitTesting(false)
                    ForEach(input.layers.filter { multi.contains($0.id) && !$0.locked }, id: \.id) { l in
                        Rectangle().fill(Color.yellow.opacity(0.001))
                            .frame(width: max(6, l.w * size.width), height: max(6, l.h * size.height))
                            .rotationEffect(.degrees(l.rotation))
                            .offset(x: l.x * size.width, y: l.y * size.height)
                            .onTapGesture { click(l.id) }
                            .gesture(groupMove(size))
                    }
                } else if case .layer(let id) = target, let k = input.layers.firstIndex(where: { $0.id == id }), !input.layers[k].locked {
                    let l = input.layers[k]
                    handles(CGRect(x: l.x, y: l.y, width: l.w, height: l.h), size: size, rotation: l.rotation,
                            move: layerMove(k, size), corner: { c in layerResize(k, c, size) },
                            edge: { e in layerCrop(k, e, size) })
                }
            } else {
                let r = me.rect(out: out)
                box(r, size: size, label: nil, locked: false, selected: true, rotation: 0)
                handles(r, size: size, rotation: 0, move: inputMove(size), corner: { c in inputResize(c, size) },
                        edge: { e in inputCrop(e, size) })
            }
            ForEach(Array(guides.enumerated()), id: \.offset) { _, gv in
                if gv >= 0 {
                    Rectangle().fill(Color.green).frame(width: 1, height: size.height).offset(x: gv * size.width)
                } else {
                    Rectangle().fill(Color.green).frame(width: size.width, height: 1).offset(y: (-1 - gv) * size.height)
                }
            }
            .allowsHitTesting(false)
        }
    }

    // MARK: Drawing

    private func box(_ r: CGRect, size: CGSize, label: String?, locked: Bool, selected: Bool, rotation: Double) -> some View {
        ZStack(alignment: .topLeading) {
            Rectangle().fill(Color.yellow.opacity(selected ? 0.08 : 0.001))
            Rectangle().stroke(selected ? Color.yellow : Color.white.opacity(0.55),
                               style: StrokeStyle(lineWidth: selected ? 2 : 1, dash: selected && !locked ? [] : [4, 3]))
            if let label {
                HStack(spacing: 2) {
                    Text(label).font(.system(size: 10, weight: .bold))
                    if locked { Image(systemName: "lock.fill").font(.system(size: 8)) }
                }
                .foregroundColor(.black)
                .padding(.horizontal, 3).background(selected ? Color.yellow : Color.white.opacity(0.8))
            }
        }
        .frame(width: max(6, r.width * size.width), height: max(6, r.height * size.height))
        .rotationEffect(.degrees(rotation))
        .offset(x: r.minX * size.width, y: r.minY * size.height)
    }

    private enum Edge: CaseIterable { case left, right, top, bottom }

    @ViewBuilder
    private func handles<M: Gesture, C: Gesture, E: Gesture>(_ r: CGRect, size: CGSize, rotation: Double, move: M,
                                                          corner: @escaping (Int) -> C,
                                                          edge: @escaping (Edge) -> E) -> some View {
        let w = max(8, r.width * size.width), h = max(8, r.height * size.height)
        let ox = r.minX * size.width, oy = r.minY * size.height
        // a box far outside the frame: its handles stay at the edge of the grey margin, still grabbable
        // (dragging works on the movement, not the position, so a pinned handle behaves the same)
        let m = size.width * Self.margin - 7
        let pin = { (x: CGFloat, y: CGFloat) -> CGPoint in
            guard rotation == 0 else { return CGPoint(x: x, y: y) }
            return CGPoint(x: min(max(ox + x, -m), size.width + m) - ox, y: min(max(oy + y, -m), size.height + m) - oy)
        }
        ZStack(alignment: .topLeading) {
            // move / ⌥ slide area
            Rectangle().fill(Color.yellow.opacity(0.001)).frame(width: w, height: h).gesture(move)
            ForEach(0..<4, id: \.self) { c in
                let p = pin(c % 2 == 0 ? 0 : w, c < 2 ? 0 : h)
                Rectangle().fill(Color.yellow).frame(width: 11, height: 11)
                    .offset(x: p.x - 5.5, y: p.y - 5.5)
                    .gesture(corner(c))
            }
            ForEach(Edge.allCases, id: \.self) { e in
                let vertical = e == .left || e == .right
                let p = pin(e == .left ? 0 : (e == .right ? w : w / 2), e == .top ? 0 : (e == .bottom ? h : h / 2))
                RoundedRectangle(cornerRadius: 2).fill(Color.orange)
                    .frame(width: vertical ? 7 : 26, height: vertical ? 26 : 7)
                    .offset(x: p.x - (vertical ? 3.5 : 13), y: p.y - (vertical ? 13 : 3.5))
                    .gesture(edge(e))
            }
        }
        .frame(width: w, height: h, alignment: .topLeading)
        .rotationEffect(.degrees(rotation))
        .offset(x: r.minX * size.width, y: r.minY * size.height)
    }

    private func legend(_ c: Color, _ text: String) -> some View {
        HStack(spacing: 4) {
            RoundedRectangle(cornerRadius: 2).fill(c).frame(width: 10, height: 10)
            Text(text).font(.caption).foregroundColor(.secondary)
        }
    }

    /// Values in output pixels, like vMix's Layer Designer toolbar.
    private var readout: String {
        let W = out.width, H = out.height
        func px(_ r: CGRect) -> String {
            String(format: "X %.0f  Y %.0f  W %.0f  H %.0f px", r.minX * W, r.minY * H, r.width * W, r.height * H)
        }
        switch target {
        case .input:
            let a = input.adjust
            return px(me.rect(out: out)) + String(format: "  ·  Zoom %.2f  Pan %.2f / %.2f  ·  Crop L%.0f R%.0f T%.0f B%.0f %%",
                                                   a.zoom, a.panX, a.panY, a.cropL * 100, a.cropR * 100, a.cropT * 100, a.cropB * 100)
        case .layer(let id):
            if groupIDs.count > 1 {
                return Lf("레이어 %@개 선택됨", "\(groupIDs.count)") + "  ·  " + px(bounds(of: groupIDs))
            }
            guard let l = input.layers.first(where: { $0.id == id }) else { return "" }
            var s = px(CGRect(x: l.x, y: l.y, width: l.w, height: l.h))
                + String(format: "  ·  Crop L%.0f R%.0f T%.0f B%.0f %%", l.cropL * 100, l.cropR * 100, l.cropT * 100, l.cropB * 100)
            if l.opacity < 1 { s += String(format: "  ·  %.0f %%", l.opacity * 100) }
            if l.rotation != 0 { s += String(format: "  ·  %.1f°", l.rotation) }
            return s
        }
    }

    /// "Right 220 px, bottom 104 px outside" — so a box that grew past the frame isn't a mystery.
    private var overflowText: String? {
        let r: CGRect
        switch target {
        case .input: r = me.rect(out: out)
        case .layer(let id):
            guard let l = input.layers.first(where: { $0.id == id }) else { return nil }
            r = CGRect(x: l.x, y: l.y, width: l.w, height: l.h)
        }
        let W = out.width, H = out.height
        var parts: [String] = []
        if r.minX < -0.001 { parts.append(Lf("왼쪽 %@px", String(format: "%.0f", -r.minX * W))) }
        if r.maxX > 1.001 { parts.append(Lf("오른쪽 %@px", String(format: "%.0f", (r.maxX - 1) * W))) }
        if r.minY < -0.001 { parts.append(Lf("위 %@px", String(format: "%.0f", -r.minY * H))) }
        if r.maxY > 1.001 { parts.append(Lf("아래 %@px", String(format: "%.0f", (r.maxY - 1) * H))) }
        guard !parts.isEmpty else { return nil }
        return Lf("화면 밖: %@", parts.joined(separator: ", "))
    }

    private func select(at p: CGPoint) {
        guard layersView else { return }
        if let hit = input.layers.reversed().first(where: { CGRect(x: $0.x, y: $0.y, width: $0.w, height: $0.h).contains(p) }) {
            click(hit.id)
        } else if !shiftDown {
            group.wrappedValue = []
        }
    }

    /// Selected layers that still exist (two or more), else [].
    private var groupIDs: [UUID] {
        let g = group.wrappedValue.filter { id in input.layers.contains { $0.id == id } }
        return g.count > 1 ? g : []
    }

    /// Click = select only this layer; ⇧-click = add it to / remove it from the selection.
    private func click(_ id: UUID) {
        focused = true
        guard layersView, shiftDown else { group.wrappedValue = []; target = .layer(id); return }
        var g = groupIDs
        if g.isEmpty, case .layer(let cur) = target, input.layers.contains(where: { $0.id == cur }) { g = [cur] }
        if let k = g.firstIndex(of: id) { g.remove(at: k) } else { g.append(id) }
        if let first = g.first { target = .layer(first) }
        group.wrappedValue = g.count > 1 ? g : []
    }

    /// Bounding box of the given layers (unrotated boxes, fractions of the output).
    private func bounds(of ids: [UUID]) -> CGRect {
        input.layers.filter { ids.contains($0.id) }
            .map { CGRect(x: $0.x, y: $0.y, width: $0.w, height: $0.h) }
            .reduce(CGRect.null) { $0.union($1) }
    }

    /// Edges and centres of the other layers' boxes (snap targets while moving `moving`).
    private func layerTargets(excluding moving: [UUID]) -> (x: [CGFloat], y: [CGFloat]) {
        var xs: [CGFloat] = [], ys: [CGFloat] = []
        for l in input.layers where l.visible && !moving.contains(l.id) {
            xs += [l.x, l.x + l.w / 2, l.x + l.w]
            ys += [l.y, l.y + l.h / 2, l.y + l.h]
        }
        return (xs, ys)
    }

    /// Arrow keys: move the selection by output pixels.
    private func nudge(_ dx: CGFloat, _ dy: CGFloat) {
        switch target {
        case .input:
            // Layers tab with no layer selected: don't move the input itself (it is on air, no box shown)
            guard !layersView else { NSSound.beep(); return }
            PlacementHistory.push(input, coalesce: true)
            var a = input.adjust
            a.panX += Float(2 * dx / out.width)
            a.panY -= Float(2 * dy / out.height)
            input.adjust = a
        case .layer(let id):
            let ids = groupIDs.isEmpty ? [id] : groupIDs
            let ks = input.layers.indices.filter { ids.contains(input.layers[$0].id) && !input.layers[$0].locked }
            guard !ks.isEmpty else { NSSound.beep(); return }
            PlacementHistory.push(input, coalesce: true)
            for k in ks {
                input.layers[k].x += Double(dx / out.width)
                input.layers[k].y += Double(dy / out.height)
            }
        }
    }

    private var optionDown: Bool { NSEvent.modifierFlags.contains(.option) }
    private var shiftDown: Bool { NSEvent.modifierFlags.contains(.shift) }

    private func drag() -> DragGesture { DragGesture(minimumDistance: 1, coordinateSpace: .named("placement")) }

    // MARK: Input (Position): pan / zoom / crop — same maths as Program (EditableLayer, Mixer.metal)

    private func inputMove(_ size: CGSize) -> some Gesture {
        drag()
            .onChanged { v in
                if startAdjust == nil { PlacementHistory.push(input); focused = true; startAdjust = input.adjust; startRect = me.rect(out: out) }
                guard let a0 = startAdjust else { return }
                var dx = v.translation.width / size.width, dy = v.translation.height / size.height
                var a = a0
                if optionDown {
                    // slide the visible part: shift the crop window over the source, compensate the pan
                    let fw = fittedSize(a0).width * CGFloat(a0.zoom * a0.zoomX), fh = fittedSize(a0).height * CGFloat(a0.zoom * a0.zoomY)
                    var d = Float(-dx / max(0.0001, fw)), e = Float(-dy / max(0.0001, fh))
                    d = max(-a0.cropL, min(a0.cropR, d)); e = max(-a0.cropT, min(a0.cropB, e))
                    a.cropL = a0.cropL + d; a.cropR = a0.cropR - d
                    a.cropT = a0.cropT + e; a.cropB = a0.cropB - e
                    a.panX = a0.panX - Float(2 * fw) * d
                    a.panY = a0.panY + Float(2 * fh) * e
                    guides = []
                } else {
                    let r0 = startRect
                    let (sx, gx) = snap([r0.minX + dx, r0.midX + dx, r0.maxX + dx])
                    let (sy, gy) = snap([r0.minY + dy, r0.midY + dy, r0.maxY + dy])
                    dx += sx; dy += sy
                    guides = gx + gy.map { -1 - $0 }
                    a.panX = a0.panX + Float(dx * 2)
                    a.panY = a0.panY - Float(dy * 2)
                }
                input.adjust = a
            }
            .onEnded { _ in startAdjust = nil; guides = [] }
    }

    private func inputResize(_ c: Int, _ size: CGSize) -> some Gesture {
        drag()
            .onChanged { v in
                if startAdjust == nil { PlacementHistory.push(input); focused = true; startAdjust = input.adjust; startRect = me.rect(out: out) }
                guard let a0 = startAdjust else { return }
                let r0 = startRect
                let ax = c % 2 == 0 ? r0.maxX : r0.minX, ay = c < 2 ? r0.maxY : r0.minY
                let hx = (c % 2 == 0 ? r0.minX : r0.maxX) + v.translation.width / size.width
                let hy = (c < 2 ? r0.minY : r0.maxY) + v.translation.height / size.height
                let ratio = max(0.02, max(abs(hx - ax) / max(0.0001, r0.width), abs(hy - ay) / max(0.0001, r0.height)))
                let z = CGFloat(a0.zoom) * ratio
                // anchor corner stays put (EditableLayer.rect solved for pan)
                var tmp = a0; tmp.zoom = Float(z)
                let base = EditableLayer(input: input, label: "").baseRect(out: out)
                let bax = c % 2 == 0 ? base.maxX : base.minX, bay = c < 2 ? base.maxY : base.minY
                let zx = z * CGFloat(a0.zoomX), zy = z * CGFloat(a0.zoomY)
                tmp.panX = Float((ax - (bax - 0.5) * zx - 0.5) * 2)
                tmp.panY = Float(-(ay - (bay - 0.5) * zy - 0.5) * 2)
                input.adjust = tmp
            }
            .onEnded { _ in startAdjust = nil }
    }

    /// Crop a side; the rest of the picture stays where it is (vMix crop: no re-scaling).
    private func inputCrop(_ e: Edge, _ size: CGSize) -> some Gesture {
        drag()
            .onChanged { v in
                if startAdjust == nil { PlacementHistory.push(input); focused = true; startAdjust = input.adjust }
                guard let a0 = startAdjust else { return }
                let fw = fittedSize(a0).width * CGFloat(a0.zoom * a0.zoomX), fh = fittedSize(a0).height * CGFloat(a0.zoom * a0.zoomY)
                let dx = Float(v.translation.width / size.width / max(0.0001, fw))
                let dy = Float(v.translation.height / size.height / max(0.0001, fh))
                var a = a0
                func clamp(_ x: Float, _ other: Float) -> Float { max(0, min(0.95 - other, x)) }
                switch e {
                case .left: a.cropL = clamp(a0.cropL + dx, a0.cropR)
                case .right: a.cropR = clamp(a0.cropR - dx, a0.cropL)
                case .top: a.cropT = clamp(a0.cropT + dy, a0.cropB)
                case .bottom: a.cropB = clamp(a0.cropB - dy, a0.cropT)
                }
                input.adjust = a
            }
            .onEnded { _ in startAdjust = nil }
    }

    /// Aspect-fitted source size (normalised output units) before crop and zoom.
    private func fittedSize(_ a: VideoAdjust) -> CGSize {
        let b = EditableLayer(input: input, label: "").baseRect(out: out)
        return CGSize(width: b.width / CGFloat(max(0.05, 1 - a.cropL - a.cropR)),
                      height: b.height / CGFloat(max(0.05, 1 - a.cropT - a.cropB)))
    }

    // MARK: Layers: box x / y / w / h and crop (fractions of the source)

    /// Drag translation in the layer's own (rotated) axes, canvas pixels.
    private func local(_ t: CGSize, _ rotation: Double) -> CGSize {
        guard rotation != 0 else { return t }
        let a = rotation * .pi / 180, c = cos(a), s = sin(a)
        return CGSize(width: t.width * c + t.height * s, height: -t.width * s + t.height * c)
    }

    private func layerMove(_ k: Int, _ size: CGSize) -> some Gesture {
        drag()
            .onChanged { v in
                guard input.layers.indices.contains(k) else { return }
                if startLayer == nil { PlacementHistory.push(input); focused = true; startLayer = input.layers[k] }
                guard let l0 = startLayer else { return }
                // the layer may have been moved / removed meanwhile (API, layout): find it by id
                guard let j = input.layers.firstIndex(where: { $0.id == l0.id }) else { return }
                if optionDown {
                    let t = local(v.translation, l0.rotation)
                    let visW = 1 - l0.cropL - l0.cropR, visH = 1 - l0.cropT - l0.cropB
                    let dx = max(-l0.cropL, min(l0.cropR, -Float(t.width / size.width / max(0.0001, l0.w)) * visW))
                    let dy = max(-l0.cropT, min(l0.cropB, -Float(t.height / size.height / max(0.0001, l0.h)) * visH))
                    input.layers[j].cropL = l0.cropL + dx; input.layers[j].cropR = l0.cropR - dx
                    input.layers[j].cropT = l0.cropT + dy; input.layers[j].cropB = l0.cropB - dy
                    guides = []
                    return
                }
                var dx = v.translation.width / size.width, dy = v.translation.height / size.height
                let others = layerTargets(excluding: [l0.id])
                let (sx, gx) = snap([l0.x + dx, l0.x + l0.w / 2 + dx, l0.x + l0.w + dx], extra: others.x)
                let (sy, gy) = snap([l0.y + dy, l0.y + l0.h / 2 + dy, l0.y + l0.h + dy], extra: others.y)
                dx += sx; dy += sy
                guides = gx + gy.map { -1 - $0 }
                input.layers[j].x = l0.x + dx
                input.layers[j].y = l0.y + dy
            }
            .onEnded { _ in startLayer = nil; guides = [] }
    }

    /// Several selected layers move together; the selection's outline snaps like a single box.
    private func groupMove(_ size: CGSize) -> some Gesture {
        drag()
            .onChanged { v in
                if startGroup.isEmpty {
                    PlacementHistory.push(input); focused = true
                    startGroup = input.layers.filter { groupIDs.contains($0.id) && !$0.locked }
                }
                guard !startGroup.isEmpty else { return }
                let b = startGroup.map { CGRect(x: $0.x, y: $0.y, width: $0.w, height: $0.h) }.reduce(CGRect.null) { $0.union($1) }
                var dx = v.translation.width / size.width, dy = v.translation.height / size.height
                let others = layerTargets(excluding: startGroup.map(\.id))
                let (sx, gx) = snap([b.minX + dx, b.midX + dx, b.maxX + dx], extra: others.x)
                let (sy, gy) = snap([b.minY + dy, b.midY + dy, b.maxY + dy], extra: others.y)
                dx += sx; dy += sy
                guides = gx + gy.map { -1 - $0 }
                for l0 in startGroup {
                    guard let j = input.layers.firstIndex(where: { $0.id == l0.id }) else { continue }
                    input.layers[j].x = l0.x + dx
                    input.layers[j].y = l0.y + dy
                }
            }
            .onEnded { _ in startGroup = []; guides = [] }
    }

    /// Opposite corner stays put (in the layer's own axes, so this also works on rotated layers).
    private func layerResize(_ k: Int, _ c: Int, _ size: CGSize) -> some Gesture {
        drag()
            .onChanged { v in
                guard input.layers.indices.contains(k) else { return }
                if startLayer == nil { PlacementHistory.push(input); focused = true; startLayer = input.layers[k] }
                guard let l0 = startLayer else { return }
                // the layer may have been moved / removed meanwhile (API, layout): find it by id
                guard let j = input.layers.firstIndex(where: { $0.id == l0.id }) else { return }
                let t = local(v.translation, l0.rotation)
                // canvas pixels, origin = the layer's top-left corner in its own axes
                let W0 = l0.w * size.width, H0 = l0.h * size.height
                let ax = c % 2 == 0 ? W0 : 0, ay = c < 2 ? H0 : 0
                let hx = (c % 2 == 0 ? 0 : W0) + t.width, hy = (c < 2 ? 0 : H0) + t.height
                var w = max(0.02 * size.width, abs(hx - ax)), h = max(0.02 * size.height, abs(hy - ay))
                if !shiftDown {          // keep the box's aspect
                    let s = max(w / max(0.0001, W0), h / max(0.0001, H0))
                    w = W0 * s; h = H0 * s
                }
                let nx = c % 2 == 0 ? ax - w : ax, ny = c < 2 ? ay - h : ay
                // centre shift in the layer's axes → canvas axes
                let dcx = nx + w / 2 - W0 / 2, dcy = ny + h / 2 - H0 / 2
                let a = l0.rotation * .pi / 180
                let sx = dcx * cos(a) - dcy * sin(a), sy = dcx * sin(a) + dcy * cos(a)
                let cx = (l0.x + l0.w / 2) * size.width + sx, cy = (l0.y + l0.h / 2) * size.height + sy
                input.layers[j].w = w / size.width
                input.layers[j].h = h / size.height
                input.layers[j].x = (cx - w / 2) / size.width
                input.layers[j].y = (cy - h / 2) / size.height
            }
            .onEnded { _ in startLayer = nil }
    }

    private func layerCrop(_ k: Int, _ e: Edge, _ size: CGSize) -> some Gesture {
        drag()
            .onChanged { v in
                guard input.layers.indices.contains(k) else { return }
                if startLayer == nil { PlacementHistory.push(input); focused = true; startLayer = input.layers[k] }
                guard let l0 = startLayer else { return }
                // the layer may have been moved / removed meanwhile (API, layout): find it by id
                guard let j = input.layers.firstIndex(where: { $0.id == l0.id }) else { return }
                let t = local(v.translation, l0.rotation)
                let visW = max(0.001, 1 - l0.cropL - l0.cropR), visH = max(0.001, 1 - l0.cropT - l0.cropB)
                let dx = Float(t.width / size.width / max(0.0001, l0.w)) * visW
                let dy = Float(t.height / size.height / max(0.0001, l0.h)) * visH
                // together the two sides cut at most 95 %; a crop already past that only moves back out
                func clamp(_ x: Float, _ cur: Float, _ other: Float) -> Float { max(0, min(max(cur, 0.95 - other), x)) }
                var l = l0
                switch e {
                case .left: l.cropL = clamp(l0.cropL + dx, l0.cropL, l0.cropR)
                case .right: l.cropR = clamp(l0.cropR - dx, l0.cropR, l0.cropL)
                case .top: l.cropT = clamp(l0.cropT + dy, l0.cropT, l0.cropB)
                case .bottom: l.cropB = clamp(l0.cropB - dy, l0.cropB, l0.cropT)
                }
                // vMix crop: the box edge follows the handle, so the picture keeps its size and only that side
                // is cut (the cropped part fills the box — SwitcherEngine.composeLayers). Worked out in the
                // layer's own axes, so a rotated layer behaves the same: the opposite edge stays put.
                let W0 = l0.w * size.width, H0 = l0.h * size.height                   // canvas px
                let gw = W0 / Double(visW), gh = H0 / Double(visH)                     // px per unit of source
                var nw = W0, nh = H0, lx = 0.0, ly = 0.0                               // new size, centre shift (local)
                switch e {
                case .left: let d = Double(l.cropL - l0.cropL) * gw; nw = W0 - d; lx = d / 2
                case .right: let d = Double(l.cropR - l0.cropR) * gw; nw = W0 - d; lx = -d / 2
                case .top: let d = Double(l.cropT - l0.cropT) * gh; nh = H0 - d; ly = d / 2
                case .bottom: let d = Double(l.cropB - l0.cropB) * gh; nh = H0 - d; ly = -d / 2
                }
                let a = l0.rotation * .pi / 180
                let cx = (l0.x + l0.w / 2) * size.width + lx * cos(a) - ly * sin(a)
                let cy = (l0.y + l0.h / 2) * size.height + lx * sin(a) + ly * cos(a)
                l.w = max(1, nw) / size.width; l.h = max(1, nh) / size.height
                l.x = cx / size.width - l.w / 2; l.y = cy / size.height - l.h / 2
                // write back only geometry and crop — other fields may have changed meanwhile (API)
                input.layers[j].x = l.x; input.layers[j].y = l.y; input.layers[j].w = l.w; input.layers[j].h = l.h
                input.layers[j].cropL = l.cropL; input.layers[j].cropT = l.cropT
                input.layers[j].cropR = l.cropR; input.layers[j].cropB = l.cropB
            }
            .onEnded { _ in startLayer = nil }
    }

    /// Snap to 0, ½, 1 and the 5 % / 10 % safe-area lines (same targets as the Preview position editor).
    /// `extra`: edges / centres of other layers (Layers tab), so boxes line up with each other.
    private func snap(_ values: [CGFloat], extra: [CGFloat] = []) -> (CGFloat, [CGFloat]) {
        let targets: [CGFloat] = [0, 0.05, 0.1, 0.5, 0.9, 0.95, 1] + extra
        var best: (CGFloat, CGFloat)? = nil
        for v in values {
            for t in targets where abs(t - v) < 0.008 {
                if best == nil || abs(t - v) < abs(best!.0) { best = (t - v, t) }
            }
        }
        guard let b = best else { return (0, []) }
        return (b.0, [b.1])
    }
}

/// "Trim transparent edges": crop values (L, T, R, B as fractions) that keep only the visible pixels of a
/// frame with alpha — e.g. a full-screen lower-third PNG/title whose graphic sits in one corner, so Fill
/// then fills the box with the graphic instead of the empty canvas. nil = no alpha / nothing visible.
enum AlphaTrim {
    static func crop(of input: InputSource) -> (Float, Float, Float, Float)? {
        guard let pb = input.composed ?? input.video.latest(),
              CVPixelBufferGetPixelFormatType(pb) == kCVPixelFormatType_32BGRA else { return nil }
        CVPixelBufferLockBaseAddress(pb, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pb, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(pb) else { return nil }
        let w = CVPixelBufferGetWidth(pb), h = CVPixelBufferGetHeight(pb), stride = CVPixelBufferGetBytesPerRow(pb)
        let p = base.assumingMemoryBound(to: UInt8.self)
        var minX = w, minY = h, maxX = -1, maxY = -1
        let step = 2
        var y = 0
        while y < h {
            let row = p + y * stride
            var x = 0
            while x < w {
                if row[x * 4 + 3] > 8 {
                    if x < minX { minX = x }; if x > maxX { maxX = x }
                    if y < minY { minY = y }; if y > maxY { maxY = y }
                }
                x += step
            }
            y += step
        }
        guard maxX >= minX, maxY >= minY else { return nil }
        // a little margin so anti-aliased edges aren't cut
        let m = 4
        minX = max(0, minX - m); minY = max(0, minY - m); maxX = min(w - 1, maxX + m); maxY = min(h - 1, maxY + m)
        return (Float(minX) / Float(w), Float(minY) / Float(h),
                Float(w - 1 - maxX) / Float(w), Float(h - 1 - maxY) / Float(h))
    }

    /// Trim would change something: the source has transparent edges of at least ~0.5 %.
    static func crop(ifUseful input: InputSource) -> (Float, Float, Float, Float)? {
        guard let c = crop(of: input), max(c.0, c.1, c.2, c.3) > 0.005 else { return nil }
        return c
    }
}
