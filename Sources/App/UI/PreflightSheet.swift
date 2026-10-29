import SwiftUI

/// Pre-flight checklist (also shown automatically when starting a stream with problems).
struct PreflightSheet: View {
    @EnvironmentObject var engine: SwitcherEngine
    @Environment(\.dismiss) private var dismiss
    var proceedTitle: String? = nil
    var onProceed: (() -> Void)? = nil
    @ViewState private var items: [PreflightItem] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Image(systemName: "checklist").font(.title2)
                Text(L("송출 전 점검")).font(.headline)
                Spacer()
                summary
            }
            ScrollView {
                VStack(spacing: 6) {
                    ForEach(items) { it in
                        HStack(alignment: .top, spacing: 10) {
                            Image(systemName: it.level == .ok ? "checkmark.circle.fill" : (it.level == .warn ? "exclamationmark.triangle.fill" : "xmark.octagon.fill"))
                                .foregroundColor(it.level == .ok ? .green : (it.level == .warn ? .yellow : .red))
                                .font(.system(size: 16))
                            VStack(alignment: .leading, spacing: 2) {
                                Text(it.title).font(.system(size: 13, weight: .semibold))
                                Text(it.detail).font(.system(size: 12)).foregroundColor(.secondary)
                            }
                            Spacer()
                        }
                        .padding(8)
                        .background(RoundedRectangle(cornerRadius: 6).fill(Color.white.opacity(0.04)))
                    }
                }
            }
            HStack {
                Button(L("다시 점검")) { items = engine.preflight() }
                Spacer()
                Button(L("닫기")) { dismiss() }
                if let t = proceedTitle, let go = onProceed {
                    Button(t) { go(); dismiss() }
                        .keyboardShortcut(.defaultAction)
                        .tint(items.contains { $0.level == .fail } ? .red : .accentColor)
                }
            }
        }
        .padding()
        .frame(width: 560, height: 520)
        .onAppear { items = engine.preflight() }
    }

    private var summary: some View {
        let f = items.filter { $0.level == .fail }.count, w = items.filter { $0.level == .warn }.count
        return Text(f > 0 ? Lf("문제 %@ · 주의 %@", "\(f)", "\(w)") : (w > 0 ? Lf("주의 %@", "\(w)") : L("모두 정상")))
            .font(.system(size: 12, weight: .bold))
            .padding(.horizontal, 8).padding(.vertical, 2)
            .background(f > 0 ? Color.red : (w > 0 ? Color.orange : Color.green))
            .foregroundColor(.white)
            .clipShape(Capsule())
    }
}

/// Bottom-bar "점검" button.
struct PreflightButton: View {
    @EnvironmentObject var engine: SwitcherEngine
    @ViewState private var show = false

    var body: some View {
        Button { show = true } label: {
            Image(systemName: "checklist")
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(.white)
                .frame(width: 34, height: 30)
                .background(Theme.button)
                .clipShape(RoundedRectangle(cornerRadius: 3))
        }
        .buttonStyle(.plain)
        .help(L("송출 전 점검 — 신호·백업·SRT·송출 주소·디스크·오디오·렌더를 한 번에 확인"))
        .sheet(isPresented: $show) { PreflightSheet().environmentObject(engine) }
    }
}
