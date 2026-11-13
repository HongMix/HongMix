import SwiftUI
import AppKit
import CoreVideo

/// What the placement canvas edits: the input's own Position (zoom / pan / crop), or one of its layers.
enum PlacementTarget: Equatable {
    case input
    case layer(UUID)
}

/// Input Settings › Position and › Layers share this canvas (vMix Layer Designer + Position in one):
/// a fixed live preview on the right; in a single mode the selected box is moved by dragging inside,
/// resized from the yellow corners (aspect kept, ⇧ = free for layers), cropped from the orange edge handles,
/// and ⌥-drag inside slides the visible part. Green guides snap to centre, edges and the safe areas.
struct PlacementCanvas: View {
    @EnvironmentObject var engine: SwitcherEngine
    @ObservedObject var input: InputSource
    @Binding var target: PlacementTarget
    /// true = the input's own picture with its layers (Layers tab); false = the input as placed in Program.
    let layersView: Bool

    @ViewState private var startAdjust: VideoAdjust? = nil
    @ViewState private var startRect: CGRect = .zero
    @ViewState private var startLayer: InputLayer? = nil
    @ViewState private var guides: [CGFloat] = []

    private var out: CGSize { CGSize(width: engine.format.width, height: engine.format.height) }
    private var me: EditableLayer { EditableLayer(input: input, label: input.name) }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            GeometryReader { g in
                let size = g.size
                ZStack(alignment: .topLeading) {
                    Color.black
                    if layersView {
                        MonitorView(fps: 30) { [weak input] in input?.monitorFrame() }
                    } else {
                        MonitorView(fps: 30, placement: { [weak input] in input?.videoAdjust }) { [weak input] in input?.monitorFrame() }
                    }
                    Color.black.opacity(0.001)
                        .onTapGesture { loc in select(at: CGPoint(x: loc.x / size.width, y: loc.y / size.height)) }
                    if layersView {
                        ForEach(Array(input.layers.enumerated()), id: \.element.id) { k, l in
                            let r = CGRect(x: l.x, y: l.y, width: l.w, height: l.h)
                            box(r, size: size, label: "\(k + 1)", selected: target == .layer(l.id))
                                .onTapGesture { target = .layer(l.id) }
                        }
                        if case .layer(let id) = target, let k = input.layers.firstIndex(where: { $0.id == id }) {
                            let l = input.layers[k]
                            handles(CGRect(x: l.x, y: l.y, width: l.w, height: l.h), size: size,
                                    move: layerMove(k, size), corner: { c in layerResize(k, c, size) },
                                    edge: { e in layerCrop(k, e, size) })
                        }
                    } else {
                        let r = me.rect(out: out)
                        box(r, size: size, label: nil, selected: true)
                        handles(r, size: size, move: inputMove(size), corner: { c in inputResize(c, size) },
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
                .clipped()
            }
            .aspectRatio(16.0 / 9.0, contentMode: .fit)
            .overlay(Rectangle().stroke(Color.white.opacity(0.25), lineWidth: 1))

            HStack(spacing: 12) {
                legend(Color.yellow.opacity(0.5), L("안쪽 끌기 = 이동"))
                legend(.yellow, L("모서리 = 크기"))
                legend(.orange, L("변 가운데 = 자르기"))
                Text(L("⌥ 끌기 = 보이는 부분 옮기기")).font(.caption).foregroundColor(.secondary)
            }
            Text(readout).font(.system(size: 11).monospacedDigit()).foregroundColor(.secondary)
        }
    }

    // MARK: Drawing

    private func box(_ r: CGRect, size: CGSize, label: String?, selected: Bool) -> some View {
        ZStack(alignment: .topLeading) {
            Rectangle().fill(Color.yellow.opacity(selected ? 0.08 : 0.001))
            Rectangle().stroke(selected ? Color.yellow : Color.white.opacity(0.55),
                               style: StrokeStyle(lineWidth: selected ? 2 : 1, dash: selected ? [] : [4, 3]))
            if let label {
                Text(label).font(.system(size: 10, weight: .bold)).foregroundColor(.black)
                    .padding(.horizontal, 3).background(selected ? Color.yellow : Color.white.opacity(0.8))
            }
        }
        .frame(width: max(6, r.width * size.width), height: max(6, r.height * size.height))
        .offset(x: r.minX * size.width, y: r.minY * size.height)
    }

    private enum Edge: CaseIterable { case left, right, top, bottom }

    @ViewBuilder
    private func handles<M: Gesture, C: Gesture, E: Gesture>(_ r: CGRect, size: CGSize, move: M,
                                                          corner: @escaping (Int) -> C,
                                                          edge: @escaping (Edge) -> E) -> some View {
        // move / ⌥ slide area
        Rectangle().fill(Color.yellow.opacity(0.001))
            .frame(width: max(8, r.width * size.width), height: max(8, r.height * size.height))
            .offset(x: r.minX * size.width, y: r.minY * size.height)
            .gesture(move)
        ForEach(0..<4, id: \.self) { c in
            let hx = c % 2 == 0 ? r.minX : r.maxX, hy = c < 2 ? r.minY : r.maxY
            Rectangle().fill(Color.yellow).frame(width: 11, height: 11)
                .offset(x: hx * size.width - 5.5, y: hy * size.height - 5.5)
                .gesture(corner(c))
        }
        ForEach(Edge.allCases, id: \.self) { e in
            let vertical = e == .left || e == .right
            let cx = e == .left ? r.minX : (e == .right ? r.maxX : r.midX)
            let cy = e == .top ? r.minY : (e == .bottom ? r.maxY : r.midY)
            RoundedRectangle(cornerRadius: 2).fill(Color.orange)
                .frame(width: vertical ? 7 : 26, height: vertical ? 26 : 7)
                .offset(x: cx * size.width - (vertical ? 3.5 : 13), y: cy * size.height - (vertical ? 13 : 3.5))
                .gesture(edge(e))
        }
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
            guard let l = input.layers.first(where: { $0.id == id }) else { return "" }
            return px(CGRect(x: l.x, y: l.y, width: l.w, height: l.h))
                + String(format: "  ·  Crop L%.0f R%.0f T%.0f B%.0f %%", l.cropL * 100, l.cropR * 100, l.cropT * 100, l.cropB * 100)
        }
    }

