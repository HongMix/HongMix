import SwiftUI

/// REC ⚙ › Recording safety: disk-time warning, backup recording to a second disk, continue on another disk.
struct RecordingSafetySection: View {
    @ObservedObject var output: OutputChannel
    @ObservedObject var safety: RecordingSafety

    var body: some View {
        Section(L("녹화 안전")) {
            Picker(L("디스크 남은 시간 경고"), selection: $safety.warnMinutes) {
                ForEach(RecordingSafety.warnOptions, id: \.self) { m in
                    Text(m == 0 ? L("끄기") : Lf("%@분 남으면", "\(m)")).tag(m)
                }
            }
            folderRow(L("백업 녹화 (두 번째 디스크)"), path: $output.config.backupFolder,
                      help: L("같은 파일을 두 디스크에 동시에 녹화합니다 (인코딩은 한 번)."))
            Toggle(isOn: $output.config.spillToBackupWhenFull) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(L("디스크가 차면 다른 디스크로 이어서 녹화"))
                    Text(L("다음 파일을 백업 디스크(또는 아래 폴더)에서 이어 갑니다. 프레임 손실 없음."))
                        .font(.caption).foregroundColor(.secondary)
                }
            }
            if output.config.spillToBackupWhenFull {
                folderRow(L("이어서 녹화할 폴더 (비우면 백업 폴더)"), path: $output.config.spillFolder, help: "")
            }
            if output.running {
                if let r = output.remainingSeconds {
                    LabeledContent(L("이 디스크 남은 시간"), value: RecordingDisk.remaining(r))
                }
                if !output.backupFile.isEmpty {
                    LabeledContent(L("백업 파일"), value: (output.backupFile as NSString).lastPathComponent)
                }
                if output.backupState == 2 { Text(L("백업 녹화가 실패했습니다 — 주 녹화는 계속됩니다.")).foregroundColor(.orange) }
                if output.mainDiskFailed { Text(L("주 디스크가 실패해 백업 디스크로 녹화 중입니다.")).foregroundColor(.orange) }
            }
            if !safety.diskWarningMessage.isEmpty {
                Text(safety.diskWarningMessage).foregroundColor(safety.diskCritical ? .red : .orange)
            }
        }
    }

    private func folderRow(_ title: String, path: Binding<String>, help: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                TextField(title, text: path)
                Button(L("선택…")) {
                    let p = NSOpenPanel()
                    p.canChooseDirectories = true
                    p.canChooseFiles = false
                    p.canCreateDirectories = true
                    if p.runModal() == .OK, let u = p.url { path.wrappedValue = u.path }
                }
                if !path.wrappedValue.isEmpty {
                    Button { path.wrappedValue = "" } label: { Image(systemName: "xmark.circle") }.buttonStyle(.borderless)
                }
            }
            if !help.isEmpty { Text(help).font(.caption).foregroundColor(.secondary) }
        }
    }
}

enum RecordingDisk {
    static func remaining(_ s: Double) -> String { RecordingSafety.remainingText(s) }
}

/// Popover next to STREAM: per destination bitrate graph (last 60 s), drops, SRT link, uptime.
struct StreamMonitorView: View {
    @EnvironmentObject var engine: SwitcherEngine

    var body: some View {
        let outs = engine.outputs.filter { $0.config.kind == .stream }
        VStack(alignment: .leading, spacing: 12) {
            Text(L("송출 모니터")).font(.headline)
            if outs.isEmpty { Text(L("설정된 송출이 없습니다.")).foregroundColor(.secondary) }
            ForEach(outs) { StreamMonitorRow(output: $0) }
            Text(L("최근 60초 비트레이트 · 주황 = 드롭")).font(.caption).foregroundColor(.secondary)
        }
        .padding(14)
        .frame(width: 420)
    }
}

private struct StreamMonitorRow: View {
    @ObservedObject var output: OutputChannel

    var body: some View {
        let h = output.history
        let last = h.last
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Circle().fill(!output.running ? Color.secondary : (last?.connected == false ? Color.orange : Color.green))
                    .frame(width: 8, height: 8)
                Text(output.config.name).fontWeight(.semibold).lineLimit(1)
                Spacer()
                if output.running, let since = output.connectedSince {
                    Text(Self.uptime(Date().timeIntervalSince(since))).monospacedDigit().foregroundColor(.secondary)
                }
            }
            HStack(spacing: 10) {
                Text(String(format: "%.1f Mbps", (last?.kbps ?? 0) / 1000)).monospacedDigit()
                Text(Lf("드롭 %@", "\(h.reduce(0) { $0 + $1.framesDropped })"))
                if let rtt = last?.rttMs { Text(String(format: "RTT %.0f ms", rtt)) }
                if let loss = last?.lossPercent { Text(String(format: "loss %.1f%%", loss)) }
                if output.reconnectCount > 0 { Text(Lf("재연결 %@", "\(output.reconnectCount)")).foregroundColor(.orange) }
            }
            .font(.caption)
            GeometryReader { g in
                let maxK = max(1, h.map(\.kbps).max() ?? 1)
                HStack(alignment: .bottom, spacing: 1) {
                    ForEach(Array(h.enumerated()), id: \.offset) { _, s in
                        Rectangle()
                            .fill(s.framesDropped > 0 || !s.connected ? Color.orange : Color.primary.opacity(0.75))
                            .frame(height: max(1, g.size.height * CGFloat(s.kbps / maxK)))
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
            }
            .frame(height: 46)
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color.secondary.opacity(0.08)))
    }

    static func uptime(_ t: TimeInterval) -> String {
        let s = Int(t)
        return String(format: "%d:%02d:%02d", s / 3600, s / 60 % 60, s % 60)
    }
}
