import SwiftUI
import AppKit

/// CAM 1–4 colours (replay window, clip angles, input-tile R chips).
enum ReplayColors {
    static let cams: [Color] = [
        Color(red: 0.23, green: 0.51, blue: 0.97),   // CAM 1 blue
        Color(red: 0.85, green: 0.54, blue: 0.17),   // CAM 2 orange
        Color(red: 0.56, green: 0.36, blue: 0.85),   // CAM 3 purple
        Color(red: 0.16, green: 0.62, blue: 0.56),   // CAM 4 teal
    ]
    static let deck: [Color] = [Theme.preview, Color(red: 0.23, green: 0.51, blue: 0.97)]
    static let clock = Color(red: 1.0, green: 0.84, blue: 0.04)
    static func cam(_ k: Int) -> Color { cams[max(0, min(cams.count - 1, k))] }
}

/// Instant Replay controller (Window id "replay"): recording, A/B decks, CAM 1–4 sources, transport, clips.
struct ReplayView: View {
    @EnvironmentObject var engine: SwitcherEngine
    @ObservedObject var replay = ReplayEngine.shared
    @ViewState private var showSettings = false
    @ViewState private var message: String? = nil
    @ViewState private var exportSelection: Set<UUID> = []
    @ViewState private var exportEvents: [ReplayEvent] = []

    private func sourceName(_ k: Int) -> String {
        guard let id = replay.settings.slots[k], let i = engine.input(withID: id) else { return "—" }
        return "\(engine.number(of: i)). \(i.name)"
    }

    var body: some View {
        VStack(spacing: 10) {
            header
            HStack(alignment: .top, spacing: 10) {
                channelPanel(0)
                channelPanel(1)
            }
            .layoutPriority(1)      // decks get the height first; the clip list must not squeeze them
            sources
            transport
            marks
            eventList
        }
        .padding(12)
        .background(Color(white: 0.08))
        .frame(minWidth: 1200, minHeight: 820)
        .sheet(isPresented: $showSettings) { ReplaySettingsSheet().environmentObject(engine) }
        .sheet(isPresented: Binding(get: { !exportEvents.isEmpty }, set: { if !$0 { exportEvents = [] } })) {
            ReplayExportSheet(events: exportEvents, fps: replay.frameRate)
        }
        .onAppear { replay.engine = engine; replay.refreshStatus(); replay.setWindowVisible(true) }
        .onDisappear { replay.setWindowVisible(false) }
        .background(cameraKeys)
    }

    /// Keys 1–4 = angle of the selected deck(s).
    private var cameraKeys: some View {
        ZStack {
            ForEach(0..<ReplaySettings.maxCameras, id: \.self) { k in
                Button("") { replay.setCamera(k) }
                    .keyboardShortcut(KeyEquivalent(Character("\(k + 1)")), modifiers: [])
            }
        }
        .opacity(0).frame(width: 0, height: 0)
    }

    // MARK: Header: record + status

