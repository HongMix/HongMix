import SwiftUI
import AppKit

/// Instant Replay controller (Window id "replay"): recording, A/B channels, transport, marks, events.
struct ReplayView: View {
    @EnvironmentObject var engine: SwitcherEngine
    @ObservedObject var replay = ReplayEngine.shared
    @ViewState private var showSettings = false
    @ViewState private var message: String? = nil

    private var cameraNames: [String] {
        let ids = replay.recording || !replay.cameraIDs.isEmpty ? replay.cameraIDs : replay.settings.cameraIDs.compactMap { UUID(uuidString: $0) }
        return ids.map { id in engine.input(withID: id).map { "\(engine.number(of: $0)). \($0.name)" } ?? "—" }
    }

    var body: some View {
        VStack(spacing: 10) {
            header
            HStack(alignment: .top, spacing: 10) {
                channelPanel(0)
                channelPanel(1)
            }
            transport
            marks
            eventList
        }
        .padding(12)
        .background(Color(white: 0.08))
        .frame(minWidth: 980, minHeight: 640)
        .sheet(isPresented: $showSettings) { ReplaySettingsSheet().environmentObject(engine) }
        .onAppear { replay.engine = engine; replay.refreshStatus() }
    }

    // MARK: Header: record + status

    private var header: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 1) {
                Text("HONGMIX REPLAY").font(.system(size: 15, weight: .black, design: .rounded))
                Text(L("두 개의 독립 재생 덱 · 프레임 정밀 TC")).font(.system(size: 9, weight: .medium)).foregroundColor(.secondary)
            }
            Divider().frame(height: 34)
            Button {
                if replay.recording { replay.stopRecording() } else { message = replay.startRecording() }
            } label: {
                HStack(spacing: 6) {
                    Circle().fill(replay.recording ? Color.red : Color(white: 0.5)).frame(width: 10, height: 10)
                    Text(replay.recording ? "REC" : L("녹화 시작")).font(.system(size: 12, weight: .heavy))
                }
                .padding(.horizontal, 12).frame(height: 28)
                .background(RoundedRectangle(cornerRadius: 5).fill(replay.recording ? Theme.live.opacity(0.35) : Theme.button))
            }
            .buttonStyle(.plain)
            .keyboardShortcut("r", modifiers: [.command, .shift])
            VStack(alignment: .leading, spacing: 2) {
                Text(statusLine).font(.system(size: 11, weight: .semibold).monospacedDigit())
                Text(diskLine).font(.system(size: 10).monospacedDigit()).foregroundColor(.secondary)
            }
            Spacer()
            timecodeReadout(label: "REC TC", value: replay.recordTimecode(), color: replay.recording ? .red : .secondary)
            timecodeReadout(label: "SELECTED TC", value: replay.selectedTimecode(), color: Theme.preview)
            TimelineView(.periodic(from: .now, by: 1.0 / max(1, engine.format.fps))) { context in
                VStack(alignment: .trailing, spacing: 2) {
                    timecodeReadout(label: "SYSTEM TC", value: replay.systemTimecode(context.date), color: .green)
                    Text("REC START  \(replay.recordingStartText())")
                        .font(.system(size: 9, weight: .semibold, design: .monospaced)).foregroundColor(.secondary)
                }
            }
            if let m = message { Text(m).font(.caption).foregroundColor(.orange).lineLimit(2) }
            Picker("", selection: Binding(get: { replay.selected == [0, 1] ? 2 : (replay.selected.first ?? 0) },
                                          set: { replay.selected = $0 == 2 ? [0, 1] : [$0] })) {
                Text("A").tag(0)
                Text("B").tag(1)
                Text("A+B").tag(2)
            }
            .pickerStyle(.segmented).labelsHidden().frame(width: 140)
            .help(L("전송 버튼이 움직일 채널"))
            Button { showSettings = true } label: { Image(systemName: "gearshape") }
                .help(L("리플레이 설정 — 카메라, 화질, 저장 위치"))
        }
    }

    private func timecodeReadout(label: String, value: String, color: Color) -> some View {
        VStack(alignment: .trailing, spacing: 1) {
            Text(label).font(.system(size: 8, weight: .bold)).foregroundColor(color)
            Text(value).font(.system(size: 17, weight: .semibold, design: .monospaced)).foregroundColor(.white)
        }
        .padding(.horizontal, 9).padding(.vertical, 4)
        .background(RoundedRectangle(cornerRadius: 5).fill(Color.black.opacity(0.75)))
        .overlay(RoundedRectangle(cornerRadius: 5).stroke(color.opacity(0.5), lineWidth: 1))
    }

    private var statusLine: String {
        let s = replay.status
        let cams = replay.recording ? s.cameras : replay.settings.cameraIDs.count
        let buf = Int(s.bufferedSeconds)
        return String(format: "%@ · %d cam · %@ %02d:%02d:%02d", replay.recording ? "Recording" : "Stopped", cams,
                      L("버퍼"), buf / 3600, (buf / 60) % 60, buf % 60)
    }

    private var diskLine: String {
        let s = replay.status
        let est = replay.estimate(cameras: max(1, replay.recording ? s.cameras : replay.settings.cameraIDs.count))
        return Lf("사용 %@ · 남은 공간 %@ · 이 설정으로 약 %@시간 녹화 가능%@",
                  OutputConfig.bytesText(s.bytes), OutputConfig.bytesText(est.free), String(format: "%.1f", est.hours),
                  replay.settings.autoDelete ? L(" · 가득 차면 오래된 것부터 자동 삭제") : "")
    }

    // MARK: Channels

    private func channelPanel(_ c: Int) -> some View {
        let ui = replay.channelsUI[c]
        let input = engine.inputs.first { ($0 as? ReplayInput)?.channel == c }
        let sel = replay.selected.contains(c)
        return VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(c == 0 ? "DECK A" : "DECK B").font(.system(size: 13, weight: .heavy))
                Text(ui.live ? "LIVE" : (ui.playing ? "PLAY" : "PAUSE"))
                    .font(.system(size: 10, weight: .heavy)).foregroundColor(.white)
                    .padding(.horizontal, 6).padding(.vertical, 1)
                    .background(RoundedRectangle(cornerRadius: 3).fill(ui.live ? Theme.program : (ui.playing ? Theme.live : Color.gray)))
                if let n = ui.eventNumber { Text(String(format: "EVT %04d", n)).font(.system(size: 10, weight: .bold).monospacedDigit()).foregroundColor(.secondary) }
                Spacer()
                Text(ui.live ? "" : String(format: "%@%.0f%% · -%.1fs", ui.reverse ? "◀ " : "", ui.speed * 100, ui.behindLive))
                    .font(.system(size: 11, weight: .semibold).monospacedDigit())
            }
            ZStack {
                Color.black
                if let i = input {
                    MonitorView(fps: 30) { i.currentFrame() }
                } else {
                    Text(c == 0 ? L("Replay A 입력이 없습니다 — 입력 추가 › Instant Replay") : L("Replay B 입력이 없습니다 — 입력 추가 › Instant Replay"))
                        .font(.caption).foregroundColor(.secondary).multilineTextAlignment(.center).padding()
                }
            }
            .aspectRatio(16 / 9, contentMode: .fit)
            .overlay(RoundedRectangle(cornerRadius: 3).stroke(sel ? Theme.preview : Color.clear, lineWidth: 2))
            .onTapGesture { replay.selected = [c] }
            HStack(spacing: 4) {
                ForEach(Array(cameraNames.enumerated()), id: \.offset) { k, name in
                    Button { replay.setCamera(k, channels: [c]) } label: {
                        Text("\(k + 1)").font(.system(size: 12, weight: .bold))
                            .frame(width: 30, height: 24)
                            .background(RoundedRectangle(cornerRadius: 3).fill(ui.camera == k ? Theme.accent : Theme.button))
                    }
                    .buttonStyle(.plain)
                    .help(name)
                }
                Spacer()
                Button(L("LIVE")) { replay.goLive([c]) }.disabled(ui.live)
            }
            let bounds = replay.timelineBounds()
            VStack(spacing: 2) {
                HStack {
                    Text(replay.timecode(Int64(bounds.lowerBound))).foregroundColor(.secondary)
                    Spacer()
                    Text(replay.timecode(ui.position)).foregroundColor(ui.live ? Theme.program : Theme.preview)
                    Text("·").foregroundColor(.secondary)
                    Text(replay.recordedClockTimecode(ui.position)).foregroundColor(.white)
                    Spacer()
                    Text("LIVE").foregroundColor(Theme.program)
                }
                .font(.system(size: 9, weight: .semibold, design: .monospaced))
                Slider(value: Binding(get: { min(bounds.upperBound, max(bounds.lowerBound, Double(ui.position))) },
                                      set: { replay.seekTimeline($0, channel: c) }), in: bounds)
                    .tint(ui.live ? Theme.program : Theme.preview)
            }
            .help(L("현재 PLAY TC와 실제 녹화 시각 — 드래그하여 원하는 시점으로 이동"))
            HStack {
                Text("PLAY TC").font(.system(size: 8, weight: .bold)).foregroundColor(.secondary)
                Text(replay.timecode(ui.position)).font(.system(size: 14, weight: .semibold, design: .monospaced))
                Spacer()
                Text(ui.live ? L("녹화 헤드 추적 중") : String(format: "LIVE − %.2fs", ui.behindLive))
                    .font(.system(size: 10, weight: .semibold).monospacedDigit())
                    .foregroundColor(ui.live ? Theme.program : .orange)
            }
            .padding(.horizontal, 7).frame(height: 25)
            .background(RoundedRectangle(cornerRadius: 3).fill(Color.black.opacity(0.65)))
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color(white: 0.12)))
    }

    // MARK: Transport

    private var transport: some View {
        HStack(spacing: 6) {
            tbtn("backward.end.fill", L("5초 뒤로")) { replay.jump(seconds: -5) }
            tbtn("backward.frame.fill", L("1프레임 뒤로")) { replay.jump(frames: -1) }
                .keyboardShortcut(.leftArrow, modifiers: [])
            let playing = replay.selected.contains { replay.channelsUI[$0].playing }
            tbtn(playing ? "pause.fill" : "play.fill", L("재생 / 일시정지 (Space)"), wide: true) { replay.playPause() }
                .keyboardShortcut(.space, modifiers: [])
            tbtn("forward.frame.fill", L("1프레임 앞으로")) { replay.jump(frames: 1) }
                .keyboardShortcut(.rightArrow, modifiers: [])
            tbtn("forward.end.fill", L("5초 앞으로")) { replay.jump(seconds: 5) }
            Divider().frame(height: 24)
            let cur = replay.channelsUI[replay.selected.min() ?? 0]
            ForEach([0.25, 0.5, 0.75, 1.0, 2.0], id: \.self) { v in
                Button { replay.setSpeed(v) } label: {
                    Text(String(format: "%.0f%%", v * 100)).font(.system(size: 11, weight: .bold).monospacedDigit())
                        .frame(width: 46, height: 26)
                        .background(RoundedRectangle(cornerRadius: 3).fill(abs(cur.speed - v) < 0.001 ? Theme.accent : Theme.button))
                }
                .buttonStyle(.plain)
            }
            Slider(value: Binding(get: { cur.speed }, set: { replay.setSpeed($0) }), in: 0.05...2)
                .frame(width: 140)
            Toggle(L("역재생"), isOn: Binding(get: { cur.reverse }, set: { replay.setReverse($0) }))
                .toggleStyle(.button)
            Spacer()
            Button(L("LIVE (선택 채널)")) { replay.goLive() }
        }
    }

    private func tbtn(_ sym: String, _ help: String, wide: Bool = false, _ f: @escaping () -> Void) -> some View {
        Button(action: f) {
            Image(systemName: sym).font(.system(size: 13, weight: .semibold))
                .frame(width: wide ? 56 : 36, height: 28)
                .background(RoundedRectangle(cornerRadius: 4).fill(Theme.button))
        }
        .buttonStyle(.plain)
        .help(help)
    }

    // MARK: Marks

    private var marks: some View {
        HStack(spacing: 8) {
            mbtn(replay.pendingIn != nil ? "IN UPDATE" : "SET IN", Theme.preview) { replay.markIn() }
                .keyboardShortcut("i", modifiers: [])
            mbtn("SET OUT / SAVE CLIP", Theme.preview) { replay.markOut() }
                .keyboardShortcut("o", modifiers: [])
            VStack(alignment: .leading, spacing: 1) {
                Text(replay.pendingIn == nil ? "IN  --:--:--:--" : "IN  \(replay.timecode(replay.pendingIn!))")
                Text("DUR \(replay.pendingDuration() ?? "--:--:--:--")")
            }
            .font(.system(size: 10, weight: .semibold, design: .monospaced))
            .foregroundColor(replay.pendingIn == nil ? .secondary : Theme.preview)
            .padding(.horizontal, 8).frame(height: 30)
            .background(RoundedRectangle(cornerRadius: 4).fill(Color.black.opacity(0.7)))
            ForEach([5.0, 10.0, 20.0], id: \.self) { s in
                mbtn(String(format: "QUICK %.0fs", s), Theme.button) { replay.markInOut(seconds: s) }
                    .help(Lf("지난 %@초를 이벤트로 저장", String(format: "%.0f", s)))
            }
            Divider().frame(height: 24)
            mbtn(L("▶ 마지막 클립"), Theme.button) { replay.playLastEvent() }
            mbtn(L("클립 TAKE"), Theme.live) { message = replay.replayToProgram() }
                .help(L("마지막 이벤트를 Replay A로 재생하면서 프로그램에 올리고, 끝나면 원래 화면으로 돌아갑니다"))
            Spacer()
        }
    }

    private func mbtn(_ title: String, _ color: Color, _ f: @escaping () -> Void) -> some View {
        Button(action: f) {
            Text(title).font(.system(size: 11, weight: .heavy))
                .padding(.horizontal, 10).frame(height: 28)
                .background(RoundedRectangle(cornerRadius: 4).fill(color.opacity(0.85)))
        }
        .buttonStyle(.plain)
    }

    // MARK: Events

    private var eventList: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(L("CLIP BIN")).font(.system(size: 12, weight: .bold))
                Text("\(replay.events.count)").font(.caption).foregroundColor(.secondary)
                Spacer()
                Text(L("더블클릭 = Deck A 로드 · I / O = IN / OUT · Space = 재생")).font(.caption).foregroundColor(.secondary)
            }
            HStack(spacing: 10) {
                Text("CLIP").frame(width: 44, alignment: .leading)
                Text("IN TC").frame(width: 102, alignment: .leading)
                Text("OUT TC").frame(width: 102, alignment: .leading)
                Text("DURATION").frame(width: 78, alignment: .leading)
                Text("ANGLE").frame(width: 90, alignment: .leading)
                Text("NAME")
            }
            .font(.system(size: 9, weight: .bold)).foregroundColor(.secondary).padding(.horizontal, 8)
            List {
                ForEach(replay.events.reversed()) { e in
                    HStack(spacing: 10) {
                        Text(String(format: "%04d", e.number)).font(.system(size: 12, weight: .bold).monospacedDigit()).frame(width: 44, alignment: .leading)
                        Text(replay.timecode(e.inFrame)).font(.system(size: 11).monospacedDigit()).frame(width: 102, alignment: .leading)
                        Text(replay.timecode(e.outFrame)).font(.system(size: 11).monospacedDigit()).frame(width: 102, alignment: .leading)
                        Text(replay.duration(e)).font(.system(size: 11).monospacedDigit()).frame(width: 78, alignment: .leading)
                        Picker("", selection: Binding(get: { e.camera }, set: { replay.setEventCamera(e.id, $0) })) {
                            ForEach(Array(cameraNames.enumerated()), id: \.offset) { k, n in Text("Cam \(k + 1)").tag(k) }
                        }
                        .labelsHidden().frame(width: 90)
                        Text(e.name.isEmpty ? (cameraNames.indices.contains(e.camera) ? cameraNames[e.camera] : "") : e.name)
                            .font(.system(size: 11)).foregroundColor(.secondary).lineLimit(1)
                        Spacer()
                        Button("A") { replay.playEvent(e, channels: [0]) }
                        Button("B") { replay.playEvent(e, channels: [1]) }
                        Button(role: .destructive) { replay.deleteEvent(e.id) } label: { Image(systemName: "trash") }
                            .buttonStyle(.borderless)
                    }
                    .contentShape(Rectangle())
                    .onTapGesture(count: 2) { replay.playEvent(e, channels: [0]) }
                }
            }
            .frame(minHeight: 140)
        }
    }
}

