import SwiftUI

/// Compact EBU R128 readout for the Audio Mixer header (short-term + integrated vs. target),
/// with a popover for momentary / LRA / peak, target choice and reset.
struct LoudnessBadge: View {
    @EnvironmentObject var engine: SwitcherEngine
    @ViewState private var showDetails = false
    @ViewState private var target = LoudnessTarget.saved

    var body: some View {
        Button { showDetails.toggle() } label: {
            TimelineView(.periodic(from: .now, by: 0.25)) { _ in
                let r = engine.audioMixer.loudness.current
                HStack(spacing: 5) {
                    Text("LUFS").font(.system(size: 8, weight: .bold)).foregroundColor(.secondary)
                    Text("S " + LoudnessBadge.fmt(r.shortTerm))
                        .foregroundColor(LoudnessBadge.color(r.shortTerm, target: target.rawValue))
                    Text("I " + LoudnessBadge.fmt(r.integrated))
                        .foregroundColor(LoudnessBadge.color(r.integrated, target: target.rawValue))
                    let duck = engine.audioMixer.duckReductionDB
                    if duck < -0.5 {
                        Text(String(format: "DUCK %.0f", duck)).foregroundColor(.cyan)
                    }
                }
                .font(.system(size: 10, weight: .semibold).monospacedDigit())
                .padding(.horizontal, 6).padding(.vertical, 2)
                .background(RoundedRectangle(cornerRadius: 4).fill(Color.black.opacity(0.35)))
            }
        }
        .buttonStyle(.plain)
        .help(Lf("프로그램(Master) 라우드니스 — EBU R128 / ITU-R BS.1770. S = 숏텀(3초), I = 통합. 목표 %@", "\(target.label)"))
        .popover(isPresented: $showDetails, arrowEdge: .bottom) {
            LoudnessDetails(target: $target)
                .environmentObject(engine)
        }
    }

    static func fmt(_ v: Double) -> String { v.isFinite && v > -70 ? String(format: "%.1f", v) : "—" }

    /// green within ±1 LU of target, yellow within ±3, red beyond (too loud = red, too quiet = orange)
    static func color(_ v: Double, target: Double) -> Color {
        guard v.isFinite, v > -70 else { return .secondary }
        let d = v - target
        if abs(d) <= 1 { return .green }
        if abs(d) <= 3 { return .yellow }
        return d > 0 ? .red : .orange
    }
}

private struct LoudnessDetails: View {
    @EnvironmentObject var engine: SwitcherEngine
    @Binding var target: LoudnessTarget

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.2)) { _ in
            let r = engine.audioMixer.loudness.current
            VStack(alignment: .leading, spacing: 10) {
                Text(L("라우드니스 (EBU R128)")).font(.headline)
                Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 5) {
                    row(L("모멘터리 (400ms)"), LoudnessBadge.fmt(r.momentary) + " LUFS", LoudnessBadge.color(r.momentary, target: target.rawValue))
                    row(L("숏텀 (3초)"), LoudnessBadge.fmt(r.shortTerm) + " LUFS", LoudnessBadge.color(r.shortTerm, target: target.rawValue))
                    row(L("통합 (게이트)"), LoudnessBadge.fmt(r.integrated) + " LUFS", LoudnessBadge.color(r.integrated, target: target.rawValue))
                    row(L("목표 대비"), r.integrated.isFinite && r.integrated > -70
                        ? String(format: "%+.1f LU", r.integrated - target.rawValue) : "—", .primary)
                    row(L("라우드니스 범위 (LRA)"), String(format: "%.1f LU", r.range), .primary)
                    row(L("최대 모멘터리"), LoudnessBadge.fmt(r.maxMomentary) + " LUFS", .primary)
                    row(L("샘플 피크"), r.peak.isFinite ? String(format: "%.1f dBFS", r.peak) : "—",
                        r.peak > -1 ? .red : .primary)
                    row(L("측정 시간"), LoudnessDetails.duration(r.seconds), .secondary)
                }
                .font(.system(size: 12).monospacedDigit())
                Picker(L("목표"), selection: $target) {
                    ForEach(LoudnessTarget.allCases) { Text($0.label).tag($0) }
                }
                .onChange(of: target) { _, v in LoudnessTarget.saved = v }
                HStack {
                    Button(L("측정 초기화")) { engine.audioMixer.loudness.reset() }
                    Spacer()
                    Text("API: LoudnessReset").font(.caption).foregroundColor(.secondary)
                }
            }
            .padding(14)
            .frame(width: 300)
        }
    }

    @ViewBuilder private func row(_ k: String, _ v: String, _ c: Color) -> some View {
        GridRow {
            Text(k).foregroundColor(.secondary)
            Text(v).foregroundColor(c).fontWeight(.semibold)
        }
    }

    static func duration(_ s: Double) -> String {
        let t = Int(s)
        return t >= 3600 ? String(format: "%d:%02d:%02d", t / 3600, t / 60 % 60, t % 60) : String(format: "%d:%02d", t / 60, t % 60)
    }
}