    private var header: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 1) {
                Text("HONGMIX REPLAY").font(.system(size: 15, weight: .black, design: .rounded))
                Text(L("4-feed ISO · 프레임 정밀 TC")).font(.system(size: 9, weight: .medium)).foregroundColor(.secondary)
            }
            .fixedSize()
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
            .fixedSize()
            .keyboardShortcut("r", modifiers: [.command, .shift])
            VStack(alignment: .leading, spacing: 2) {
                Text(statusLine).font(.system(size: 11, weight: .semibold).monospacedDigit())
                    .lineLimit(1).minimumScaleFactor(0.8)
                Text(diskLine).font(.system(size: 10).monospacedDigit()).foregroundColor(.secondary).lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(minWidth: 160, alignment: .leading)
            .help(diskLine)
            Spacer()
            timecodeReadout(label: "REC TC", value: replay.recordTimecode(), color: replay.recording ? .red : .secondary)
            VStack(alignment: .trailing, spacing: 0) {
                Text(L("SELECTED · TC / 녹화 시각")).font(.system(size: 8, weight: .bold)).foregroundColor(Theme.preview)
                Text(replay.selectedTimecode()).font(.system(size: 17, weight: .semibold, design: .monospaced)).foregroundColor(.white)
                Text(replay.selectedClock()).font(.system(size: 13, weight: .semibold, design: .monospaced)).foregroundColor(ReplayColors.clock)
            }
            .padding(.horizontal, 9).padding(.vertical, 3)
            .background(RoundedRectangle(cornerRadius: 5).fill(Color.black.opacity(0.75)))
            .overlay(RoundedRectangle(cornerRadius: 5).stroke(Theme.preview.opacity(0.5), lineWidth: 1))
            .fixedSize()
            .help(L("선택한 덱 위치의 TC와 그 장면이 실제로 녹화된 시각"))
            TimelineView(.periodic(from: .now, by: 1.0 / max(1, engine.format.fps))) { context in
                VStack(alignment: .trailing, spacing: 2) {
                    timecodeReadout(label: "SYSTEM TC", value: replay.systemTimecode(context.date), color: .green)
                    Text("REC START  \(replay.recordingStartText())")
                        .font(.system(size: 9, weight: .semibold, design: .monospaced)).foregroundColor(.secondary)
                }
                .fixedSize()
            }
            if let m = message {
                Text(m).font(.caption).foregroundColor(.orange).lineLimit(2)
                    .frame(maxWidth: 220, alignment: .leading).help(m)
            }
            Picker("", selection: Binding(get: { replay.selected == [0, 1] ? 2 : (replay.selected.first ?? 0) },
                                          set: { replay.selected = $0 == 2 ? [0, 1] : [$0] })) {
                Text("A").tag(0)
                Text("B").tag(1)
                Text("A+B").tag(2)
            }
            .pickerStyle(.segmented).labelsHidden().frame(width: 140).fixedSize()
            .help(L("전송 버튼이 움직일 채널"))
            Button { showSettings = true } label: { Image(systemName: "gearshape") }
                .help(L("리플레이 설정 — 소스, 녹화 형식, 슬로모션, 저장 위치"))
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
        .fixedSize()
    }

    private var statusLine: String {
        let s = replay.status
        let cams = replay.recording ? s.cameras : replay.settings.assignedCount
        let buf = Int(s.bufferedSeconds)
        return String(format: "%@ · %d cam · %@ %02d:%02d:%02d", replay.recording ? "Recording" : "Stopped", cams,
                      L("버퍼"), buf / 3600, (buf / 60) % 60, buf % 60)
    }

    private var diskLine: String {
        let s = replay.status
        let est = replay.estimate(cameras: max(1, replay.recording ? s.cameras : replay.settings.assignedCount))
        return Lf("사용 %@ · 남은 공간 %@ · 약 %@시간 · %@ ×%@%@",
                  OutputConfig.bytesText(s.bytes), OutputConfig.bytesText(est.free), String(format: "%.1f", est.hours),
                  replay.settings.codecLabel, "\(max(1, replay.settings.assignedCount))",
                  replay.settings.autoDelete ? L(" · 가득 차면 오래된 것부터 삭제") : "")
    }

    // MARK: Decks

    private func badge(_ text: String, _ color: Color, dark: Bool = false) -> some View {
        Text(text).font(.system(size: 10, weight: .heavy)).foregroundColor(dark ? .black : .white)
            .padding(.horizontal, 6).padding(.vertical, 1)
            .background(RoundedRectangle(cornerRadius: 3).fill(color))
    }

    private func channelPanel(_ c: Int) -> some View {
        let ui = replay.channelsUI[c]
        let sel = replay.selected.contains(c)
        let deckColor = ReplayColors.deck[c]
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text(c == 0 ? "DECK A" : "DECK B").font(.system(size: 13, weight: .heavy))
                badge(ui.live ? "LIVE" : (ui.playing ? "PLAY" : "PAUSE"), ui.live ? Theme.program : (ui.playing ? Theme.live : Color.gray))
                badge("CAM \(ui.camera + 1)", ReplayColors.cam(ui.camera), dark: ui.camera == 1)
                if !ui.smoothing.isEmpty {
                    badge(ui.smoothing, ui.smoothing.hasPrefix("AI") ? Color(red: 0.55, green: 0.3, blue: 0.9) : Color(white: 0.35))
                        .help(L("슬로모션 보간: AI = AI 렌더 프레임, AI RT = 실시간 AI, BLEND = GPU 블렌딩"))
                }
                if let n = ui.eventNumber { Text(String(format: "EVT %04d", n)).font(.system(size: 10, weight: .bold).monospacedDigit()).foregroundColor(.secondary) }
                Spacer()
                Text(ui.live ? "" : String(format: "%@%.0f%% · -%.1fs", ui.reverse ? "◀ " : "", ui.speed * 100, ui.behindLive))
                    .font(.system(size: 11, weight: .semibold).monospacedDigit())
                Button(L("LIVE")) { replay.goLive([c]) }.disabled(ui.live).controlSize(.small)
            }
            .lineLimit(1)
            ZStack(alignment: .bottomLeading) {
                Color.black
                MonitorView(fps: 30) { replay.deckSlots[c].latest() }
                Text(burnText(ui)).font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .lineLimit(1).minimumScaleFactor(0.6)
                    .foregroundColor(.white)
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(RoundedRectangle(cornerRadius: 3).fill(Color.black.opacity(0.65)))
                    .padding(6)
                if !ui.attached && c == 0 {
                    Text(L("TAKE(프로그램 송출)용 Replay A 입력 없음 — 입력 추가 › Instant Replay"))
                        .font(.system(size: 9)).foregroundColor(.secondary)
                        .lineLimit(2).minimumScaleFactor(0.8)
                        .padding(4).background(Color.black.opacity(0.6))
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                }
            }
            .aspectRatio(16 / 9, contentMode: .fit)
            .clipped()
            .overlay(RoundedRectangle(cornerRadius: 3).stroke(sel ? deckColor : Color.clear, lineWidth: 2))
            .onTapGesture { replay.selected = [c] }
            let bounds = replay.timelineBounds()
            VStack(spacing: 2) {
                HStack {
                    Text(replay.timecode(Int64(bounds.lowerBound))).foregroundColor(.secondary)
                    Spacer()
                    Text(replay.recordedClockTimecode(Int64(bounds.lowerBound))).foregroundColor(.secondary)
                    Text("→")
                    Text(replay.recordedClockTimecode(Int64(bounds.upperBound))).foregroundColor(.secondary)
                    Spacer()
                    Text("LIVE").foregroundColor(Theme.program)
                }
                .font(.system(size: 9, weight: .semibold, design: .monospaced))
                .lineLimit(1).minimumScaleFactor(0.7)
                Slider(value: Binding(get: { min(bounds.upperBound, max(bounds.lowerBound, Double(ui.position))) },
                                      set: { replay.seekTimeline($0, channel: c) }), in: bounds)
                    .tint(ui.live ? Theme.program : deckColor)
            }
            .help(L("녹화된 범위 (TC · 녹화 시각) — 드래그하여 원하는 시점으로 이동"))
            HStack(spacing: 10) {
                Text("PLAY TC").font(.system(size: 8, weight: .bold)).foregroundColor(.secondary)
                Text(replay.timecode(ui.position)).font(.system(size: 14, weight: .semibold, design: .monospaced))
                Text(L("녹화 시각")).font(.system(size: 8, weight: .bold)).foregroundColor(.secondary)
                Text(replay.recordedClockTimecode(ui.position)).font(.system(size: 14, weight: .semibold, design: .monospaced))
                    .foregroundColor(ReplayColors.clock)
                Spacer()
                Text(ui.live ? "LIVE" : String(format: "LIVE − %.2fs", ui.behindLive))
                    .font(.system(size: 10, weight: .semibold).monospacedDigit())
                    .foregroundColor(ui.live ? Theme.program : .orange)
            }
            .lineLimit(1).minimumScaleFactor(0.75)
            .padding(.horizontal, 7).frame(height: 25)
            .background(RoundedRectangle(cornerRadius: 3).fill(Color.black.opacity(0.65)))
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color(white: 0.12)))
    }

    private func burnText(_ ui: ReplayChannelUI) -> String {
        let clock = replay.recordedClockTimecode(ui.position)
        return ui.live ? "CAM \(ui.camera + 1) · LIVE · \(clock)" : "CAM \(ui.camera + 1) · \(replay.timecode(ui.position)) · \(clock)"
    }

    // MARK: Sources (CAM 1–4)

    private var sources: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("REPLAY SOURCES").font(.system(size: 12, weight: .bold)).fixedSize()
                Spacer()
                Text(L("클릭 / 1–4 키 = 선택한 덱 앵글 전환 · ▾ 에서 입력 선택 (입력 타일의 R 칩으로도 지정)"))
                    .font(.caption).foregroundColor(.secondary)
                    .lineLimit(2).multilineTextAlignment(.trailing).fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 8) {
                ForEach(0..<ReplaySettings.maxCameras, id: \.self) { k in sourceBox(k) }
            }
        }
    }

    @ViewBuilder private func sourceMenu(_ k: Int) -> some View {
        Button(L("없음 (녹화 안 함)")) { replay.setSource(k, nil) }
        Divider()
        ForEach(engine.inputs.filter { !($0 is ReplayInput) }) { i in
            let other = replay.slot(of: i.id)
            Button("\(engine.number(of: i)). \(i.name)" + (other != nil && other != k ? "  (CAM \(other! + 1))" : "")) {
                replay.setSource(k, i.id)
            }
        }
    }

    private func sourceBox(_ k: Int) -> some View {
        let id = replay.settings.slots[k]
        let input = id.flatMap { engine.input(withID: $0) }
        let decks = (0..<2).filter { replay.channelsUI[$0].camera == k }
        let recordingSlot = replay.recording && replay.recordingSlots.indices.contains(k) && replay.recordingSlots[k] != nil
        let border: Color = decks.contains(0) ? ReplayColors.deck[0] : (decks.contains(1) ? ReplayColors.deck[1] : Color(white: 0.2))
        return VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 5) {
                badge("CAM \(k + 1)", ReplayColors.cam(k), dark: k == 1)
                ForEach(decks, id: \.self) { d in
                    Text(d == 0 ? "◀ DECK A" : "◀ DECK B").font(.system(size: 9, weight: .heavy)).foregroundColor(ReplayColors.deck[d])
                }
                Spacer()
                if input == nil {
                    Text(L("○ 비어 있음")).font(.system(size: 9, weight: .semibold)).foregroundColor(.secondary)
                } else if recordingSlot {
                    Text("● REC").font(.system(size: 9, weight: .heavy)).foregroundColor(.red)
                }
            }
            .lineLimit(1).minimumScaleFactor(0.8)
            if let i = input {
                ZStack(alignment: .bottomLeading) {
                    Color.black
                    MonitorView(fps: 15) { i.currentFrame() }
                    TimelineView(.periodic(from: .now, by: 0.2)) { ctx in
                        Text("\(replay.recordTimecode()) · \(replay.systemTimecode(ctx.date).prefix(8))")
                            .font(.system(size: 9, weight: .semibold, design: .monospaced)).foregroundColor(.white)
                            .lineLimit(1).minimumScaleFactor(0.6)
                            .padding(.horizontal, 4).padding(.vertical, 1)
                            .background(Color.black.opacity(0.65)).padding(4)
                    }
                }
                .aspectRatio(16 / 9, contentMode: .fit)
                .clipped()
                .contentShape(Rectangle())
                .onTapGesture { replay.setCamera(k) }
                Menu { sourceMenu(k) } label: {
                    Text(sourceName(k)).lineLimit(1).truncationMode(.middle)
                }
                .menuStyle(.borderlessButton)
                .padding(.horizontal, 6).frame(height: 22)
                .background(RoundedRectangle(cornerRadius: 4).fill(Theme.button))
            } else {
                // Empty slot: one full-width "choose source" button (no tiny black box with wrapped text).
                Menu { sourceMenu(k) } label: {
                    Label(L("소스 선택"), systemImage: "plus.circle").lineLimit(1)
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .frame(maxWidth: .infinity, minHeight: 44, maxHeight: .infinity)
                .background(RoundedRectangle(cornerRadius: 4).strokeBorder(style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
                    .foregroundColor(Color(white: 0.35)))
                .contentShape(Rectangle())
            }
            HStack {
                if let i = input, let sz = i.video.size {
                    Text("\(sz.0)×\(sz.1)")
                } else {
                    Text(" ")
                }
                Spacer()
                Text(input == nil ? L("녹화 안 함 (용량 절약)") : replay.settings.codecLabel)
            }
            .font(.system(size: 9).monospacedDigit()).foregroundColor(.secondary)
            .lineLimit(1).minimumScaleFactor(0.75)
        }
        .padding(6)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color(white: 0.12)))
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(border, lineWidth: 2))
        .opacity(input == nil ? 0.75 : 1)
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
                .toggleStyle(.button).fixedSize()
            Spacer()
            Button(L("LIVE (선택 채널)")) { replay.goLive() }.lineLimit(1)
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
                if let i = replay.pendingIn {
                    (Text("IN  \(replay.timecode(i)) · ") + Text(replay.recordedClockTimecode(i)).foregroundColor(ReplayColors.clock))
                } else {
                    Text("IN  --:--:--:--")
                }
                Text("DUR \(replay.pendingDuration() ?? "--:--:--:--")")
            }
            .font(.system(size: 10, weight: .semibold, design: .monospaced))
            .lineLimit(1).minimumScaleFactor(0.8)
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
                .lineLimit(1).minimumScaleFactor(0.8)
                .padding(.horizontal, 10).frame(height: 28)
                .background(RoundedRectangle(cornerRadius: 4).fill(color.opacity(0.85)))
        }
        .buttonStyle(.plain)
    }

    // MARK: Clips

    private func aiStatus(_ e: ReplayEvent) -> (String, Color)? {
        guard let a = replay.aiClips[e.id] else { return nil }
        if a.failed { return ("AI ✕", .red) }
        if a.ready { return ("AI ✓", Color(red: 0.7, green: 0.5, blue: 1)) }
        return (String(format: "AI %.0f%%", a.progress * 100), .secondary)
    }

    private var eventList: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(L("CLIP BIN")).font(.system(size: 12, weight: .bold))
                Text("\(replay.events.count)").font(.caption).foregroundColor(.secondary)
                if !exportSelection.isEmpty {
                    Button {
                        exportEvents = replay.events.filter { exportSelection.contains($0.id) }
                    } label: {
                        Label(Lf("선택한 클립 %@개 내보내기", "\(exportSelection.count)"), systemImage: "square.and.arrow.down")
                    }
                    .controlSize(.small)
                }
                if !replay.exportMessage.isEmpty {
                    Text(replay.exportMessage).font(.caption).foregroundColor(.secondary).lineLimit(1).truncationMode(.middle)
                }
                Spacer()
                Text(L("더블클릭 = Deck A 로드 · I / O = IN / OUT · Space = 재생 · 1–4 = 앵글")).font(.caption).foregroundColor(.secondary)
                    .lineLimit(1).truncationMode(.tail).minimumScaleFactor(0.8)
            }
            HStack(spacing: 10) {
                Text("CLIP").frame(width: 40, alignment: .leading)
                Text("IN TC").frame(width: 92, alignment: .leading)
                Text(L("IN 시각")).frame(width: 92, alignment: .leading).foregroundColor(ReplayColors.clock)
                Text("OUT TC").frame(width: 92, alignment: .leading)
                Text(L("OUT 시각")).frame(width: 92, alignment: .leading).foregroundColor(ReplayColors.clock)
                Text("DURATION").frame(width: 62, alignment: .leading)
                Text("ANGLE").frame(width: 112, alignment: .leading)
                Text("NAME")
            }
            .font(.system(size: 9, weight: .bold)).foregroundColor(.secondary).padding(.horizontal, 8)
            .lineLimit(1).minimumScaleFactor(0.8)
            List(selection: $exportSelection) {
                ForEach(replay.events.reversed()) { e in
                    HStack(spacing: 10) {
                        Text(String(format: "%04d", e.number)).font(.system(size: 12, weight: .bold).monospacedDigit()).frame(width: 40, alignment: .leading)
                        Text(replay.timecode(e.inFrame)).font(.system(size: 11).monospacedDigit()).frame(width: 92, alignment: .leading)
                        Text(replay.recordedClockTimecode(e.inFrame)).font(.system(size: 11).monospacedDigit())
                            .foregroundColor(ReplayColors.clock).frame(width: 92, alignment: .leading)
                        Text(replay.timecode(e.outFrame)).font(.system(size: 11).monospacedDigit()).frame(width: 92, alignment: .leading)
                        Text(replay.recordedClockTimecode(e.outFrame)).font(.system(size: 11).monospacedDigit())
                            .foregroundColor(ReplayColors.clock).frame(width: 92, alignment: .leading)
                        Text(replay.duration(e)).font(.system(size: 11).monospacedDigit()).frame(width: 62, alignment: .leading)
                        HStack(spacing: 3) {
                            ForEach(0..<ReplaySettings.maxCameras, id: \.self) { k in
                                Button { replay.setEventCamera(e.id, k) } label: {
                                    Text("\(k + 1)").font(.system(size: 10, weight: .heavy))
                                        .foregroundColor(e.camera == k ? (k == 1 ? .black : .white) : .secondary)
                                        .frame(width: 22, height: 18)
                                        .background(RoundedRectangle(cornerRadius: 3).fill(e.camera == k ? ReplayColors.cam(k) : Theme.button))
                                }
                                .buttonStyle(.plain)
                                .help(sourceName(k))
                            }
                        }
                        .frame(width: 112, alignment: .leading)
                        Text(e.name.isEmpty ? sourceName(e.camera) : e.name)
                            .font(.system(size: 11)).foregroundColor(.secondary).lineLimit(1)
                        if let p = replay.exports[e.id] {
                            Text(Lf("내보내는 중 %@%%", "\(Int(p * 100))")).font(.system(size: 9, weight: .bold).monospacedDigit())
                                .foregroundColor(.accentColor).fixedSize()
                        }
                        if let (t, c) = aiStatus(e) {
                            Text(t).font(.system(size: 9, weight: .bold).monospacedDigit()).foregroundColor(c).fixedSize()
                                .help(L("AI 슬로모션 클립: 백그라운드 렌더 진행률 — 완료되면 슬로 재생이 AI 프레임으로 부드러워집니다"))
                        }
                        Spacer()
                        Button("A") { replay.playEvent(e, channels: [0]) }.fixedSize()
                        Button("B") { replay.playEvent(e, channels: [1]) }.fixedSize()
                        Button { exportEvents = [e] } label: { Image(systemName: "square.and.arrow.down") }
                            .buttonStyle(.borderless)
                            .help(L("이 클립 내보내기 (MP4 · 가로/세로)"))
                            .disabled(replay.exports[e.id] != nil)
                        Button(role: .destructive) { replay.deleteEvent(e.id) } label: { Image(systemName: "trash") }
                            .buttonStyle(.borderless)
                    }
                    .contentShape(Rectangle())
                    .onTapGesture(count: 2) { replay.playEvent(e, channels: [0]) }
                }
            }
            .frame(minHeight: 120, idealHeight: 180, maxHeight: 240)
        }
    }
}

