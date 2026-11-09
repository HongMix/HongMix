import SwiftUI

/// Settings › MIDI: devices, mappings (control → function), Learn, built-in templates, LED tally.
struct MIDISettingsView: View {
    @EnvironmentObject var engine: SwitcherEngine
    @ObservedObject var midi: MIDIControl
    @ViewState private var deviceID = ""
    @ViewState private var function = "PreviewInput"
    @ViewState private var input = "1"
    @ViewState private var value = ""

    /// Functions offered in the Learn row (anything else can be typed).
    private static let common = ["PreviewInput", "CutDirect", "Cut", "Fade", "QuickPlay", "FadeToBlack",
                                 "OverlayInput1", "OverlayInput2", "Transition1", "Transition2", "StartStopRecording",
                                 "StartStopStreaming", "Audio", "SetFader", "SetVolume", "SetMasterVolume",
                                 "ReplayPlay", "NextItem", "NextPicture", "PreviousPicture", "PTZPresetRecall"]

    private var device: MIDIControl.Device? { midi.devices.first { $0.id == deviceID } ?? midi.devices.first }
    private var shown: [MIDIMapping] {
        guard let d = device else { return midi.mappings }
        return midi.mappings.filter { $0.deviceName.isEmpty || $0.deviceName.caseInsensitiveCompare(d.name) == .orderedSame }
    }

    var body: some View {
        Form {
            Section {
                Toggle(L("MIDI 사용"), isOn: $midi.enabled)
                Picker(L("장치"), selection: Binding(get: { device?.id ?? "" }, set: { deviceID = $0 })) {
                    if midi.devices.isEmpty { Text(L("연결된 MIDI 장치 없음")).tag("") }
                    ForEach(midi.devices) { d in
                        Text(d.online ? d.name : Lf("%@ (연결 안 됨)", d.name)).tag(d.id)
                    }
                }
                if let d = device {
                    HStack {
                        Menu(L("템플릿 적용")) {
                            ForEach(MIDIControl.templates) { t in
                                Button(t.id == d.suggestedTemplateID ? Lf("%@ (추천)", t.name) : t.name) {
                                    midi.applyTemplate(id: t.id, to: d)
                                }
                            }
                        }
                        .fixedSize()
                        Button(L("장치 다시 찾기")) { midi.rescanDevices() }
                        Spacer()
                        Toggle(L("LED 탤리"), isOn: $midi.ledFeedback)
                            .disabled(!d.hasOutput)
                            .help(d.hasOutput ? L("Program = 빨강, Preview = 초록") : L("이 장치는 LED를 받을 수 없습니다"))
                    }
                }
                if !midi.lastMessage.isEmpty {
                    LabeledContent(L("마지막 입력"), value: midi.lastMessage).font(.caption)
                }
            }

            Section(L("연결")) {
                if shown.isEmpty {
                    Text(L("아직 연결이 없습니다. 아래에서 기능을 고르고 학습을 누른 뒤 컨트롤러를 움직이세요.")).font(.caption).foregroundColor(.secondary)
                }
                ForEach(shown) { m in
                    HStack {
                        Text(m.label.isEmpty ? m.actionDescription : m.label).lineLimit(1)
                        Spacer()
                        Text(m.controlDescription).font(.caption.monospaced()).foregroundColor(.secondary)
                        Button { midi.removeMapping(id: m.id) } label: { Image(systemName: "minus.circle") }
                            .buttonStyle(.borderless)
                            .help(L("삭제"))
                    }
                }
            }

            Section(L("학습")) {
                Picker(L("기능"), selection: $function) {
                    ForEach(Self.common, id: \.self) { Text($0).tag($0) }
                }
                LabeledContent(L("입력")) {
                    TextField("", text: $input, prompt: Text(L("번호 또는 이름")))
                        .textFieldStyle(.roundedBorder).multilineTextAlignment(.trailing).frame(width: 180)
                }
                LabeledContent(L("값")) {
                    TextField("", text: $value, prompt: Text(L("비워 두면 컨트롤 값")))
                        .textFieldStyle(.roundedBorder).multilineTextAlignment(.trailing).frame(width: 180)
                }
                HStack {
                    if midi.learning {
                        Label(L("기다리는 중… 컨트롤을 움직이세요"), systemImage: "dot.radiowaves.left.and.right")
                            .foregroundColor(.orange)
                        Spacer()
                        Button(L("취소")) { midi.cancelLearn() }
                    } else {
                        Button(L("학습")) {
                            midi.startLearn(MIDIActionDraft(function: function, input: input.trimmingCharacters(in: .whitespaces),
                                                            value: value.trimmingCharacters(in: .whitespaces)))
                        }
                        .keyboardShortcut(.defaultAction)
                        Spacer()
                    }
                }
                Text(L("페이더·노브에 SetFader(T-바)나 볼륨 기능을 고르면 값이 컨트롤을 따라갑니다(값은 비워 두세요). 같은 컨트롤을 다시 학습하면 덮어씁니다."))
                    .font(.caption).foregroundColor(.secondary)
                if !midi.status.isEmpty { Text(midi.status).font(.caption) }
                if device?.name.lowercased().contains("nanokontrol") == true {
                    Text(L("nanoKONTROL2 LED를 쓰려면 KORG KONTROL Editor에서 LED Mode를 External로 바꾸세요."))
                        .font(.caption).foregroundColor(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .textFieldStyle(.roundedBorder)
    }
}
