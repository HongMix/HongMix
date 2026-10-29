import SwiftUI

/// Statistics window (vMix: icon in the bottom-right corner). Per input: format, frame-arrival
/// intervals ("Video" column), late frames (≈ Source Dropped), audio buffer. Per output: encoder and
/// bitrate. Plus the renderer: average / peak frame time and dropped render ticks.
struct StatisticsSheet: View {
    @EnvironmentObject var engine: SwitcherEngine
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Statistics").font(.headline)
                Spacer()
                Button("Reset") {
                    for i in engine.inputs { i.video.resetStats() }
                }
                .help(L("입력별 '늦은 프레임' 카운터를 0으로 (녹화·송출은 영향 없음)"))
            }
            .padding()

            TimelineView(.periodic(from: .now, by: 1)) { _ in
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        rendererSection
                        HealthGraphsSection(stats: engine.stats, frameMs: 1000 / max(1, engine.format.fps))
                        inputsSection
                        srtSection
                        outputsSection
                        Text(L("Video: 직전 프레임들의 도착 간격(ms). 30p는 약 33, 59.94p는 약 17이 일정하게 나와야 정상입니다. 값이 들쭉날쭉하거나 크게 튀면 소스(카메라·네트워크) 쪽 문제입니다. 늦은 프레임은 1.5 프레임 이상 늦게 도착한 횟수입니다."))
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    .padding(.horizontal)
                }
            }

            HStack {
                Spacer()
                Button(L("닫기")) { dismiss() }.keyboardShortcut(.defaultAction)
            }
            .padding()
        }
        .frame(minWidth: 900, minHeight: 560)
    }

    private var rendererSection: some View {
        let budget = engine.format.frameDuration * 1000
        return GroupBox(Lf("렌더러 (%@)", "\(engine.format.name)")) {
            HStack(spacing: 24) {
                stat(L("평균"), String(format: "%.1f ms", engine.renderMs))
                stat(L("최대 (1초)"), String(format: "%.1f ms", engine.renderMsPeak), warn: engine.renderMsPeak > budget)
                stat(L("프레임 예산"), String(format: "%.1f ms", budget))
                stat("Renderer Dropped", "\(engine.droppedTicks)", warn: engine.droppedTicks > 0)
                stat(L("UI 멈춤 (최대)"), String(format: "%.0f ms", engine.uiStallMs), warn: engine.uiStallMs > 30)
                stat(L("Output 모니터"), "\(MonitorRenderer.drawsPerSecond) fps")
                Spacer()
            }
            .padding(4)
        }
    }

    private var inputsSection: some View {
        GroupBox(L("입력")) {
            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 4) {
                GridRow {
                    head("#"); head("Input"); head("Format"); head("FPS"); head("Video (ms)"); head(L("늦은 프레임")); head("Source Dropped")
                    head("Audio buffer"); head("Status")
                }
                Divider()
                ForEach(engine.inputs) { i in
                    let st = i.video.stats
                    GridRow {
                        Text("\(engine.number(of: i))").monospacedDigit()
                        Text(i.name).lineLimit(1).frame(maxWidth: 200, alignment: .leading)
                        Text(VideoSlot.formatLabel(st, ntsc: engine.format.fpsDen == 1001) ?? "—")
                        Text(st.fps > 0 ? (i.video.followsProgramRate
                                           ? String(format: L("%.2f (갱신 %.0f)"), st.fps, st.updateFPS)
                                           : String(format: "%.2f", st.updateFPS)) : "—").monospacedDigit()
                        Text(st.intervalsMs.isEmpty || st.fps == 0 ? "—"
                             : st.intervalsMs.map { String(format: "%.0f", $0) }.joined(separator: " ")
                               + String(format: "  ±%.1f", st.jitterMs))
                            .monospacedDigit()
                        Text("\(st.late)").monospacedDigit().foregroundColor(st.late > 0 ? .orange : .primary)
                        Text("\(i.video.sourceDropped)").monospacedDigit()
                            .foregroundColor(i.video.sourceDropped > 0 ? .orange : .primary)
                        Text(String(format: "%.0f ms", Double(i.audio.available) / 48.0)).monospacedDigit()
                        Text(i.status).lineLimit(1).foregroundColor(.secondary).frame(maxWidth: 220, alignment: .leading)
                    }
                    .font(.system(size: 12))
                }
            }
            .padding(4)
        }
    }

    /// vMix "SRT" statistics: every SRT input and output with link quality.
    private var srtSection: some View {
        let ins: [(String, SRTStats)] = engine.inputs.compactMap { i in
            (i as? FFmpegInput)?.srtStats().map { ("\(engine.number(of: i)). \(i.name)", $0) }
        }
        let outs: [(String, SRTStats)] = engine.outputs.compactMap { o in o.srtStats().map { (o.config.name, $0) } }
        return GroupBox("SRT") {
            if ins.isEmpty && outs.isEmpty {
                Text(L("연결된 SRT 입력/출력 없음")).foregroundColor(.secondary).frame(maxWidth: .infinity, alignment: .leading)
            } else {
                Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 4) {
                    GridRow {
                        head(""); head(L("이름")); head(L("방향/모드")); head(L("상대")); head("RTT"); head(L("전송률")); head(L("대역폭"))
                        head(L("손실(1초)")); head(L("손실/재전송/드롭 누적")); head(L("버퍼/지연"))
                    }
                    Divider()
                    ForEach(Array((ins + outs).enumerated()), id: \.offset) { item in
                        let (name, st) = item.element
                        GridRow {
                            Circle().fill(st.health == 0 ? Color.green : (st.health == 1 ? Color.yellow : Color.red))
                                .frame(width: 8, height: 8)
                            Text(name).lineLimit(1).frame(maxWidth: 180, alignment: .leading)
                            Text((st.isSender ? L("송출 · ") : L("수신 · ")) + st.mode)
                            Text(st.peer.isEmpty ? "—" : st.peer).font(.system(size: 11).monospaced())
                            Text(String(format: "%.0f ms", st.rttMs)).monospacedDigit()
                            Text(String(format: "%.1f Mbps", st.rateMbps)).monospacedDigit()
                            Text(String(format: "%.0f Mbps", st.bandwidthMbps)).monospacedDigit()
                            Text(String(format: "%.2f %%", st.lossPercent)).monospacedDigit()
                                .foregroundColor(st.lossPercent > 0.5 ? .orange : .primary)
                            Text("\(st.lost) / \(st.retransmitted) / \(st.dropped)").monospacedDigit()
                                .foregroundColor(st.dropped > 0 ? .red : .primary)
                            Text("\(st.bufferMs) / \(st.latencyMs) ms").monospacedDigit()
                        }
                        .font(.system(size: 12))
                    }
                }
                .padding(4)
                Text(L("지연(latency)은 RTT의 4배 이상을 권장합니다 (노랑 = 부족). 드롭 = 지연 안에 복구 못 하고 버린 패킷 → 화면 깨짐."))
                    .font(.caption).foregroundColor(.secondary)
            }
        }
    }

    private var outputsSection: some View {
        GroupBox(L("출력")) {
            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 4) {
                GridRow { head("Output"); head(L("종류")); head(L("상태")); head(L("인코더 · 비트레이트 · 드롭")) }
                Divider()
                ForEach(engine.outputs) { o in
                    OutputStatRow(output: o)
                }
                if engine.outputs.isEmpty {
                    Text(L("설정된 출력 없음")).foregroundColor(.secondary)
                }
            }
            .padding(4)
        }
    }

    private func head(_ s: String) -> some View {
        Text(s).font(.system(size: 11, weight: .semibold)).foregroundColor(.secondary)
    }

    private func stat(_ label: String, _ value: String, warn: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.caption).foregroundColor(.secondary)
            Text(value).font(.system(size: 15, weight: .semibold).monospacedDigit())
                .foregroundColor(warn ? .orange : .primary)
        }
    }
}

private struct OutputStatRow: View {
    @ObservedObject var output: OutputChannel

    var body: some View {
        GridRow {
            Text(output.config.name)
            Text(output.config.kind.label).foregroundColor(.secondary)
            Text(output.running ? (output.message.isEmpty ? L("실행 중") : output.message) : L("중지"))
                .foregroundColor(output.state == Int32(MC_STATE_ERROR) ? .orange : (output.running ? .green : .secondary))
            Text(output.statsText.isEmpty ? "—" : output.statsText).monospacedDigit()
        }
        .font(.system(size: 12))
    }
}
