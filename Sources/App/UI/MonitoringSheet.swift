import SwiftUI
import AppKit

/// "상황판": SRT link dashboard + blackbox (incident) log.
struct MonitoringButton: View {
    @EnvironmentObject var engine: SwitcherEngine
    @ViewState private var show = false

    var body: some View {
        MonitoringButtonLabel(srt: engine.srtMonitor, box: engine.blackbox) { show = true }
            .sheet(isPresented: $show) { MonitoringSheet(srt: engine.srtMonitor, box: engine.blackbox).environmentObject(engine) }
    }
}

private struct MonitoringButtonLabel: View {
    @ObservedObject var srt: SRTMonitor
    @ObservedObject var box: Blackbox
    let action: () -> Void

    var body: some View {
        let worst = srt.links.map { $0.level }.max() ?? 0
        Button(action: action) {
            ZStack(alignment: .topTrailing) {
                Image(systemName: "waveform.path.ecg")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(.white)
                    .frame(width: 34, height: 30)
                    .background(srt.links.isEmpty ? Theme.button : (worst == 2 ? Color.red : (worst == 1 ? Color.orange : Theme.program)))
                    .clipShape(RoundedRectangle(cornerRadius: 3))
                if !box.incidents.isEmpty {
                    Text("\(box.incidents.count)")
                        .font(.system(size: 9, weight: .bold)).foregroundColor(.white)
                        .padding(.horizontal, 3).background(Capsule().fill(Color.red))
                        .offset(x: 4, y: -4)
                }
            }
        }
        .buttonStyle(.plain)
        .help(L("상황판 — SRT 링크 신호등·추천 지연값, 사고 기록(블랙박스)"))
    }
}

struct MonitoringSheet: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var srt: SRTMonitor
    @ObservedObject var box: Blackbox
    @ViewState private var tab = 0

    var body: some View {
        VStack(spacing: 10) {
            Picker("", selection: $tab) {
                Text(L("SRT 링크")).tag(0)
                Text(L("사고 기록 (블랙박스)")).tag(1)
            }
            .pickerStyle(.segmented).labelsHidden().fixedSize()
            if tab == 0 { srtTab } else { boxTab }
            HStack {
                Spacer()
                Button(L("닫기")) { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding()
        .frame(width: 820, height: 600)
    }

    private var srtTab: some View {
        ScrollView {
            if srt.links.isEmpty {
                Text(L("연결된 SRT 입력/출력 없음")).foregroundColor(.secondary).padding(40)
            }
            VStack(spacing: 10) {
                ForEach(srt.links) { l in
                    GroupBox {
                        HStack(alignment: .top, spacing: 14) {
                            Circle().fill(l.level == 0 ? Color.green : (l.level == 1 ? Color.orange : Color.red))
                                .frame(width: 18, height: 18)
                            VStack(alignment: .leading, spacing: 4) {
                                Text((l.sending ? L("송출 · ") : L("수신 · ")) + l.name).font(.headline)
                                Text(String(format: "%@  ·  RTT %.1f ms  ·  %@ %.2f%%  ·  %.2f Mbps  ·  %@ %d ms / %@ %d ms",
                                            l.stats.peer, l.stats.rttMs, L("손실"), l.stats.lossPercent, l.stats.rateMbps,
                                            L("버퍼"), l.stats.bufferMs, L("지연"), l.stats.latencyMs))
                                    .font(.system(size: 11).monospacedDigit()).foregroundColor(.secondary)
                                let rec = l.recommendedLatency
                                Text(l.stats.latencyMs >= rec
                                     ? Lf("지연 설정 적정 (권장 %@ ms 이상)", "\(rec)")
                                     : Lf("권장: Latency를 %@ → %@ ms 이상으로 (최근 RTT·손실 기준)", "\(l.stats.latencyMs)", "\(rec)"))
                                    .font(.system(size: 12, weight: .semibold))
                                    .foregroundColor(l.stats.latencyMs >= rec ? .green : .orange)
                                HStack(spacing: 10) {
                                    Sparkline(title: "RTT", values: l.rtt, unit: "ms", minScale: 20, color: .purple)
                                    Sparkline(title: L("손실"), values: l.loss, unit: "%", minScale: 1, warn: 0.5, color: .pink, format: "%.2f")
                                    Sparkline(title: L("전송률"), values: l.rate, unit: "Mbps", minScale: 2, color: .blue, format: "%.2f")
                                }
                                if !l.events.isEmpty {
                                    Text(l.events.prefix(4).joined(separator: "\n"))
                                        .font(.system(size: 11).monospacedDigit()).foregroundColor(.orange)
                                }
                            }
                        }
                        .padding(4)
                    }
                }
            }
        }
    }

    private var boxTab: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(L("송출·녹화 중에 신호 끊김, 프레임 드롭, 무음, SRT 손실, 출력 오류가 생기면 그 전후 약 10초의 Output 화면과 기록을 자동으로 남깁니다."))
                .font(.caption).foregroundColor(.secondary)
            List(box.incidents) { i in
                HStack(spacing: 10) {
                    if let img = NSImage(contentsOfFile: (i.folder as NSString).appendingPathComponent("before_12.jpg"))
                        ?? NSImage(contentsOfFile: (i.folder as NSString).appendingPathComponent("before_01.jpg")) {
                        Image(nsImage: img).resizable().aspectRatio(16 / 9, contentMode: .fit).frame(width: 96)
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        Text(box.kindLabel(i.kind)).font(.headline).foregroundColor(.red)
                        Text(i.detail).font(.system(size: 12))
                        Text(i.time.formatted(date: .omitted, time: .standard)).font(.caption.monospacedDigit()).foregroundColor(.secondary)
                    }
                    Spacer()
                    Button(L("화면 보기")) { NSWorkspace.shared.open(URL(fileURLWithPath: i.folder)) }
                }
            }
            HStack {
                Button(L("보고서 저장…")) {
                    let p = NSSavePanel()
                    p.nameFieldStringValue = "HongMix-incidents.txt"
                    if p.runModal() == .OK, let u = p.url { try? box.report().write(to: u, atomically: true, encoding: .utf8) }
                }
                Button(L("기록 폴더 열기")) {
                    try? FileManager.default.createDirectory(atPath: Blackbox.folder, withIntermediateDirectories: true)
                    NSWorkspace.shared.open(URL(fileURLWithPath: Blackbox.folder))
                }
            }
        }
    }
}
