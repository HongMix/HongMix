import SwiftUI

/// Small line graph with a fixed floor scale, optional warning threshold and the current value.
struct Sparkline: View {
    let title: String
    let values: [Double]
    let unit: String
    var minScale: Double = 1
    var warn: Double? = nil
    var color: Color = .accentColor
    var format = "%.1f"

    var body: some View {
        let top = max(minScale, (values.max() ?? 0) * 1.15, (warn ?? 0) * 1.2)
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(title).font(.system(size: 11)).foregroundColor(.secondary)
                Spacer()
                Text(String(format: format, values.last ?? 0) + " " + unit)
                    .font(.system(size: 11, weight: .semibold).monospacedDigit())
                    .foregroundColor((warn.map { (values.last ?? 0) > $0 } ?? false) ? .orange : .primary)
            }
            Canvas { ctx, size in
                let cap = Double(HealthHistory.capacity)
                func pt(_ i: Int, _ v: Double) -> CGPoint {
                    // newest sample at the right edge; the graph fills in from the right
                    let x = size.width * (1 - (Double(values.count - 1 - i) / (cap - 1)))
                    return CGPoint(x: x, y: size.height * (1 - min(v, top) / top))
                }
                ctx.fill(Path(CGRect(origin: .zero, size: size)), with: .color(Color.black.opacity(0.25)))
                if let w = warn {
                    let y = size.height * (1 - w / top)
                    var p = Path(); p.move(to: CGPoint(x: 0, y: y)); p.addLine(to: CGPoint(x: size.width, y: y))
                    ctx.stroke(p, with: .color(.orange.opacity(0.5)), style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
                }
                guard values.count > 1 else { return }
                var line = Path()
                var area = Path()
                area.move(to: CGPoint(x: pt(0, 0).x, y: size.height))
                for (i, v) in values.enumerated() {
                    let p = pt(i, v)
                    if i == 0 { line.move(to: p) } else { line.addLine(to: p) }
                    area.addLine(to: p)
                }
                area.addLine(to: CGPoint(x: pt(values.count - 1, 0).x, y: size.height))
                ctx.fill(area, with: .color(color.opacity(0.18)))
                ctx.stroke(line, with: .color(color), lineWidth: 1.5)
            }
            .frame(height: 46)
            .clipShape(RoundedRectangle(cornerRadius: 4))
        }
    }
}

/// "Stream health" section: last 2 minutes of render time, drops, bitrate and SRT link quality.
struct HealthGraphsSection: View {
    @ObservedObject var stats: EngineStats
    let frameMs: Double

    var body: some View {
        let h = stats.history
        GroupBox(L("상태 그래프 (최근 2분)")) {
            VStack(alignment: .leading, spacing: 8) {
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 14), GridItem(.flexible(), spacing: 14)], spacing: 10) {
                    Sparkline(title: L("렌더 시간 (최대)"), values: h.series(\.renderMaxMs), unit: "ms",
                              minScale: frameMs, warn: frameMs, color: .green)
                    Sparkline(title: L("드롭된 프레임 / 초"), values: h.intSeries(\.droppedFrames), unit: "",
                              minScale: 3, warn: 0.5, color: .red, format: "%.0f")
                    Sparkline(title: L("스트림 비트레이트 (합계)"), values: h.series(\.streamKbps).map { $0 / 1000 },
                              unit: "Mbps", minScale: 2, color: .blue, format: "%.2f")
                    Sparkline(title: L("SRT RTT (최악 링크)"), values: h.series(\.srtRttMs), unit: "ms",
                              minScale: 20, color: .purple)
                    Sparkline(title: L("SRT 손실률 (최악 링크)"), values: h.series(\.srtLossPct), unit: "%",
                              minScale: 1, warn: 0.5, color: .pink, format: "%.2f")
                    Sparkline(title: L("UI 멈춤"), values: h.series(\.uiStallMs), unit: "ms",
                              minScale: 50, warn: 100, color: .gray, format: "%.0f")
                }
                HStack(spacing: 16) {
                    event(L("마지막 프레임 드롭"), h.lastEvent { $0.droppedFrames > 0 })
                    event(L("마지막 신호 끊김"), h.lastEvent { $0.lostInputs > 0 })
                    event(L("마지막 SRT 손실"), h.lastEvent { $0.srtLossPct > 0.5 })
                }
                .font(.system(size: 11))
            }
            .padding(4)
        }
    }

    private func event(_ label: String, _ ago: TimeInterval?) -> some View {
        HStack(spacing: 4) {
            Circle().fill(ago == nil ? Color.green : (ago! < 10 ? .red : .orange)).frame(width: 7, height: 7)
            Text(label + ": " + (ago.map { Lf("%@초 전", "\(Int($0))") } ?? L("없음"))).foregroundColor(.secondary)
        }
    }
}
