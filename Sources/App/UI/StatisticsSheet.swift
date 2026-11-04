import SwiftUI

/// Statistics window (vMix: icon in the bottom-right corner). Per input: format, frame-arrival
/// intervals ("Video" column), late frames (≈ Source Dropped), audio buffer. Per output: encoder and
/// bitrate. Plus the renderer: average / peak frame time and dropped render ticks.
struct StatisticsSheet: View {
    // Keep a plain reference instead of observing the entire switcher. The sheet has its own
    // section-level refreshes below; observing every live engine change invalidates this large
    // diagnostic hierarchy while cameras and media inputs are publishing state.
    let engine: SwitcherEngine
    @Environment(\.dismiss) private var dismiss
    @ViewState private var showInputDetails = false

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Statistics").font(.headline)
                Spacer()
                Button("Reset") {
                    for i in engine.inputs { i.video.resetStats(); i.resetAudioDiagnostics() }
                    engine.audioMixer.resetOutputDiagnostics()
                }
                .help(L("프레임 지연·믹서 및 CoreAudio 언더런 누적값을 초기화합니다. 녹화·송출에는 영향이 없습니다."))
            }
            .padding()

            ScrollView {
                // A regular VStack measures and constructs every diagnostics section when the
                // window opens, even when most of the sections are below the fold. The SRT and
                // output sections can query live objects, while the graphs create several Canvas
                // views. Keep the initial presentation cheap and build sections as they approach
                // the visible area.
                LazyVStack(alignment: .leading, spacing: 14) {
                    TimelineView(.periodic(from: .now, by: 1)) { _ in
                        rendererSection
                    }
                    HealthGraphsSection(stats: engine.stats, frameMs: 1000 / max(1, engine.format.fps))
                    inputsSection
                    TimelineView(.periodic(from: .now, by: 1)) { _ in
                        audioOutputSection
                    }
                    TimelineView(.periodic(from: .now, by: 1)) { _ in
                        srtSection
                    }
                    TimelineView(.periodic(from: .now, by: 1)) { _ in
                        outputsSection
                    }
                    Text(L("Video 간격/Max gap은 최근 입력 프레임 도착 간격입니다. PTS step은 파일 미디어 시간 간격입니다. Frame age max (2s)는 실제 Program에 사용된 연속 영상 프레임의 최근 2초 최대 나이입니다. 타이틀·브라우저·이미지처럼 내용이 바뀔 때만 새 프레임을 만드는 입력은 이 값이 적용되지 않습니다. Program reuse는 같은 프레임을 출력 틱에서 재사용한 횟수이며 정지 그래픽에서는 정상적으로 증가합니다. 입력 Audio underrun과 최종 CoreAudio 출력 underrun은 별도입니다. Reset 후 문제 구간을 재생해 비교하세요."))
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                .padding(.horizontal)
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
                stat(L("UI 응답 지연 (최대/1초)"), String(format: "%.0f ms", engine.uiStallMs), warn: engine.uiStallMs > 30)
                    .help(L("메인 UI 이벤트 루프의 20ms 감시 타이머가 늦어진 최대 시간입니다. 이 값만으로 송출 영상/오디오 드롭을 뜻하지 않습니다. Renderer Dropped, Output monitor, 실제 출력 녹화/수신을 함께 확인하세요."))
                stat(L("Output 모니터"), "\(MonitorRenderer.drawsPerSecond) fps")
                Spacer()
            }
            .padding(4)
        }
    }

    private var inputsSection: some View {
        GroupBox {
            DisclosureGroup(isExpanded: $showInputDetails) {
                if showInputDetails {
                    TimelineView(.periodic(from: .now, by: 1)) { _ in
                        inputRows
                    }
                }
            } label: {
                HStack {
                    Text(L("입력 진단 상세"))
                    Text("\(engine.inputs.count)")
                        .foregroundColor(.secondary)
                    Spacer()
                    if !showInputDetails {
                        Text(L("필요할 때 펼치기"))
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
                .font(.headline)
                .contentShape(Rectangle())
            }
        }
    }

    private var inputRows: some View {
        ScrollView(.horizontal) {
            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 4) {
                GridRow {
                    head("#"); head("Input"); head("Format"); head("FPS"); head("Video (ms)"); head("Max gap (2s)"); head("PTS step"); head("Frame age max (2s)"); head("Program reuse")
                    head(L("늦은 프레임")); head("Source Dropped"); head("Audio buffer"); head("Audio underruns")
                    head("Audio path (min PCM · FF queue now/peak · late/max)"); head("Status")
                }
                Divider()
                ForEach(engine.inputs) { i in
                    let st = i.video.stats
                    let audio = i.audio.diagnostics
                    let ffmpeg = i as? FFmpegInput
                    let decodeMode = ffmpeg?.videoDecodeModeName() ?? "—"
                    let decoderAudio = ffmpeg?.audioQueueDiagnostics()
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
                        Text(st.maxGapMs > 0 ? String(format: "%.1f ms", st.maxGapMs) : "—")
                            .monospacedDigit().foregroundColor(st.maxGapMs > 50 ? .orange : .primary)
                        Text(st.lastPTSStepMs != 0 ? String(format: "%.1f ms", st.lastPTSStepMs) : "—").monospacedDigit()
                        Text(i.video.followsProgramRate ? "—" : (st.maxProgramFrameAgeMs > 0 ? String(format: "%.1f ms", st.maxProgramFrameAgeMs) : "—"))
                            .monospacedDigit().foregroundColor(st.maxProgramFrameAgeMs > 50 ? .orange : .primary)
                        Text("\(st.repeatedProgramTicks)").monospacedDigit()
                        Text("\(st.late)").monospacedDigit().foregroundColor(st.late > 0 ? .orange : .primary)
                        Text("\(i.video.sourceDropped)").monospacedDigit()
                            .foregroundColor(i.video.sourceDropped > 0 ? .orange : .primary)
                        Text(String(format: "%.0f ms", Double(i.audio.available) / 48.0)).monospacedDigit()
                        // Both old columns counted the same `got < n` event in AudioMixer.mix.
                        // Show that one input-ring underrun once; output-ring underruns remain below.
                        Text("\(audio.shortReads)").monospacedDigit()
                            .foregroundColor(audio.shortReads > 0 ? .red : .primary)
                        let minPCM = audio.minReadAvailable.map { String(format: "%.0f", Double($0) / 48.0) } ?? "—"
                        let ffQueue = decoderAudio.map {
                            String(format: "%.0f/%.0f · %llu/%.0f",
                                   Double($0.queued_frames) / 48.0,
                                   Double($0.peak_queued_frames) / 48.0,
                                   $0.late_chunks,
                                   Double($0.max_lateness_us) / 1000.0)
                        } ?? "—"
                        Text("\(minPCM) ms · \(ffQueue)").monospacedDigit()
                            .help(L("최저 PCM 대기량(ms) · FFmpeg 예약 오디오 큐 현재/최대 대기량(ms) · 기한이 지난 청크 수/최대 지연(ms). 현재값은 순간값이고 나머지는 Reset 이후 누적 또는 최대값입니다."))
                        Text(i.status + (decodeMode == "—" || decodeMode == "Pending" ? "" : " · " + (decodeMode == "VideoToolbox" ? "VT" : "CPU")))
                            .lineLimit(1).foregroundColor(decodeMode == "Software" ? .orange : .secondary)
                        .frame(maxWidth: 220, alignment: .leading)
                    }
                    .font(.system(size: 12))
                }
            }
            .fixedSize(horizontal: true, vertical: false)
            .padding(4)
        }
    }

    private var audioOutputSection: some View {
        GroupBox(L("최종 CoreAudio 출력 링")) {
            let rows = engine.audioMixer.outputRingStats
            if rows.isEmpty {
                Text(L("현재 모니터링 또는 지정된 CoreAudio 출력이 없습니다."))
                    .foregroundColor(.secondary).frame(maxWidth: .infinity, alignment: .leading)
            } else {
                Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 4) {
                    GridRow {
                        head(L("장치/버스")); head(L("출력 언더런")); head(L("빠진 오디오")); head(L("초기/재버퍼 무음")); head(L("현재 대기"))
                    }
                    Divider()
                    ForEach(rows, id: \.name) { row in
                        GridRow {
                            Text(row.name)
                            Text("\(row.shortReads)").foregroundColor(row.shortReads > 0 ? .red : .primary)
                            Text(String(format: "%.1f ms", Double(row.shortFrames) / 48.0))
                                .foregroundColor(row.shortFrames > 0 ? .red : .primary)
                            Text(String(format: "%.1f ms", Double(row.primingSilenceFrames) / 48.0))
                                .foregroundColor(.secondary)
                            Text(String(format: "%.1f ms", Double(row.availableFrames) / 48.0)).monospacedDigit()
                        }
                        .font(.system(size: 12))
                    }
                }
                Text(L("출력 언더런은 재생 시작 후 CoreAudio 콜백에 공급하지 못한 프레임입니다. 초기/재버퍼 무음은 링을 채우는 동안 출력한 무음과 구분합니다. 누적값이므로 Reset 전후를 비교하세요."))
                    .font(.caption).foregroundColor(.secondary)
            }
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
                ScrollView(.horizontal) {
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
                .fixedSize(horizontal: true, vertical: false)
                .padding(4)
                }
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
            Text(label).font(.caption).foregroundColor(.secondary).lineLimit(1).minimumScaleFactor(0.8)
            Text(value).font(.system(size: 15, weight: .semibold).monospacedDigit()).lineLimit(1).minimumScaleFactor(0.8)
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