/// Replay settings: cameras (angles), quality, folder, disk limit.
struct ReplaySettingsSheet: View {
    @EnvironmentObject var engine: SwitcherEngine
    @ObservedObject var replay = ReplayEngine.shared
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(L("리플레이 설정")).font(.headline)
            Form {
                Section(Lf("카메라 (앵글, 최대 %@개) — 위에서부터 Cam 1, 2, 3 …", "\(ReplaySettings.maxCameras)")) {
                    ForEach(engine.inputs.filter { !($0 is ReplayInput) }) { i in
                        Toggle("\(engine.number(of: i)). \(i.name)", isOn: Binding(
                            get: { replay.settings.cameraIDs.contains(i.id.uuidString) },
                            set: { on in
                                var ids = replay.settings.cameraIDs.filter { $0 != i.id.uuidString }
                                if on && ids.count < ReplaySettings.maxCameras { ids.append(i.id.uuidString) }
                                replay.settings.cameraIDs = ids
                            }))
                    }
                }
                Section(L("화질 · 저장")) {
                    Picker(L("화질 (카메라당)"), selection: $replay.settings.quality) {
                        Text(L("보통 · 20 Mbps")).tag(20_000)
                        Text(L("높음 · 35 Mbps (권장)")).tag(35_000)
                        Text(L("최고 · 60 Mbps")).tag(60_000)
                        Text(L("4K · 100 Mbps")).tag(100_000)
                    }
                    HStack {
                        Text(replay.settings.folderPath).lineLimit(1).truncationMode(.middle)
                        Spacer()
                        Button(L("폴더 선택…")) {
                            let p = NSOpenPanel()
                            p.canChooseDirectories = true; p.canChooseFiles = false; p.canCreateDirectories = true
                            if p.runModal() == .OK, let u = p.url { replay.settings.folder = u.path }
                        }
                    }
                    HStack {
                        Text(L("최대 용량"))
                        TextField("", value: $replay.settings.maxGB, format: .number).frame(width: 70)
                        Text(L("GB (0 = 디스크 남은 공간까지)")).foregroundColor(.secondary)
                    }
                    Toggle(L("가득 차면 가장 오래된 영상부터 지우고 계속 녹화"), isOn: $replay.settings.autoDelete)
                    let est = replay.estimate(cameras: max(1, replay.settings.cameraIDs.count))
                    Text(Lf("카메라 %@대 · 시간당 %@ · 남은 공간 %@ → 약 %@시간 녹화 가능",
                            "\(max(1, replay.settings.cameraIDs.count))", OutputConfig.bytesText(est.perHour),
                            OutputConfig.bytesText(est.free), String(format: "%.1f", est.hours)))
                        .font(.caption).monospacedDigit().foregroundColor(.secondary)
                }
                Section(L("재생")) {
                    Toggle(L("REPLAY → 프로그램: 이벤트가 끝나면 원래 화면으로 돌아가기"), isOn: $replay.settings.autoReturn)
                    HStack {
                        Text(L("프리롤"))
                        Slider(value: $replay.settings.preRoll, in: 0...5, step: 0.5).frame(width: 160)
                        Text(String(format: "%.1fs", replay.settings.preRoll)).monospacedDigit()
                    }
                }
                Section {
                    Button(L("녹화된 영상과 이벤트 모두 삭제"), role: .destructive) { replay.clearAll() }
                    Text(L("카메라를 바꾸면 다음 녹화 시작 때 새 세션으로 시작합니다. 영상은 프레임마다 독립 압축(인트라)으로 저장되어 슬로모션·역재생·프레임 이동이 정확합니다."))
                        .font(.caption).foregroundColor(.secondary)
                }
            }
            .formStyle(.grouped)
            HStack { Spacer(); Button(L("닫기")) { dismiss() }.keyboardShortcut(.defaultAction) }
        }
        .padding(16)
        .frame(width: 560, height: 620)
    }
}

/// Bottom-bar button that opens the replay window.
struct ReplayButton: View {
    @Environment(\.openWindow) private var openWindow
    @ObservedObject var replay = ReplayEngine.shared

    var body: some View {
        Button { openWindow(id: "replay") } label: {
            Image(systemName: "gobackward")
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(.white)
                .frame(width: 34, height: 30)
                .background(replay.recording ? Theme.live.opacity(0.7) : Theme.button)
                .clipShape(RoundedRectangle(cornerRadius: 3))
        }
        .buttonStyle(.plain)
        .help(L("Instant Replay — 녹화 · 마크 · 슬로모션 재생"))
    }
}
