import SwiftUI
import AppKit
import CoreVideo
import QuartzCore

private enum StatisticsTab: String, CaseIterable, Identifiable {
    case overview, inputs, network, outputs, diagnostics
    var id: String { rawValue }
    var title: String {
        switch self {
        case .overview: return L("전체 상태")
        case .inputs: return L("입력 및 장비")
        case .network: return L("네트워크")
        case .outputs: return L("출력")
        case .diagnostics: return L("상세 진단")
        }
    }
}

private struct BroadcastDeviceRow: Identifiable {
    let id = UUID()
    var name: String
    var type: String
    var status: String
    var detail: String
    var level: PreflightItem.Level
}

/// Statistics window (vMix: icon in the bottom-right corner). Per input: format, frame-arrival
/// intervals ("Video" column), late frames (≈ Source Dropped), audio buffer. Per output: encoder and
/// bitrate. Plus the renderer: average / peak frame time and dropped render ticks.
struct StatisticsSheet: View {
    // Keep a plain reference instead of observing the entire switcher. The sheet has its own
    // section-level refreshes below; observing every live engine change invalidates this large
    // diagnostic hierarchy while cameras and media inputs are publishing state.
    let engine: SwitcherEngine
    @Environment(\.dismissWindow) private var dismissWindow
    @ViewState private var showInputDetails = false
    @ViewState private var tab: StatisticsTab = .overview
    @ViewState private var checkItems: [PreflightItem] = []
    @ViewState private var lastFullCheck: Date?

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(L("통계 및 모니터링")).font(.headline)
                Spacer()
                Button(L("초기화")) {
                    for i in engine.inputs { i.video.resetStats(); i.resetAudioDiagnostics() }
                    engine.audioMixer.resetOutputDiagnostics()
                }
                .help(L("프레임 지연·믹서 및 CoreAudio 언더런 누적값을 초기화합니다. 녹화·송출에는 영향이 없습니다."))
            }
            .padding()

            Picker("", selection: $tab) {
                ForEach(StatisticsTab.allCases) { item in Text(item.title).tag(item) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal)
            .padding(.bottom, 10)

            ScrollView {
                // A regular VStack measures and constructs every diagnostics section when the
                // window opens, even when most of the sections are below the fold. The SRT and
                // output sections can query live objects, while the graphs create several Canvas
                // views. Keep the initial presentation cheap and build sections as they approach
                // the visible area.
                LazyVStack(alignment: .leading, spacing: 14) {
                    switch tab {
                    case .overview:
                        TimelineView(.periodic(from: .now, by: 1)) { _ in overviewContent }
                    case .inputs:
                        connectedDevicesSection
                        inputsSection
                        TimelineView(.periodic(from: .now, by: 1)) { _ in audioOutputSection }
                    case .network:
                        TimelineView(.periodic(from: .now, by: 1)) { _ in networkSummarySection }
                        TimelineView(.periodic(from: .now, by: 1)) { _ in srtSection }
                    case .outputs:
                        TimelineView(.periodic(from: .now, by: 1)) { _ in outputsSection }
                    case .diagnostics:
                        TimelineView(.periodic(from: .now, by: 1)) { _ in rendererSection }
                        HealthGraphsSection(stats: engine.stats, frameMs: 1000 / max(1, engine.format.fps))
                        inputsSection
                        TimelineView(.periodic(from: .now, by: 1)) { _ in audioOutputSection }
                        TimelineView(.periodic(from: .now, by: 1)) { _ in srtSection }
                        TimelineView(.periodic(from: .now, by: 1)) { _ in outputsSection }
                        diagnosticsExplanation
                    }
                }
                .padding(.horizontal)
            }

            HStack {
                Spacer()
                Button(L("닫기")) { dismissWindow(id: "statistics") }.keyboardShortcut(.defaultAction)
            }
            .padding()
        }
        .frame(minWidth: 1100, minHeight: 680)
        .onAppear { runFullCheck() }
    }

    private var overviewContent: some View {
        PreflightSafetyDashboard(engine: engine, items: checkItems, lastCheck: lastFullCheck,
                                 runCheck: runFullCheck, saveReport: saveDiagnosticReport)
    }

    private var allSRTStats: [SRTStats] {
        engine.inputs.compactMap { ($0 as? FFmpegInput)?.srtStats() }
            + engine.outputs.compactMap { $0.srtStats() }
    }

    private var broadcastHealthSection: some View {
        let budget = engine.format.frameDuration * 1000
        let renderer: PreflightItem.Level = engine.droppedTicks > 0 || engine.renderMsPeak > budget ? .warn : .ok
        let audioPeak = max(engine.audioMixer.master.0, engine.audioMixer.master.1)
        let audio: PreflightItem.Level = audioPeak < 0.003 || audioPeak > 0.99 ? .warn : .ok
        let inputs: PreflightItem.Level = engine.inputs.contains(where: { $0.isLiveSource && $0.signalLost }) ? .fail : .ok
        let srt = allSRTStats
        let network: PreflightItem.Level = srt.contains(where: { $0.lossPercent > 1 || $0.dropped > 0 }) ? .fail
            : (srt.contains(where: { $0.lossPercent > 0.3 || ($0.latencyMs > 0 && $0.rttMs * 4 > Double($0.latencyMs)) }) ? .warn : .ok)
        let output: PreflightItem.Level = engine.outputs.contains(where: { $0.state == Int32(MC_STATE_ERROR) }) ? .fail : .ok
        let diskGB = freeDiskGB
        let storage: PreflightItem.Level = diskGB < 5 ? .fail : (diskGB < 50 ? .warn : .ok)
        return GroupBox(L("방송 시스템")) {
            HStack(spacing: 8) {
                healthCard(L("렌더러"), renderer, renderer == .ok ? L("정상") : L("확인 필요"))
                healthCard(L("오디오"), audio, audio == .ok ? L("정상") : L("레벨 확인"))
                healthCard(L("입력"), inputs, inputs == .ok ? Lf("%@개 정상", "\(engine.inputs.count)") : L("신호 끊김"))
                healthCard(L("네트워크"), network, srt.isEmpty ? L("SRT 연결 없음") : (network == .ok ? L("정상") : L("확인 필요")))
                healthCard(L("출력"), output, engine.outputs.contains(where: { $0.running }) ? L("실행 중") : L("대기"))
                healthCard(L("저장 공간"), storage, String(format: L("%.0f GB 남음"), diskGB))
            }
            .padding(4)
        }
    }

    private func healthCard(_ title: String, _ level: PreflightItem.Level, _ detail: String) -> some View {
        let color: Color = level == .ok ? .green : (level == .warn ? .orange : .red)
        return HStack(alignment: .top, spacing: 7) {
            Circle().fill(color).frame(width: 9, height: 9).padding(.top, 3)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 12, weight: .semibold)).lineLimit(1)
                Text(detail).font(.system(size: 10)).foregroundColor(.secondary).lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 6).fill(color.opacity(0.10)))
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(color.opacity(0.25)))
    }

    private var connectedDevicesSection: some View {
        GroupBox(L("연결된 방송 장비")) {
            Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 5) {
                GridRow { head(L("장비")); head(L("종류")); head(L("상태")); head(L("상세")) }
                Divider()
                ForEach(deviceRows) { row in
                    GridRow {
                        HStack(spacing: 6) {
                            Circle().fill(row.level == .ok ? Color.green : (row.level == .warn ? .orange : .red)).frame(width: 8, height: 8)
                            Text(row.name).lineLimit(1)
                        }
                        Text(row.type).foregroundColor(.secondary)
                        Text(row.status).foregroundColor(row.level == .ok ? .green : (row.level == .warn ? .orange : .red))
                        Text(row.detail).foregroundColor(.secondary).lineLimit(1)
                    }
                    .font(.system(size: 11))
                }
            }
            .padding(4)
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    private var deviceRows: [BroadcastDeviceRow] {
        var rows = engine.inputs.filter { $0.isLiveSource || $0.kind == .audio }.map { input in
            let st = input.video.stats
            let detail = st.fps > 0 ? String(format: "%.2f fps", st.updateFPS) : (input.hasAudio ? L("오디오 연결") : "—")
            return BroadcastDeviceRow(name: input.name, type: input.kind.label,
                                      status: input.signalLost ? L("신호 끊김") : (input.status.isEmpty ? L("연결됨") : input.status),
                                      detail: detail, level: input.signalLost ? .fail : .ok)
        }
        rows.append(BroadcastDeviceRow(name: "DeckLink", type: "SDI I/O",
                                       status: mc_decklink_available() != 0 ? L("사용 가능") : L("장치 없음"),
                                       detail: mc_decklink_available() != 0 ? L("드라이버와 장치 감지") : L("실장비 검증 필요"),
                                       level: mc_decklink_available() != 0 ? .ok : .warn))
        rows.append(BroadcastDeviceRow(name: "NDI Runtime", type: L("네트워크 비디오"),
                                       status: mc_ndi_available() != 0 ? L("로드됨") : L("설치 안 됨"), detail: "NDI®",
                                       level: mc_ndi_available() != 0 ? .ok : .warn))
        return rows
    }

    private var systemResourcesSection: some View {
        let info = ProcessInfo.processInfo
        let memoryGB = Double(info.physicalMemory) / 1_073_741_824
        let thermal: String
        let thermalColor: Color
        switch info.thermalState {
        case .nominal: thermal = L("정상"); thermalColor = .green
        case .fair: thermal = L("주의"); thermalColor = .yellow
        case .serious: thermal = L("높음"); thermalColor = .orange
        case .critical: thermal = L("위험"); thermalColor = .red
        @unknown default: thermal = "—"; thermalColor = .secondary
        }
        return GroupBox(L("시스템 자원")) {
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 9) {
                resourceRow("GPU", MetalContext.shared.device.name)
                resourceRow(L("CPU 코어"), "\(info.processorCount)")
                resourceRow(L("메모리"), String(format: "%.1f GB", memoryGB))
                resourceRow(L("SSD 여유"), String(format: "%.0f GB", freeDiskGB))
                GridRow {
                    Text(L("온도 상태")).foregroundColor(.secondary)
                    HStack(spacing: 5) { Circle().fill(thermalColor).frame(width: 8, height: 8); Text(thermal) }
                }
            }
            .font(.system(size: 11))
            .padding(4)
        }
        .frame(width: 300, alignment: .topLeading)
    }

    private func resourceRow(_ label: String, _ value: String) -> some View {
        GridRow { Text(label).foregroundColor(.secondary); Text(value).lineLimit(1) }
    }

    private var freeDiskGB: Double {
        let configured = engine.outputs.first(where: { $0.config.kind == .record })?.config.recordFolder ?? "~/Movies"
        let path = (configured as NSString).expandingTildeInPath
        return Double(DiskSpace.freeBytes(at: path) ?? 0) / 1e9
    }

    private var overviewActions: some View {
        HStack(spacing: 10) {
            Button(L("전체 점검 실행")) { runFullCheck() }
            Button(L("진단 보고서 저장…")) { saveDiagnosticReport() }
            Spacer()
            if let date = lastFullCheck {
                Text(Lf("마지막 전체 점검: %@", date.formatted(date: .omitted, time: .standard)))
                    .font(.caption).foregroundColor(.secondary)
            }
        }
    }

    private var preflightIssuesSection: some View {
        GroupBox(L("점검 결과")) {
            VStack(spacing: 5) {
                ForEach(checkItems.filter { $0.level != .ok }) { item in
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: item.level == .warn ? "exclamationmark.triangle.fill" : "xmark.octagon.fill")
                            .foregroundColor(item.level == .warn ? .orange : .red)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(item.title).font(.system(size: 12, weight: .semibold))
                            Text(item.detail).font(.system(size: 11)).foregroundColor(.secondary)
                        }
                        Spacer()
                    }
                }
            }
            .padding(4)
        }
    }

    private var networkSummarySection: some View {
        let stats = allSRTStats
        let worstRTT = stats.map(\.rttMs).max() ?? 0
        let worstLoss = stats.map(\.lossPercent).max() ?? 0
        return GroupBox(L("네트워크 요약")) {
            HStack(spacing: 28) {
                stat(L("SRT 링크"), "\(stats.count)")
                stat(L("최대 RTT"), String(format: "%.1f ms", worstRTT), warn: worstRTT > 100)
                stat(L("최대 손실"), String(format: "%.2f %%", worstLoss), warn: worstLoss > 0.3)
                stat("NDI Runtime", mc_ndi_available() != 0 ? L("로드됨") : L("설치 안 됨"), warn: mc_ndi_available() == 0)
                stat(L("실행 중인 스트림"), "\(engine.outputs.filter { $0.config.kind == .stream && $0.running }.count)")
                Spacer()
            }
            .padding(4)
        }
    }

    private var diagnosticsExplanation: some View {
        Text(L("Video 간격/Max gap은 최근 입력 프레임 도착 간격입니다. PTS step은 파일 미디어 시간 간격입니다. Frame age max (2s)는 실제 Program에 사용된 연속 영상 프레임의 최근 2초 최대 나이입니다. 타이틀·브라우저·이미지처럼 내용이 바뀔 때만 새 프레임을 만드는 입력은 이 값이 적용되지 않습니다. Program reuse는 같은 프레임을 출력 틱에서 재사용한 횟수이며 정지 그래픽에서는 정상적으로 증가합니다. 입력 Audio underrun과 최종 CoreAudio 출력 underrun은 별도입니다. Reset 후 문제 구간을 재생해 비교하세요."))
            .font(.caption)
            .foregroundColor(.secondary)
    }

    private func runFullCheck() {
        checkItems = engine.preflight()
        lastFullCheck = Date()
    }

    private func saveDiagnosticReport() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "HongMix-diagnostics-\(Self.fileTimestamp.string(from: Date())).txt"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let lines = checkItems.map { item in
            let level = item.level == .ok ? "OK" : (item.level == .warn ? "WARNING" : "ERROR")
            return "[\(level)] \(item.title): \(item.detail)"
        }
        let report = """
        HongMix Diagnostic Report
        Generated: \(Date().formatted(date: .numeric, time: .standard))
        Program format: \(engine.format.name)
        Renderer: average \(String(format: "%.1f", engine.renderMs)) ms, max \(String(format: "%.1f", engine.renderMsPeak)) ms, dropped \(engine.droppedTicks)
        UI response delay: \(String(format: "%.0f", engine.uiStallMs)) ms
        Inputs: \(engine.inputs.count)
        Outputs: \(engine.outputs.count)
        SRT links: \(allSRTStats.count)
        DeckLink available: \(mc_decklink_available() != 0 ? "yes" : "no")
        NDI runtime: \(mc_ndi_available() != 0 ? "loaded" : "not installed")
        Free disk: \(String(format: "%.1f", freeDiskGB)) GB
        Thermal: \(String(describing: ProcessInfo.processInfo.thermalState))

        Preflight
        \(lines.joined(separator: "\n"))
        """
        try? report.write(to: url, atomically: true, encoding: .utf8)
    }

    private static let fileTimestamp: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter
    }()

    private var rendererSection: some View {
        let budget = engine.format.frameDuration * 1000
        return GroupBox(Lf("렌더러 (%@)", "\(engine.format.name)")) {
            HStack(spacing: 24) {
                stat(L("평균"), String(format: "%.1f ms", engine.renderMs))
                stat(L("최대 (1초)"), String(format: "%.1f ms", engine.renderMsPeak), warn: engine.renderMsPeak > budget)
                stat(L("프레임 예산"), String(format: "%.1f ms", budget))
                stat(L("렌더러 드롭"), "\(engine.droppedTicks)", warn: engine.droppedTicks > 0)
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
                    head("#"); head(L("입력")); head(L("형식")); head("FPS"); head(L("비디오 (ms)")); head(L("최대 간격 (2초)")); head(L("PTS 간격")); head(L("최대 프레임 나이 (2초)")); head(L("프로그램 재사용"))
                    head(L("늦은 프레임")); head(L("소스 드롭")); head(L("오디오 버퍼")); head(L("오디오 언더런"))
                    head(L("오디오 경로 (최소 PCM · FF 큐 현재/최대 · 지연/최대)")); head(L("상태"))
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
                GridRow { head(L("출력")); head(L("종류")); head(L("상태")); head(L("인코더 · 비트레이트 · 드롭")) }
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

private struct DashboardStereoMeter: NSViewRepresentable {
    let source: () -> (Float, Float)

    init(source: @escaping () -> (Float, Float)) { self.source = source }

    func makeNSView(context: Context) -> DashboardStereoMeterView {
        let view = DashboardStereoMeterView()
        view.source = source
        return view
    }

    func updateNSView(_ view: DashboardStereoMeterView, context: Context) { view.source = source }
    static func dismantleNSView(_ view: DashboardStereoMeterView, coordinator: ()) { view.stop() }
}

private final class DashboardStereoMeterView: NSView {
    var source: () -> (Float, Float) = { (0, 0) }
    private let tracks = [CALayer(), CALayer()]
    private let fills = [CAGradientLayer(), CAGradientLayer()]
    private let masks = [CALayer(), CALayer()]
    private let channelLabels = [CATextLayer(), CATextLayer()]
    private let valueLabels = [CATextLayer(), CATextLayer()]
    private var timer: Timer?
    private var last: (CGFloat, CGFloat) = (-1, -1)

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.masksToBounds = true
        for index in 0..<2 {
            tracks[index].backgroundColor = NSColor.white.withAlphaComponent(0.08).cgColor
            tracks[index].cornerRadius = 2
            layer?.addSublayer(tracks[index])
            let fill = fills[index]
            fill.colors = [NSColor.systemGreen.cgColor, NSColor.systemGreen.cgColor,
                           NSColor.systemYellow.cgColor, NSColor.systemRed.cgColor]
            fill.locations = [0, 0.68, 0.84, 1]
            fill.startPoint = CGPoint(x: 0, y: 0.5); fill.endPoint = CGPoint(x: 1, y: 0.5)
            fill.cornerRadius = 2
            masks[index].backgroundColor = NSColor.white.cgColor
            fill.mask = masks[index]
            layer?.addSublayer(fill)
            configureText(channelLabels[index], size: 12, weight: .bold, alignment: .left)
            channelLabels[index].string = index == 0 ? "L" : "R"
            configureText(valueLabels[index], size: 11, weight: .medium, alignment: .right)
            layer?.addSublayer(channelLabels[index]); layer?.addSublayer(valueLabels[index])
        }
    }

    required init?(coder: NSCoder) { fatalError() }

    private func configureText(_ text: CATextLayer, size: CGFloat, weight: NSFont.Weight,
                               alignment: CATextLayerAlignmentMode) {
        text.contentsScale = NSScreen.main?.backingScaleFactor ?? 2
        text.font = NSFont.monospacedDigitSystemFont(ofSize: size, weight: weight)
        text.fontSize = size
        text.foregroundColor = NSColor.labelColor.cgColor
        text.alignmentMode = alignment
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil { stop() } else { start() }
    }

    override func layout() {
        super.layout()
        let labelW: CGFloat = 18, valueW: CGFloat = 82, gap: CGFloat = 8
        let meterX = labelW + gap
        let meterW = max(1, bounds.width - meterX - valueW - gap)
        let rowH = bounds.height / 2
        CATransaction.begin(); CATransaction.setDisableActions(true)
        for index in 0..<2 {
            let y = CGFloat(1 - index) * rowH + (rowH - 14) / 2
            channelLabels[index].frame = CGRect(x: 0, y: y - 1, width: labelW, height: 16)
            tracks[index].frame = CGRect(x: meterX, y: y, width: meterW, height: 14)
            fills[index].frame = tracks[index].frame
            valueLabels[index].frame = CGRect(x: bounds.width - valueW, y: y - 1, width: valueW, height: 16)
        }
        CATransaction.commit()
        last = (-1, -1)
        refresh()
    }

    private func start() {
        guard timer == nil else { return }
        let timer = Timer(timeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in self?.refresh() }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        refresh()
    }

    func stop() { timer?.invalidate(); timer = nil }

    private static func fraction(_ level: Float) -> CGFloat {
        let db = level > 0 ? 20 * log10(Double(level)) : -60
        return CGFloat(max(0, min(1, (db + 60) / 60)))
    }

    private func refresh() {
        let levels = source()
        let fractions = (Self.fraction(levels.0), Self.fraction(levels.1))
        let dbs = (levels.0 > 0 ? 20 * log10(Double(levels.0)) : -60,
                   levels.1 > 0 ? 20 * log10(Double(levels.1)) : -60)
        let widths = (fills[0].bounds.width * fractions.0, fills[1].bounds.width * fractions.1)
        CATransaction.begin(); CATransaction.setDisableActions(true)
        masks[0].frame = CGRect(x: 0, y: 0, width: widths.0, height: fills[0].bounds.height)
        masks[1].frame = CGRect(x: 0, y: 0, width: widths.1, height: fills[1].bounds.height)
        valueLabels[0].string = String(format: "%.1f dBFS", dbs.0)
        valueLabels[1].string = String(format: "%.1f dBFS", dbs.1)
        CATransaction.commit()
        last = fractions
    }

    deinit { stop() }
}

private struct PreflightSafetyDashboard: View {
    let engine: SwitcherEngine
    let items: [PreflightItem]
    let lastCheck: Date?
    let runCheck: () -> Void
    let saveReport: () -> Void

    private var pass: Int { items.filter { $0.level == .ok }.count }
    private var warnings: Int { items.filter { $0.level == .warn }.count }
    private var blocked: Int { items.filter { $0.level == .fail }.count }
    private var readiness: Int {
        guard !items.isEmpty else { return 0 }
        return max(0, min(100, Int((Double(pass) + Double(warnings) * 0.5) / Double(items.count) * 100)))
    }

    var body: some View {
        VStack(spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                checklistPanel.frame(width: 285)
                centerPanel.frame(maxWidth: .infinity)
                readinessPanel.frame(width: 250)
            }
            .frame(minHeight: 590)
            HStack(alignment: .top, spacing: 12) {
                incidentPanel.frame(maxWidth: .infinity)
                recoveryPanel.frame(width: 390)
                savePanel.frame(width: 260)
            }
        }
    }

    private var checklistPanel: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text(L("송출 전 점검표")).font(.headline)
                    Text("(\(items.count))").foregroundColor(.secondary)
                    Spacer()
                    summaryLabel(.ok, pass)
                    summaryLabel(.warn, warnings)
                    summaryLabel(.fail, blocked)
                }
                Divider()
                ForEach(items) { item in
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: item.level == .ok ? "checkmark.circle.fill" : (item.level == .warn ? "exclamationmark.triangle.fill" : "xmark.octagon.fill"))
                            .foregroundColor(levelColor(item.level)).frame(width: 15)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(item.title).font(.system(size: 12, weight: .semibold)).lineLimit(1)
                            Text(item.detail).font(.system(size: 10)).foregroundColor(.secondary).lineLimit(2)
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(6)
                    .background(RoundedRectangle(cornerRadius: 5).fill(levelColor(item.level).opacity(0.07)))
                }
                if items.isEmpty {
                    Text(L("점검을 실행하세요.")).foregroundColor(.secondary).frame(maxWidth: .infinity).padding(30)
                }
            }
            .padding(4)
        }
    }

    private var centerPanel: some View {
        VStack(spacing: 10) {
            HStack(spacing: 8) {
                confidenceMonitor(L("미리보기"), color: Theme.preview, footer: engine.input(withID: engine.previewID)?.name ?? "—") {
                    guard let input = engine.input(withID: engine.previewID) else { return nil }
                    return engine.previewComposed ? engine.previewSlot.latest() : input.currentFrame()
                }
                confidenceMonitor(L("프로그램"), color: Theme.program, footer: engine.input(withID: engine.programID)?.name ?? "PGM") {
                    engine.programSlot.latest()
                }
            }
            GroupBox {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Label(L("프로그램 신뢰 상태"), systemImage: blocked == 0 ? "checkmark.circle.fill" : "xmark.octagon.fill")
                            .font(.headline).foregroundColor(blocked == 0 ? .green : .red)
                        Spacer()
                        Text(blocked == 0 ? L("차단 문제 없음") : Lf("차단 문제 %@개", "\(blocked)"))
                            .font(.caption).foregroundColor(.secondary)
                    }
                    HStack(spacing: 6) {
                        confidenceCard(L("비디오"), engine.format.name, blocked == 0)
                        confidenceCard(L("오디오"), masterDBText, max(engine.audioMixer.master.0, engine.audioMixer.master.1) > 0.003)
                        confidenceCard("SRT", engine.srtMonitor.links.isEmpty ? L("연결 없음") : L("연결됨"), !engine.srtMonitor.links.contains { $0.level == 2 })
                        confidenceCard(L("녹화"), outputState(.record), !engine.outputs.contains { $0.config.kind == .record && $0.state == Int32(MC_STATE_ERROR) })
                    }
                }
                .padding(4)
            }
            GroupBox(L("프로그램 오디오")) {
                DashboardStereoMeter { engine.audioMixer.master }
                    .frame(height: 58)
                    .padding(4)
            }
        }
    }

    private func confidenceMonitor(_ title: String, color: Color, footer: String,
                                   source: @escaping () -> CVPixelBuffer?) -> some View {
        VStack(spacing: 0) {
            ZStack(alignment: .topLeading) {
                MonitorView(fps: min(60, max(1, Int(engine.format.fps.rounded()))), source: source)
                    .aspectRatio(16 / 9, contentMode: .fit)
                Text(title.uppercased()).font(.system(size: 11, weight: .bold)).foregroundColor(.black)
                    .padding(.horizontal, 7).padding(.vertical, 3).background(color).cornerRadius(3).padding(7)
            }
            HStack {
                Text(footer).lineLimit(1)
                Spacer()
                Text(engine.format.name).monospacedDigit()
            }
            .font(.system(size: 10, weight: .semibold)).padding(.horizontal, 7).frame(height: 24)
        }
        .background(Color.black)
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(color, lineWidth: 2))
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    private func confidenceCard(_ title: String, _ value: String, _ good: Bool) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.caption).foregroundColor(.secondary)
            HStack(spacing: 4) {
                Image(systemName: good ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                    .foregroundColor(good ? .green : .orange)
                Text(value).lineLimit(1).minimumScaleFactor(0.7)
            }
            .font(.system(size: 10, weight: .semibold))
        }
        .padding(7).frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 5).fill(Color.white.opacity(0.04)))
    }

    private var readinessPanel: some View {
        VStack(spacing: 10) {
            GroupBox(L("방송 준비도")) {
                HStack(spacing: 15) {
                    ZStack {
                        Circle().stroke(Color.white.opacity(0.10), lineWidth: 12)
                        Circle().trim(from: 0, to: CGFloat(readiness) / 100)
                            .stroke(blocked > 0 ? Color.red : (warnings > 0 ? Color.orange : Color.green), style: StrokeStyle(lineWidth: 12, lineCap: .round))
                            .rotationEffect(.degrees(-90))
                        VStack(spacing: 0) {
                            Text("\(readiness)%").font(.system(size: 27, weight: .bold).monospacedDigit())
                            Text(blocked > 0 ? L("차단됨") : L("준비됨")).font(.caption)
                        }
                    }
                    .frame(width: 112, height: 112)
                    VStack(alignment: .leading, spacing: 8) {
                        resultLine(.ok, pass, L("통과"))
                        resultLine(.warn, warnings, L("주의"))
                        resultLine(.fail, blocked, L("차단"))
                    }
                }
                .padding(4)
            }
            GroupBox(Lf("필요한 조치 (%@)", "\(warnings + blocked)")) {
                VStack(spacing: 6) {
                    ForEach(items.filter { $0.level != .ok }.prefix(3)) { item in
                        HStack(alignment: .top, spacing: 7) {
                            Image(systemName: item.level == .fail ? "xmark.octagon.fill" : "exclamationmark.triangle.fill")
                                .foregroundColor(levelColor(item.level))
                            VStack(alignment: .leading, spacing: 1) {
                                Text(item.title).font(.system(size: 11, weight: .semibold))
                                Text(item.detail).font(.system(size: 9)).foregroundColor(.secondary).lineLimit(2)
                            }
                            Spacer()
                        }
                        .padding(6).background(RoundedRectangle(cornerRadius: 5).stroke(levelColor(item.level).opacity(0.55)))
                    }
                    if warnings + blocked == 0 { Text(L("필요한 조치가 없습니다.")).foregroundColor(.secondary).padding(12) }
                }
            }
            Button(action: runCheck) { Label(L("전체 점검 실행"), systemImage: "arrow.clockwise") }
                .buttonStyle(.borderedProminent).controlSize(.large).frame(maxWidth: .infinity)
            GroupBox(L("출력 상태")) {
                VStack(spacing: 7) {
                    ForEach(engine.outputs) { output in
                        HStack {
                            Image(systemName: output.config.kind.symbol)
                            Text(output.config.name).lineLimit(1)
                            Spacer()
                            Circle().fill(output.state == Int32(MC_STATE_ERROR) ? Color.red : (output.running ? Color.green : Color.gray))
                                .frame(width: 9, height: 9)
                            Text(output.running ? L("실행 중") : L("대기")).font(.caption).foregroundColor(.secondary)
                        }
                    }
                    if engine.outputs.isEmpty { Text(L("설정된 출력 없음")).foregroundColor(.secondary) }
                }
                .font(.system(size: 11)).padding(4)
            }
            if let date = lastCheck {
                Text(Lf("마지막 전체 점검: %@", date.formatted(date: .omitted, time: .standard)))
                    .font(.caption2).foregroundColor(.secondary)
            }
        }
    }

    private var incidentPanel: some View {
        GroupBox(L("사고 기록")) {
            VStack(spacing: 5) {
                ForEach(engine.blackbox.incidents.prefix(5)) { incident in
                    HStack(spacing: 8) {
                        Text(incident.time.formatted(date: .omitted, time: .standard)).monospacedDigit().foregroundColor(.secondary)
                        Text(engine.blackbox.kindLabel(incident.kind)).foregroundColor(.orange).frame(width: 80, alignment: .leading)
                        Text(incident.detail).lineLimit(1)
                        Spacer()
                    }
                    .font(.system(size: 10))
                }
                if engine.blackbox.incidents.isEmpty {
                    Label(L("현재 세션에 기록된 사고 없음"), systemImage: "checkmark.circle.fill")
                        .foregroundColor(.green).frame(maxWidth: .infinity, alignment: .leading).padding(8)
                }
            }
            .padding(4)
        }
    }

    private var recoveryPanel: some View {
        GroupBox(L("자동 복구")) {
            VStack(alignment: .leading, spacing: 9) {
                recoveryRow(L("출력 재연결"), L("스트림 엔진에서 자동 재시도"))
                recoveryRow(L("사고 전후 화면 기록"), L("블랙박스 활성화"))
                recoveryRow(L("입력 신호 페일오버"), Lf("백업 지정 %@개", "\(engine.inputs.filter { $0.backupInputID != nil }.count)"))
            }
            .padding(4)
        }
    }

    private func recoveryRow(_ title: String, _ detail: String) -> some View {
        HStack {
            Image(systemName: "checkmark.circle.fill").foregroundColor(.green)
            Text(title).font(.system(size: 11, weight: .semibold))
            Spacer()
            Text(detail).font(.system(size: 10)).foregroundColor(.secondary)
        }
    }

    private var savePanel: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                Button(action: saveReport) { Label(L("진단 보고서 저장…"), systemImage: "square.and.arrow.down") }
                    .controlSize(.large).frame(maxWidth: .infinity)
                Text(L("렌더러, 입출력, SRT, DeckLink, NDI, 저장 공간 및 점검 결과를 지원용 텍스트 파일로 저장합니다."))
                    .font(.caption).foregroundColor(.secondary)
            }
            .padding(4)
        }
    }

    private func summaryLabel(_ level: PreflightItem.Level, _ count: Int) -> some View {
        HStack(spacing: 3) {
            Image(systemName: level == .ok ? "checkmark.circle.fill" : (level == .warn ? "exclamationmark.triangle.fill" : "xmark.octagon.fill"))
            Text("\(count)").monospacedDigit()
        }
        .font(.system(size: 10, weight: .semibold)).foregroundColor(levelColor(level))
    }

    private func resultLine(_ level: PreflightItem.Level, _ count: Int, _ label: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: level == .ok ? "checkmark.circle.fill" : (level == .warn ? "exclamationmark.triangle.fill" : "xmark.octagon.fill"))
                .foregroundColor(levelColor(level))
            Text("\(count)").font(.system(size: 13, weight: .bold).monospacedDigit())
            Text(label).font(.caption).foregroundColor(.secondary)
        }
    }

    private func levelColor(_ level: PreflightItem.Level) -> Color {
        level == .ok ? .green : (level == .warn ? .orange : .red)
    }

    private var masterDBText: String {
        let level = max(engine.audioMixer.master.0, engine.audioMixer.master.1)
        return level > 0 ? String(format: "%.1f dBFS", 20 * log10(Double(level))) : "−∞ dBFS"
    }

    private func outputState(_ kind: OutputKind) -> String {
        let matching = engine.outputs.filter { $0.config.kind == kind }
        if matching.contains(where: { $0.running }) { return L("실행 중") }
        return matching.isEmpty ? L("설정 안 됨") : L("준비")
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