/// Input tile chip: which replay CAM (R1–R4) this input records as; click to assign.
struct ReplaySlotChip: View {
    @ObservedObject var replay = ReplayEngine.shared
    @EnvironmentObject var engine: SwitcherEngine
    let input: InputSource

    var body: some View {
        let slot = replay.slot(of: input.id)
        Menu {
            Text(L("리플레이 소스"))
            Button(L("없음 (녹화 안 함)")) { if let s = slot { replay.setSource(s, nil) } }
            ForEach(0..<ReplaySettings.maxCameras, id: \.self) { k in
                let cur = replay.settings.slots[k].flatMap { engine.input(withID: $0) }
                Button((slot == k ? "✓ " : "") + "CAM \(k + 1)" + (cur != nil && slot != k ? " — \(cur!.name)" : (cur == nil ? L(" — (비어 있음)") : ""))) {
                    replay.setSource(k, input.id)
                }
            }
            Divider()
            Text(L("이미 쓰는 CAM 을 고르면 그 자리를 바꿈"))
        } label: {
            Text(slot.map { "R\($0 + 1)" } ?? "R")
                .font(.system(size: 9, weight: .heavy))
                .foregroundColor(slot == 1 ? .black : (slot == nil ? .secondary : .white))
                .padding(.horizontal, 4).frame(height: 15)
                .background(RoundedRectangle(cornerRadius: 3).fill(slot.map { ReplayColors.cam($0) } ?? Theme.button.opacity(0.6)))
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help(slot.map { Lf("리플레이 CAM %@ 로 녹화 중 — 클릭해서 변경", "\($0 + 1)") } ?? L("리플레이 소스로 지정 (CAM 1–4)"))
    }
}

/// Replay settings: sources, recording format, slow motion, folder, disk limit.
struct ReplaySettingsSheet: View {
    @EnvironmentObject var engine: SwitcherEngine
    @ObservedObject var replay = ReplayEngine.shared
    @Environment(\.dismiss) private var dismiss

