import SwiftUI
import CoreVideo

/// One input as it appears in a monitor: its own Position settings plus any extra placement applied by the
/// mixer (Overlay channel Picture-in-Picture).
struct EditableLayer: Identifiable {
    let input: InputSource
    var extraZoom: Float = 1
    var extraPanX: Float = 0
    var extraPanY: Float = 0
    var label: String
    var id: UUID { input.id }

    /// Source size in pixels (falls back to the output size until the first frame arrives).
    func sourceSize(_ out: CGSize) -> CGSize {
        let st = input.video.stats
        return st.width > 0 && st.height > 0 ? CGSize(width: st.width, height: st.height) : out
    }

    /// Cropped, aspect-fitted source rectangle before zoom/pan (normalised output coords, y down).
    func baseRect(out: CGSize) -> CGRect {
        let a = input.adjust
        let s = sourceSize(out)
        let sa = s.width / max(1, s.height), da = out.width / max(1, out.height)
        var w: CGFloat = sa > da ? 1 : sa / da
        var h: CGFloat = sa > da ? da / sa : 1
        var x = (1 - w) / 2, y = (1 - h) / 2
        x += CGFloat(a.cropL) * w; y += CGFloat(a.cropT) * h
        w *= CGFloat(max(0, 1 - a.cropL - a.cropR)); h *= CGFloat(max(0, 1 - a.cropT - a.cropB))
        return CGRect(x: x, y: y, width: w, height: h)
    }

    /// Visible rectangle on screen — mirrors `sampleLayer` in Mixer.metal: uv = (p − ½)·zoom + ½ + pan/2.
    func rect(out: CGSize) -> CGRect {
        let a = input.adjust
        let b = baseRect(out: out)
        let z = CGFloat(a.zoom * extraZoom)
        let px = CGFloat(a.panX + extraPanX), py = CGFloat(a.panY + extraPanY)
        return CGRect(x: (b.minX - 0.5) * z + 0.5 + px / 2, y: (b.minY - 0.5) * z + 0.5 - py / 2,
                      width: b.width * z, height: b.height * z)
    }
}

/// Drag-to-position overlay for the Preview / Output monitors (vMix Layer Designer style):
/// drag inside a box to move it, drag a corner to resize (aspect kept), green guides snap to the centre,
/// the frame edges and the 90 % / 80 % safe areas. Values are written to the input's Position settings.
struct PositionEditLayer: View {
    @EnvironmentObject var engine: SwitcherEngine
    let layers: [EditableLayer]          // bottom → top
    @ViewState private var selected: UUID? = nil
    @ViewState private var dragStart: (VideoAdjust, CGRect)? = nil
    @ViewState private var guides: [CGFloat] = []      // x guides (positive) and y guides (encoded as -1 - y)
    @ViewState private var hover: Bool = false

    private var outSize: CGSize { CGSize(width: engine.format.width, height: engine.format.height) }

    var body: some View {
        GeometryReader { g in
            let size = g.size
            let current = layers.first { $0.id == selected } ?? layers.last
            ZStack(alignment: .topLeading) {
                Color.black.opacity(0.001)                 // catches clicks over empty areas
                ForEach(layers) { l in
                    let r = l.rect(out: outSize)
                    let isSel = l.id == current?.id
                    Rectangle()
                        .stroke(isSel ? Color.yellow : Color.white.opacity(0.45),
                                style: StrokeStyle(lineWidth: isSel ? 2 : 1, dash: isSel ? [] : [4, 3]))
                        .frame(width: max(2, r.width * size.width), height: max(2, r.height * size.height))
                        .offset(x: r.minX * size.width, y: r.minY * size.height)
                        .allowsHitTesting(false)
                }
                if let l = current {
                    let r = l.rect(out: outSize)
                    // move area
                    Rectangle().fill(Color.yellow.opacity(0.06))
                        .frame(width: max(8, r.width * size.width), height: max(8, r.height * size.height))
                        .offset(x: r.minX * size.width, y: r.minY * size.height)
                        .gesture(moveGesture(l, size))
                    // corner handles (resize around the opposite corner)
                    ForEach(0..<4, id: \.self) { c in
                        let hx = c % 2 == 0 ? r.minX : r.maxX, hy = c < 2 ? r.minY : r.maxY
                        Rectangle().fill(Color.yellow)
                            .frame(width: 10, height: 10)
                            .offset(x: hx * size.width - 5, y: hy * size.height - 5)
                            .gesture(resizeGesture(l, corner: c, size))
                    }
                    // label + values
                    let a = l.input.adjust
                    Text("\(l.label)  X \(String(format: "%.2f", a.panX))  Y \(String(format: "%.2f", a.panY))  Zoom \(String(format: "%.2f", a.zoom))")
                        .font(.system(size: 10, weight: .semibold).monospacedDigit())
                        .padding(.horizontal, 5).padding(.vertical, 2)
                        .background(Color.black.opacity(0.7))
                        .foregroundColor(.yellow)
                        .offset(x: min(max(0, r.minX * size.width), size.width - 240),
                                y: r.minY * size.height > 18 ? r.minY * size.height - 18 : r.maxY * size.height + 2)
                        .allowsHitTesting(false)
                }
                // snapping guides
                ForEach(Array(guides.enumerated()), id: \.offset) { _, gv in
                    if gv >= 0 {
                        Rectangle().fill(Color.green).frame(width: 1, height: size.height).offset(x: gv * size.width)
                    } else {
                        Rectangle().fill(Color.green).frame(width: size.width, height: 1).offset(y: (-1 - gv) * size.height)
                    }
                }
                .allowsHitTesting(false)
            }
            .contentShape(Rectangle())
            .onTapGesture { loc in
                // select the topmost layer under the click
                let p = CGPoint(x: loc.x / size.width, y: loc.y / size.height)
                if let hit = layers.reversed().first(where: { $0.rect(out: outSize).contains(p) }) { selected = hit.id }
            }
            .contextMenu {
                if let l = current {
                    Button(Lf("위치 초기화 (%@)", "\(l.label)")) { reset(l, keepCrop: true) }
                    Button(L("가운데 정렬")) { center(l) }
                    Button(L("화면에 맞추기 (Zoom 1)")) { var a = l.input.adjust; a.zoom = 1 / l.extraZoom; a.panX = -l.extraPanX; a.panY = -l.extraPanY; l.input.adjust = a }
                    Divider()
                    ForEach(layers.reversed()) { o in
                        Button((o.id == l.id ? "✓ " : "   ") + o.label) { selected = o.id }
                    }
                }
            }
        }
    }