    private func select(at p: CGPoint) {
        guard layersView else { return }
        if let hit = input.layers.reversed().first(where: { CGRect(x: $0.x, y: $0.y, width: $0.w, height: $0.h).contains(p) }) {
            target = .layer(hit.id)
        }
    }

    private var optionDown: Bool { NSEvent.modifierFlags.contains(.option) }
    private var shiftDown: Bool { NSEvent.modifierFlags.contains(.shift) }

    // MARK: Input (Position): pan / zoom / crop — same maths as Program (EditableLayer, Mixer.metal)

    private func inputMove(_ size: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 1)
            .onChanged { v in
                if startAdjust == nil { startAdjust = input.adjust; startRect = me.rect(out: out) }
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
        DragGesture(minimumDistance: 1)
            .onChanged { v in
                if startAdjust == nil { startAdjust = input.adjust; startRect = me.rect(out: out) }
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
        DragGesture(minimumDistance: 1)
            .onChanged { v in
                if startAdjust == nil { startAdjust = input.adjust }
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

    private func layerMove(_ k: Int, _ size: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 1)
            .onChanged { v in
                guard input.layers.indices.contains(k) else { return }
                if startLayer == nil { startLayer = input.layers[k] }
                guard let l0 = startLayer else { return }
                if optionDown {
                    let visW = 1 - l0.cropL - l0.cropR, visH = 1 - l0.cropT - l0.cropB
                    let dx = max(-l0.cropL, min(l0.cropR, -Float(v.translation.width / size.width / max(0.0001, l0.w)) * visW))
                    let dy = max(-l0.cropT, min(l0.cropB, -Float(v.translation.height / size.height / max(0.0001, l0.h)) * visH))
                    input.layers[k].cropL = l0.cropL + dx; input.layers[k].cropR = l0.cropR - dx
                    input.layers[k].cropT = l0.cropT + dy; input.layers[k].cropB = l0.cropB - dy
                    guides = []
                    return
                }
                var dx = v.translation.width / size.width, dy = v.translation.height / size.height
                let (sx, gx) = snap([l0.x + dx, l0.x + l0.w / 2 + dx, l0.x + l0.w + dx])
                let (sy, gy) = snap([l0.y + dy, l0.y + l0.h / 2 + dy, l0.y + l0.h + dy])
                dx += sx; dy += sy
                guides = gx + gy.map { -1 - $0 }
                input.layers[k].x = l0.x + dx
                input.layers[k].y = l0.y + dy
            }
            .onEnded { _ in startLayer = nil; guides = [] }
    }

    private func layerResize(_ k: Int, _ c: Int, _ size: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 1)
            .onChanged { v in
                guard input.layers.indices.contains(k) else { return }
                if startLayer == nil { startLayer = input.layers[k] }
                guard let l0 = startLayer else { return }
                let ax = c % 2 == 0 ? l0.x + l0.w : l0.x, ay = c < 2 ? l0.y + l0.h : l0.y
                let hx = (c % 2 == 0 ? l0.x : l0.x + l0.w) + v.translation.width / size.width
                let hy = (c < 2 ? l0.y : l0.y + l0.h) + v.translation.height / size.height
                var w = max(0.02, abs(hx - ax)), h = max(0.02, abs(hy - ay))
                if !shiftDown {          // keep the box's aspect
                    let s = max(w / max(0.0001, l0.w), h / max(0.0001, l0.h))
                    w = l0.w * s; h = l0.h * s
                }
                input.layers[k].w = w
                input.layers[k].h = h
                input.layers[k].x = c % 2 == 0 ? ax - w : ax
                input.layers[k].y = c < 2 ? ay - h : ay
            }
            .onEnded { _ in startLayer = nil }
    }

    private func layerCrop(_ k: Int, _ e: Edge, _ size: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 1)
            .onChanged { v in
                guard input.layers.indices.contains(k) else { return }
                if startLayer == nil { startLayer = input.layers[k] }
                guard let l0 = startLayer else { return }
                let visW = max(0.05, 1 - l0.cropL - l0.cropR), visH = max(0.05, 1 - l0.cropT - l0.cropB)
                let dx = Float(v.translation.width / size.width / max(0.0001, l0.w)) * visW
                let dy = Float(v.translation.height / size.height / max(0.0001, l0.h)) * visH
                func clamp(_ x: Float, _ other: Float) -> Float { max(0, min(0.95 - other, x)) }
                switch e {
                case .left: input.layers[k].cropL = clamp(l0.cropL + dx, l0.cropR)
                case .right: input.layers[k].cropR = clamp(l0.cropR - dx, l0.cropL)
                case .top: input.layers[k].cropT = clamp(l0.cropT + dy, l0.cropB)
                case .bottom: input.layers[k].cropB = clamp(l0.cropB - dy, l0.cropT)
                }
            }
            .onEnded { _ in startLayer = nil }
    }

    /// Snap to 0, ½, 1 and the 5 % / 10 % safe-area lines (same targets as the Preview position editor).
    private func snap(_ values: [CGFloat]) -> (CGFloat, [CGFloat]) {
        let targets: [CGFloat] = [0, 0.05, 0.1, 0.5, 0.9, 0.95, 1]
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
}
