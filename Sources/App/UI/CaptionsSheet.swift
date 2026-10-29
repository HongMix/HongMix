import SwiftUI

/// Live captions control (bottom bar "CC").
struct CaptionsButton: View {
    @EnvironmentObject var engine: SwitcherEngine
    @ViewState private var show = false

    var body: some View {
        CaptionsButtonLabel(captions: engine.captions) { show = true }
            .sheet(isPresented: $show) { CaptionsSheet(captions: engine.captions).environmentObject(engine) }
    }
}

private struct CaptionsButtonLabel: View {
    @ObservedObject var captions: CaptionEngine
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text("CC")
                .font(.system(size: 12, weight: .heavy))
                .foregroundColor(.white)
                .frame(width: 36, height: 30)
                .background(captions.running ? Theme.live : Theme.button)
                .clipShape(RoundedRectangle(cornerRadius: 3))
        }
        .buttonStyle(.plain)
        .help(L("실시간 자막 — 방송 오디오를 맥 안에서 글자로 바꿔 자막 입력에 띄우고, 번역·SRT 파일 저장"))
    }
}

struct CaptionsSheet: View {
    @EnvironmentObject var engine: SwitcherEngine
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var captions: CaptionEngine

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(L("실시간 자막 (음성 인식)")).font(.headline)
                Spacer()
                Button(captions.running ? L("자막 중지") : L("자막 시작")) {
                    captions.running ? captions.stop() : captions.start()
                }
                .buttonStyle(.borderedProminent)
                .tint(captions.running ? .red : .accentColor)
            }
            Form {
                Picker(L("말하는 언어"), selection: $captions.settings.language) {
                    ForEach(CaptionEngine.languages, id: \.0) { Text($0.1).tag($0.0) }
                }
                .disabled(captions.running)
                Picker(L("번역"), selection: $captions.settings.translateTo) {
                    ForEach(CaptionEngine.targets, id: \.0) { Text(L($0.1)).tag($0.0) }
                }
                Picker(L("듣는 오디오"), selection: $captions.settings.bus) {
                    Text("Master").tag(0)
                    ForEach(1..<AudioMixer.busCount, id: \.self) { b in Text("Bus " + AudioBus.all[b]).tag(b) }
                }
                Toggle(L("SRT 자막 파일 저장 (~/Movies/HongMix)"), isOn: $captions.settings.saveSRT)
                    .disabled(captions.running)
                LabeledContent(L("말이 끊기면 지우기")) {
                    Stepper(String(format: L("%.0f초"), captions.settings.clearAfter), value: $captions.settings.clearAfter, in: 1...15)
                }
            }
            .formStyle(.grouped)

            GroupBox(L("지금 인식된 내용")) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(captions.lastText.isEmpty ? "—" : captions.lastText).font(.system(size: 14, weight: .semibold))
                    if !captions.lastTranslation.isEmpty {
                        Text(captions.lastTranslation).foregroundColor(.yellow)
                    }
                    Text(captions.status).font(.caption).foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(4)
            }

            HStack {
                Button(L("자막 입력 추가")) {
                    var c = InputConfig(kind: .title, name: L("실시간 자막"))
                    c.title = TitleDocument(template: .liveCaptions)
                    engine.addInput(c)
                }
                .help(L("자막을 보여줄 타이틀 입력을 만듭니다 — 오버레이로 올리면 방송에 나갑니다"))
                Spacer()
                Button(L("닫기")) { dismiss() }.keyboardShortcut(.defaultAction)
            }
            Text(L("오디오는 맥 안에서 인식합니다(지원 언어). 번역은 macOS 번역 기능을 쓰며, 처음엔 시스템 설정 › 일반 › 언어 및 지역 › 번역 언어에서 언어를 내려받아야 합니다. '듣는 오디오'를 해설 마이크만 보낸 버스로 정하면 가장 정확합니다."))
                .font(.caption).foregroundColor(.secondary)
        }
        .padding()
        .frame(width: 560)
    }
}
