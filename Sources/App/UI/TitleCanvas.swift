import SwiftUI

/// Title editor canvas: the live title with every field's box on top. Drag a box to move it, drag the
/// corner to resize; boxes snap to the centre, 5 % safe-area lines and the frame edges (green guides).
struct TitleCanvas: View {
    @ObservedObject var title: TitleInput
    @Binding var selected: String?
    @ViewState private var start: TitleField? = nil
    @ViewState private var guides: [CGFloat] = []

    var body: some View {
        GeometryReader { g in
            let size = g.size
            ZStack(alignment: .topLeading) {
                // checkerboard so transparency is visible
                Canvas { ctx, sz in
                    let cell: CGFloat = 12
                    for y in 0..<Int(sz.height / cell) + 1 {
                        for x in 0..<Int(sz.width / cell) + 1 {
                            ctx.fill(Path(CGRect(x: CGFloat(x) * cell, y: CGFloat(y) * cell, width: cell, height: cell)),
                                     with: .color(Color(white: (x + y) % 2 == 0 ? 0.2 : 0.26)))
                        }
                    }
                }
                MonitorView(fps: 30) { title.video.latest() }
                // safe area (90 %)
                Rectangle().stroke(Color.white.opacity(0.18), style: StrokeStyle(lineWidth: 1, dash: [4, 4]))
                    .frame(width: size.width * 0.9, height: size.height * 0.9)
                    .offset(x: size.width * 0.05, y: size.height * 0.05)
                    .allowsHitTesting(false)
                ForEach(title.document.fields.indices, id: \.self) { i in
                    let f = title.document.fields[i]
                    if f.visible {
                        let r = CGRect(x: f.x * size.width, y: f.y * size.height, width: f.w * size.width, height: f.h * size.height)
                        let sel = selected == f.id
                        Rectangle()
                            .fill(Color.yellow.opacity(sel ? 0.08 : 0.001))
                            .overlay(Rectangle().stroke(sel ? Color.yellow : Color.white.opacity(0.35),
                                                        style: StrokeStyle(lineWidth: sel ? 1.5 : 1, dash: sel ? [] : [3, 3])))
                            .frame(width: max(6, r.width), height: max(6, r.height))
                            .offset(x: r.minX, y: r.minY)
                            .gesture(move(i, size))
                            .onTapGesture { selected = f.id }
                        if sel {
                            Rectangle().fill(Color.yellow).frame(width: 9, height: 9)
                                .offset(x: r.maxX - 4.5, y: r.maxY - 4.5)
                                .gesture(resize(i, size))
                            Text(f.id).font(.system(size: 9, weight: .bold)).foregroundColor(.black)
                                .padding(.horizontal, 3).background(Color.yellow)
                                .offset(x: r.minX, y: max(0, r.minY - 13))
                                .allowsHitTesting(false)
                        }
                    }
                }
                ForEach(Array(guides.enumerated()), id: \.offset) { _, v in
                    if v >= 0 {
                        Rectangle().fill(Color.green).frame(width: 1, height: size.height).offset(x: v * size.width)
                    } else {
                        Rectangle().fill(Color.green).frame(width: size.width, height: 1).offset(y: (-1 - v) * size.height)
                    }
                }
                .allowsHitTesting(false)
            }
            .clipped()
        }
        .aspectRatio(16.0 / 9.0, contentMode: .fit)
    }

    private func snap(_ values: [Double]) -> (Double, [Double]) {
        let targets: [Double] = [0, 0.05, 0.1, 0.5, 0.9, 0.95, 1]
        var best: (Double, Double)? = nil
        for v in values {
            for t in targets where abs(t - v) < 0.008 {
                if best == nil || abs(t - v) < abs(best!.0) { best = (t - v, t) }
            }
        }
        return best.map { ($0.0, [$0.1]) } ?? (0, [])
    }

    private func move(_ i: Int, _ size: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 1)
            .onChanged { v in
                guard title.document.fields.indices.contains(i) else { return }
                if start == nil { start = title.document.fields[i]; selected = title.document.fields[i].id }
                guard let f0 = start else { return }
                var nx = f0.x + Double(v.translation.width / size.width)
                var ny = f0.y + Double(v.translation.height / size.height)
                let (sx, gx) = snap([nx, nx + f0.w / 2, nx + f0.w])
                let (sy, gy) = snap([ny, ny + f0.h / 2, ny + f0.h])
                nx += sx; ny += sy
                guides = gx.map { CGFloat($0) } + gy.map { -1 - CGFloat($0) }
                title.document.fields[i].x = nx
                title.document.fields[i].y = ny
            }
            .onEnded { _ in start = nil; guides = [] }
    }

    private func resize(_ i: Int, _ size: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 1)
            .onChanged { v in
                guard title.document.fields.indices.contains(i) else { return }
                if start == nil { start = title.document.fields[i] }
                guard let f0 = start else { return }
                var w = max(0.005, f0.w + Double(v.translation.width / size.width))
                var h = max(0.004, f0.h + Double(v.translation.height / size.height))
                let (sx, gx) = snap([f0.x + w]); let (sy, gy) = snap([f0.y + h])
                w += sx; h += sy
                guides = gx.map { CGFloat($0) } + gy.map { -1 - CGFloat($0) }
                title.document.fields[i].w = w
                title.document.fields[i].h = h
            }
            .onEnded { _ in start = nil; guides = [] }
    }
}