    // MARK: Gestures

    private func moveGesture(_ l: EditableLayer, _ size: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 1)
            .onChanged { v in
                if dragStart == nil { dragStart = (l.input.adjust, l.rect(out: outSize)); selected = l.id }
                guard let (a0, r0) = dragStart else { return }
                var dx = v.translation.width / size.width, dy = v.translation.height / size.height
                // snap the moved rectangle's edges / centre to guides
                let (sx, gx) = snap([r0.minX + dx, r0.midX + dx, r0.maxX + dx])
                let (sy, gy) = snap([r0.minY + dy, r0.midY + dy, r0.maxY + dy])
                dx += sx; dy += sy
                guides = gx + gy.map { -1 - $0 }
                var a = a0
                a.panX = a0.panX + Float(dx * 2)
                a.panY = a0.panY - Float(dy * 2)
                l.input.adjust = a
            }
            .onEnded { _ in dragStart = nil; guides = [] }
    }

    private func resizeGesture(_ l: EditableLayer, corner c: Int, _ size: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 1)
            .onChanged { v in
                if dragStart == nil { dragStart = (l.input.adjust, l.rect(out: outSize)); selected = l.id }
                guard let (a0, r0) = dragStart else { return }
                // anchor = opposite corner, fixed on screen
                let ax = c % 2 == 0 ? r0.maxX : r0.minX, ay = c < 2 ? r0.maxY : r0.minY
                var hx = (c % 2 == 0 ? r0.minX : r0.maxX) + v.translation.width / size.width
                let hy = (c < 2 ? r0.minY : r0.maxY) + v.translation.height / size.height
                // keep aspect: the larger relative change wins
                let sxr = abs(hx - ax) / max(0.0001, r0.width), syr = abs(hy - ay) / max(0.0001, r0.height)
                var ratio = max(0.02, max(sxr, syr))
                // snap the moving edge
                let newW = r0.width * ratio
                hx = c % 2 == 0 ? ax - newW : ax + newW
                let (sx, gx) = snap([hx])
                if sx != 0 { ratio = abs(hx + sx - ax) / max(0.0001, r0.width) }
                guides = gx
                let zEff0 = CGFloat(a0.zoom * l.extraZoom)
                let zEff = zEff0 * ratio
                // solve pan so the anchor corner stays put (see EditableLayer.rect)
                let base = l.baseRect(out: outSize)
                let bax = c % 2 == 0 ? base.maxX : base.minX, bay = c < 2 ? base.maxY : base.minY
                let pxEff = (ax - (bax - 0.5) * zEff - 0.5) * 2
                let pyEff = -(ay - (bay - 0.5) * zEff - 0.5) * 2
                var a = a0
                a.zoom = Float(zEff) / l.extraZoom
                a.panX = Float(pxEff) - l.extraPanX
                a.panY = Float(pyEff) - l.extraPanY
                l.input.adjust = a
            }
            .onEnded { _ in dragStart = nil; guides = [] }
    }

    /// Snap candidates to 0, 0.5, 1 and the 5 % / 10 % safe-area lines. Returns the correction and hit guides.
    private func snap(_ values: [CGFloat]) -> (CGFloat, [CGFloat]) {
        let targets: [CGFloat] = [0, 0.05, 0.1, 0.5, 0.9, 0.95, 1]
        let th: CGFloat = 0.008
        var best: (CGFloat, CGFloat)? = nil
        for v in values {
            for t in targets where abs(t - v) < th {
                if best == nil || abs(t - v) < abs(best!.0) { best = (t - v, t) }
            }
        }
        guard let b = best else { return (0, []) }
        return (b.0, [b.1])
    }

    private func reset(_ l: EditableLayer, keepCrop: Bool) {
        var a = l.input.adjust
        a.zoom = 1; a.panX = 0; a.panY = 0
        if !keepCrop { a.cropL = 0; a.cropR = 0; a.cropT = 0; a.cropB = 0 }
        l.input.adjust = a
    }

    private func center(_ l: EditableLayer) {
        let r = l.rect(out: outSize)
        var a = l.input.adjust
        a.panX += Float((0.5 - r.midX) * 2)
        a.panY -= Float((0.5 - r.midY) * 2)
        l.input.adjust = a
    }
}