    private var formatTag: Binding<String> {
        Binding(get: {
                    let st = replay.settings
                    return st.isProRes ? st.codec : (st.isHEVC ? "hevc:\(st.hevcQuality)" : "h264:\(st.quality)")
                },
                set: { v in
                    if v.hasPrefix("h264:"), let q = Int(v.dropFirst(5)) {
                        replay.settings.codec = "h264"; replay.settings.quality = q
                    } else if v.hasPrefix("hevc:"), let q = Int(v.dropFirst(5)) {
                        replay.settings.codec = "hevc"; replay.settings.hevcQuality = q
                    } else {
                        replay.settings.codec = v
                    }
                })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(L("리플레이 설정")).font(.headline)
            Form {
                Section(L("리플레이 소스 (CAM 1–4) — 빈 칸은 녹화하지 않음")) {
                    ForEach(0..<ReplaySettings.maxCameras, id: \.self) { k in
                        Picker("CAM \(k + 1)", selection: Binding(
                            get: { replay.settings.slots[k].flatMap { engine.input(withID: $0) }?.id.uuidString ?? "" },
                            set: { replay.setSource(k, UUID(uuidString: $0)) })) {
                            Text(L("없음")).tag("")
                            ForEach(engine.inputs.filter { !($0 is ReplayInput) }) { i in
                                Text("\(engine.number(of: i)). \(i.name)").tag(i.id.uuidString)
                            }
                        }
                    }
                    Text(L("녹화 중에도 바꿀 수 있습니다 — 바꾼 CAM 만 새 소스로 이어서 녹화 (TC 유지)."))
                        .font(.caption).foregroundColor(.secondary)
                }
                Section(L("녹화 형식")) {
                    Picker(L("형식 (카메라당)"), selection: formatTag) {
                        Text(L("HEVC Intra · 표준 ≈42 Mbps (권장)")).tag("hevc:65")
                        Text(L("HEVC Intra · 고화질 ≈59 Mbps")).tag("hevc:72")
                        Text(L("HEVC Intra · 최고 ≈85 Mbps")).tag("hevc:80")
                        Text(L("H.264 Intra · 100 Mbps (호환)")).tag("h264:100000")
                        Text(L("H.264 Intra · 60 Mbps (호환)")).tag("h264:60000")
                        Text(L("ProRes 422 Proxy (하드웨어)")).tag("prores_proxy")
                        Text(L("ProRes 422 LT (하드웨어)")).tag("prores_lt")
                    }
                    if replay.settings.isProRes {
                        if ReplayCaps.proResHardware {
                            Text(Lf("✓ 이 맥(%@)은 ProRes 하드웨어 엔진으로 녹화합니다. 탐색·역재생이 가볍고 화질이 좋지만 용량이 큽니다.", ReplayCaps.chip))
                                .font(.caption).foregroundColor(.secondary)
                        } else {
                            Text(Lf("⚠︎ 이 맥(%@)에는 ProRes 하드웨어 엔진이 없어 CPU로 인코딩합니다 — 4캠에는 H.264 를 권장합니다.", ReplayCaps.chip))
                                .font(.caption).foregroundColor(.orange)
                        }
                    }
                    let est = replay.estimate(cameras: max(1, replay.settings.assignedCount))
                    Text(Lf("카메라 %@대 · 시간당 %@ · 남은 공간 %@ → 약 %@시간 녹화 가능",
                            "\(max(1, replay.settings.assignedCount))", OutputConfig.bytesText(est.perHour),
                            OutputConfig.bytesText(est.free), String(format: "%.1f", est.hours)))
                        .font(.caption).monospacedDigit().foregroundColor(.secondary)
                    Text(L("형식을 바꾸면 다음 녹화 시작 때 새 세션으로 시작합니다."))
                        .font(.caption).foregroundColor(.secondary)
                }
                Section(L("슬로모션")) {
                    Toggle(L("AI 프레임 보간 (클립 저장 시 자동, 빠른 맥은 실시간)"), isOn: $replay.settings.aiSlow)
                    Toggle(L("GPU 블렌딩 (AI 준비 전·AI 미지원 맥에서 즉시 부드럽게)"), isOn: $replay.settings.smoothSlow)
                    if !replay.aiInfo.isEmpty {
                        Text(replay.aiInfo).font(.caption).foregroundColor(.secondary)
                    }
                }
                Section(L("저장 위치")) {
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
                }
                Section(L("재생 오디오")) {
                    Picker(L("재생 오디오"), selection: $replay.settings.audioFollowsCamera) {
                        Text(L("화면에 나오는 CAM 의 소스 오디오")).tag(true)
                        Text(L("프로그램(마스터) 오디오")).tag(false)
                    }
                    Text(L("CAM 마다 그 입력의 오디오(페이더 전)를 따로 녹화합니다. 오디오가 없는 소스는 무음, 그 CAM 오디오가 없는 구간은 프로그램 오디오로 재생합니다."))
                        .font(.caption).foregroundColor(.secondary).fixedSize(horizontal: false, vertical: true)
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
                    Text(L("영상은 프레임마다 독립 압축(인트라)으로 저장되어 슬로모션·역재생·프레임 이동이 정확합니다."))
                        .font(.caption).foregroundColor(.secondary)
                }
            }
            .formStyle(.grouped)
            HStack { Spacer(); Button(L("닫기")) { dismiss() }.keyboardShortcut(.defaultAction) }
        }
        .padding(16)
        .frame(width: 600, height: 720)
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
