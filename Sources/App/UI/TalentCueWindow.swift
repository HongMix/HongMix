import SwiftUI
import AppKit

/// Window "Talent Cue": preview of the Talent Display, prepared messages, timer, look, and the moderator link.
struct TalentCueWindow: View {
    @EnvironmentObject var engine: SwitcherEngine
    @ObservedObject var cue = TalentCue.shared
    @ViewState private var newText = ""
    @ViewState private var newColor = Color.white
    @ViewState private var remoteOn = APIAccess.enabled

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            VStack(alignment: .leading, spacing: 10) {
                Text(L("Talent Display 미리보기")).font(.system(size: 11, weight: .bold)).foregroundColor(.secondary)
                TalentDisplayView(cue: cue)
                    .aspectRatio(16.0 / 9.0, contentMode: .fit)
                    .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.white.opacity(0.25)))
                HStack {
                    Button(cue.blackout ? L("블랙아웃 해제") : L("블랙아웃")) { cue.blackout.toggle() }
                        .tint(cue.blackout ? .red : nil)
                        .buttonStyle(.borderedProminent)
                    Button(L("메시지 숨기기")) { cue.hideMessage() }.disabled(cue.liveMessageID == nil)
                    Toggle(L("눈에 띄게 (깜빡임)"), isOn: $cue.flash).disabled(cue.liveMessageID == nil)
                    Spacer()
                }
                timerControls
                Text(L("디스플레이 출력 ⚙ 또는 모니터별 출력에서 'Talent Display'를 고르면 이 화면이 그 모니터에 나갑니다."))
                    .font(.caption).foregroundColor(.secondary).fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
            .padding(14)
            .frame(width: 460)
            Divider()
            Form {
                messagesSection
                timerSection
                lookSection
                remoteSection
            }
            .formStyle(.grouped)
        }
        .frame(minWidth: 980, minHeight: 640)
    }

    // MARK: Timer (left column: the buttons you need during a show)

    private var timerControls: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Button(cue.timer.running ? L("일시정지") : L("시작")) {
                    cue.timer.running ? cue.pauseTimer() : cue.startTimer()
                }
                .buttonStyle(.borderedProminent)
                Button(L("리셋")) { cue.resetTimer() }
                Button(L("−1분")) { cue.timer.add(seconds: -60) }
                Button(L("+1분")) { cue.timer.add(seconds: 60) }
                Toggle(L("타이머 표시"), isOn: $cue.timerOnDisplay)
            }
            HStack(spacing: 4) {
                Text(L("빠른 설정")).font(.caption).foregroundColor(.secondary)
                ForEach([5, 10, 15, 20, 30, 45, 60], id: \.self) { m in
                    Button("\(m)′") { cue.setTimer(seconds: Double(m * 60)) }.controlSize(.small)
                }
            }
        }
    }

    // MARK: Messages

    private var messagesSection: some View {
        Section(L("메시지 (미리 준비 → 표시 / 숨기기)")) {
            HStack {
                TextField("", text: $newText, prompt: Text(L("새 메시지")))
                    .labelsHidden()
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: .infinity)
                    .onSubmit { add(show: false) }
                ColorPicker("", selection: $newColor, supportsOpacity: false).labelsHidden()
                Button(L("추가")) { add(show: false) }.disabled(newText.isEmpty)
                Button(L("추가하고 표시")) { add(show: true) }.disabled(newText.isEmpty)
            }
            ForEach($cue.messages) { $m in
                let live = cue.liveMessageID == m.id
                HStack {
                    ColorPicker("", selection: Binding(get: { Color(talentHex: m.color) }, set: { m.color = $0.talentHex }),
                                supportsOpacity: false).labelsHidden()
                    TextField("", text: $m.text)
                        .labelsHidden()
                        .multilineTextAlignment(.leading)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Button(live ? L("숨기기") : L("표시")) { live ? cue.hideMessage() : cue.show(m.id) }
                        .buttonStyle(.borderedProminent)
                        .tint(live ? .red : .accentColor)
                    Button { cue.deleteMessage(m.id) } label: { Image(systemName: "trash") }
                        .buttonStyle(.borderless)
                        .help(L("삭제"))
                }
            }
        }
    }

    private func add(show: Bool) {
        guard let m = cue.addMessage(newText, color: newColor.talentHex) else { return }
        newText = ""
        if show { cue.show(m.id) }
    }

    // MARK: Timer settings

    private var timerSection: some View {
        Section(L("타이머")) {
            NumberField(L("길이"), value: Binding(get: { Int(cue.timer.duration) / 60 },
                                                set: { cue.timer.duration = Double($0 * 60 + Int(cue.timer.duration) % 60) }),
                        in: 0...1440, unit: L("분"), step: 1)
            NumberField("", value: Binding(get: { Int(cue.timer.duration) % 60 },
                                           set: { cue.timer.duration = Double(Int(cue.timer.duration) / 60 * 60 + $0) }),
                        in: 0...59, unit: L("초"), step: 1)
            Picker(L("방향"), selection: $cue.timer.countUp) {
                Text(L("카운트다운")).tag(false)
                Text(L("카운트업 (경과 시간)")).tag(true)
            }
            .pickerStyle(.segmented)
            if !cue.timer.countUp {
                colorRow(L("처음"), \.colorNormal, threshold: nil)
                colorRow(L("남은 시간이 이하일 때"), \.colorWarning, threshold: $cue.timer.warnAt)
                colorRow(L("남은 시간이 이하일 때"), \.colorCritical, threshold: $cue.timer.criticalAt)
                Toggle(L("시간 초과 시 깜빡임 (마이너스로 계속 셈)"), isOn: $cue.settings.flashOvertime)
            }
            DecimalField(L("타이머 크기"), value: $cue.settings.timerScale, in: 0.4...1.6, unit: "×", step: 0.1, digits: 1)
            Toggle(L("타이머 아래 시계 표시"), isOn: $cue.settings.clockUnderTimer)
        }
    }

    /// Colour for a phase, from `threshold` minutes remaining (nil = the start colour).
    private func colorRow(_ title: String, _ kp: WritableKeyPath<TalentCue.Settings, String>, threshold: Binding<Double>?) -> some View {
        HStack {
            ColorPicker("", selection: Binding(get: { Color(talentHex: cue.settings[keyPath: kp]) },
                                               set: { cue.settings[keyPath: kp] = $0.talentHex }),
                        supportsOpacity: false).labelsHidden()
            if let threshold {
                DecimalField(title, value: Binding(get: { threshold.wrappedValue / 60 }, set: { threshold.wrappedValue = $0 * 60 }),
                             in: 0...1440, unit: L("분"), step: 0.5, digits: 1)
            } else {
                Text(title)
                Spacer()
            }
        }
    }

    // MARK: Look

    private var lookSection: some View {
        Section(L("화면")) {
            TextField(L("제목 (위쪽)"), text: $cue.settings.title)
            Picker(L("메시지·타이머가 없을 때"), selection: $cue.settings.idle) {
                ForEach(TalentCue.Idle.allCases) { Text($0.label).tag($0) }
            }
            if cue.settings.idle == .logo { fileRow(L("로고"), \.logoPath) }
            HStack {
                Text(L("배경색"))
                Spacer()
                ColorPicker("", selection: Binding(get: { Color(talentHex: cue.settings.background) },
                                                   set: { cue.settings.background = $0.talentHex }),
                            supportsOpacity: false).labelsHidden()
            }
            fileRow(L("배경 이미지"), \.backgroundImage)
            DecimalField(L("메시지 크기"), value: $cue.settings.messageScale, in: 0.4...1.6, unit: "×", step: 0.1, digits: 1)
            Toggle(L("24시간 시계"), isOn: $cue.settings.clock24h)
        }
    }

    private func fileRow(_ title: String, _ kp: WritableKeyPath<TalentCue.Settings, String>) -> some View {
        let path = cue.settings[keyPath: kp]
        return LabeledContent(title) {
            HStack {
                Text(path.isEmpty ? L("없음") : (path as NSString).lastPathComponent)
                    .foregroundColor(.secondary).lineLimit(1).truncationMode(.middle)
                Button(L("선택…")) {
                    let p = NSOpenPanel()
                    p.allowedContentTypes = [.image]
                    if p.runModal() == .OK, let u = p.url { TalentImages.reset(); cue.settings[keyPath: kp] = u.path }
                }
                if !path.isEmpty { Button(L("지우기")) { TalentImages.reset(); cue.settings[keyPath: kp] = "" } }
            }
        }
    }

    // MARK: Moderator link

    private var link: String {
        let host = APIAccess.mode == "local" ? "localhost" : (HTTPAPIServer.localIPAddress() ?? "localhost")
        let port = BackstageLink.running ? Int(Backstage.port) : 8088   // Backstage's link survives a HongMix crash
        return "http://\(host):\(port)/talent?key=\(cue.token)"
    }

    private var remoteSection: some View {
        Section(L("사회자 원격 (브라우저 링크)")) {
            if !remoteOn {
                Text(L("원격 제어가 꺼져 있어 링크가 열리지 않습니다."))
                    .foregroundColor(.orange)
                Button(L("원격 제어 켜기")) {
                    UserDefaults.standard.set(true, forKey: APIAccess.enabledKey)
                    if APIAccess.mode == "off" { UserDefaults.standard.set("lan", forKey: APIAccess.modeKey) }
                    engine.applyRemoteControl()
                    remoteOn = APIAccess.enabled
                }
            } else {
                HStack {
                    Text(link).textSelection(.enabled).font(.system(.body, design: .monospaced)).lineLimit(1)
                    Spacer()
                    Button(L("복사")) {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(link, forType: .string)
                    }
                    Button(L("새 링크")) { cue.regenerateToken() }
                        .help(L("새 링크를 만들면 예전 링크는 더 이상 작동하지 않습니다"))
                }
                if APIAccess.mode == "local" {
                    Text(L("설정 › 네트워크가 '이 맥에서만'이라 다른 기기에서는 열리지 않습니다."))
                        .font(.caption).foregroundColor(.orange)
                }
            }
            Text(L("같은 네트워크의 휴대폰·노트북에서 이 링크로 메시지 표시/숨기기와 타이머를 조작합니다. 링크를 아는 사람은 누구나 조작할 수 있으니 공유에 주의하세요. 인터넷 너머에서 쓰려면 Tailscale 같은 VPN이나 포트 포워딩이 필요합니다."))
                .font(.caption).foregroundColor(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }
}
