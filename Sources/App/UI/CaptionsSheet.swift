import SwiftUI
import AppKit
import UniformTypeIdentifiers

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
                DecimalField(L("말이 끊기면 지우기"), value: $captions.settings.clearAfter, in: 1...15, unit: L("초"), step: 1)
                Picker(L("인식 엔진"), selection: $captions.settings.engine) {
                    Text(L("새 엔진 (장시간 · 끊김 없음, macOS 26+)")).tag("auto")
                    Text(L("기존 엔진")).tag("classic")
                }
                .disabled(captions.running)
                if captions.running && !captions.engineLabel.isEmpty {
                    LabeledContent(L("사용 중")) { Text(captions.engineLabel).foregroundColor(.secondary) }
                }
                DecimalField(L("한 줄 최소 표시 시간"), value: $captions.settings.minLineSeconds, in: 0...6,
                             unit: L("초 · 0 = 바로"), step: 0.5, digits: 1)
                Toggle(L("용어집 · 교정 사용 (국정감사·예산 용어 기본 내장)"), isOn: $captions.settings.useGlossary)
                if captions.settings.useGlossary {
                    GlossaryFileRow(title: L("용어집 (.txt, 한 줄에 하나)"), path: $captions.settings.termsPath, types: ["txt"])
                    GlossaryFileRow(title: L("교정 목록 (.csv: 원문,교정문)"), path: $captions.settings.correctionsPath, types: ["csv", "txt"])
                }
                CaptionStyleSection(captions: captions)
            }
            .formStyle(.grouped)
            .frame(minHeight: 470, maxHeight: 620)

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
                Button(L("테스트 문장 보내기")) { captions.sendTest() }
                    .help(L("음성 인식 없이 예시 문장을 띄워 모양을 확인합니다"))
                Button(L("자막 지우기")) { captions.clearCaptions() }
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
        .frame(width: 660)
    }
}

/// Tools › Captions › "Caption look": layout preset, lines, size, letter spacing, line spacing, colours.
struct CaptionStyleSection: View {
    @ObservedObject var captions: CaptionEngine

    /// Binding into the style; editing a geometry value switches the preset to "custom".
    private func b<T>(_ kp: WritableKeyPath<CaptionStyle, T>, custom: Bool = false) -> Binding<T> {
        Binding(get: { captions.settings.style[keyPath: kp] },
                set: { v in
                    var st = captions.settings.style
                    st[keyPath: kp] = v
                    if custom { st.preset = "custom" }
                    captions.settings.style = st
                })
    }
    private func intB(_ kp: WritableKeyPath<CaptionStyle, Double>, custom: Bool = false) -> Binding<Int> {
        Binding(get: { Int(captions.settings.style[keyPath: kp].rounded()) },
                set: { v in
                    var st = captions.settings.style
                    st[keyPath: kp] = Double(v)
                    if custom { st.preset = "custom" }
                    captions.settings.style = st
                })
    }

    var body: some View {
        let st = captions.settings.style
        Section(L("자막 모양")) {
            Picker(L("레이아웃"), selection: Binding(get: { st.preset },
                                                   set: { captions.settings.style = st.applying(preset: $0) })) {
                Text(L("오른쪽형")).tag("right")
                Text(L("하단 영화형")).tag("bottom")
                Text(L("하단 띠")).tag("band")
                Text(L("직접 지정")).tag("custom")
            }
            .pickerStyle(.segmented)
            NumberField(L("자막 줄 수"), value: b(\.lines, custom: true), in: 1...6, unit: L("줄"), step: 1)
            NumberField(L("한 줄 글자 수"), value: b(\.lineChars, custom: true), in: 6...40, unit: L("자 (한글)"), step: 1)
            NumberField(L("글자 크기"), value: intB(\.fontSize, custom: true), in: 16...96, unit: L("px (1080 기준)"), step: 1)
            DecimalField(L("자간"), value: b(\.letterSpacing), in: -4...16, unit: "px", step: 0.5, digits: 1)
            NumberField(L("줄 간격"), value: intB(\.lineHeight, custom: true), in: 90...200, unit: "%", step: 5)
            NumberField(L("줄 사이 여백"), value: intB(\.rowGap, custom: true), in: 0...40, unit: "px", step: 1)
            NumberField(L("글자 가로 비율"), value: intB(\.scaleX), in: 60...150, unit: "%", step: 5)
            LabeledContent(L("위치 · 크기 (%)")) {
                HStack(spacing: 5) {
                    Text("X").foregroundColor(.secondary).fixedSize()
                    posField(\.left)
                    Text("Y").foregroundColor(.secondary).fixedSize()
                    posField(\.top)
                    Text("W").foregroundColor(.secondary).fixedSize()
                    posField(\.width)
                    Text("H").foregroundColor(.secondary).fixedSize()
                    posField(\.height)
                }
                .help(L("X = 왼쪽, Y = 위, W = 폭, H = 높이 (화면에 대한 %)"))
            }
            Picker(L("정렬"), selection: b(\.align, custom: true)) {
                Text(L("왼쪽")).tag("left")
                Text(L("가운데")).tag("center")
            }
            .pickerStyle(.segmented)
            Picker(L("배경"), selection: b(\.background, custom: true)) {
                Text(L("줄마다")).tag("line")
                Text(L("상자 하나")).tag("box")
                Text(L("하단 띠")).tag("band")
                Text(L("없음")).tag("none")
            }
            .pickerStyle(.segmented)
            LabeledContent(L("배경 불투명도")) {
                HStack {
                    Slider(value: b(\.bgOpacity), in: 0...100).frame(width: 200)
                    Text("\(Int(st.bgOpacity))%").monospacedDigit().frame(width: 40, alignment: .trailing)
                }
            }
            LabeledContent(L("글자 색")) {
                HStack(spacing: 6) {
                    TextField("", text: b(\.textColor), prompt: Text("#FFFFFF")).labelsHidden()
                        .textFieldStyle(.roundedBorder).frame(width: 100).font(.system(size: 11).monospaced())
                    ColorSwatch(hex: st.textColor)
                    Toggle(L("검은 외곽선"), isOn: b(\.outline)).toggleStyle(.checkbox)
                }
            }
            Picker(L("폰트"), selection: b(\.fontName)) {
                ForEach(fontList(st.fontName), id: \.self) { Text($0).tag($0) }
            }
            LabeledContent(L("자막 표시 문구")) {
                HStack(spacing: 6) {
                    Toggle("", isOn: b(\.labelShow)).labelsHidden()
                    TextField("", text: b(\.labelText), prompt: Text(L("AI 자막"))).labelsHidden()
                        .textFieldStyle(.roundedBorder).frame(width: 140)
                    TextField("", value: intB(\.labelSize), format: .number).labelsHidden()
                        .textFieldStyle(.roundedBorder).multilineTextAlignment(.trailing).frame(width: 50)
                    Text("px").foregroundColor(.secondary)
                }
            }
            if st.labelShow {
                Picker(L("표시 문구 위치"), selection: b(\.labelPos)) {
                    Text(L("자막 바로 위")).tag("rows")
                    Text(L("영역 왼쪽 위")).tag("box")
                    Text(L("직접 지정")).tag("custom")
                }
                .pickerStyle(.segmented)
                if st.labelPos == "custom" {
                    LabeledContent(L("표시 문구 X · Y (%)")) {
                        HStack(spacing: 5) {
                            Text("X").foregroundColor(.secondary).fixedSize()
                            labelPosField(\.labelX)
                            Text("Y").foregroundColor(.secondary).fixedSize()
                            labelPosField(\.labelY)
                        }
                    }
                }
            }
            NumberField(L("줄 이동 시간"), value: intB(\.animationMs), in: 0...900, unit: L("ms · 0 = 바로 바뀜"), step: 20)
            Toggle(L("말하는 중인 문장 미리 표시 (하늘색)"), isOn: b(\.showDraft))
            if !captions.settings.translateTo.isEmpty {
                Toggle(L("번역만 표시 (원문 숨김)"), isOn: b(\.translationOnly))
            }
            Text(L("영상 크기는 바꾸지 않습니다. 자막 입력을 오버레이(1~8)로 올려 방송 화면 위에 겹치세요. ‘테스트 문장 보내기’로 말하지 않고도 모양을 확인할 수 있습니다."))
                .font(.caption).foregroundColor(.secondary)
        }
    }

    private func posField(_ kp: WritableKeyPath<CaptionStyle, Double>) -> some View {
        TextField("", value: Binding(get: { Int(captions.settings.style[keyPath: kp].rounded()) },
                                     set: { v in
                                         var st = captions.settings.style
                                         st[keyPath: kp] = Double(max(0, min(100, v)))
                                         st.preset = "custom"
                                         captions.settings.style = st
                                     }), format: .number)
            .labelsHidden().textFieldStyle(.roundedBorder).multilineTextAlignment(.trailing).frame(width: 46)
    }

    private func labelPosField(_ kp: WritableKeyPath<CaptionStyle, Double>) -> some View {
        TextField("", value: Binding(get: { Int(captions.settings.style[keyPath: kp].rounded()) },
                                     set: { v in captions.settings.style[keyPath: kp] = Double(max(0, min(98, v))) }),
                  format: .number)
            .labelsHidden().textFieldStyle(.roundedBorder).multilineTextAlignment(.trailing).frame(width: 46)
    }

    private func fontList(_ current: String) -> [String] {
        var l = CaptionStyle.fontChoices
        if !l.contains(current) { l.insert(current, at: 0) }
        return l
    }
}

/// File chooser row for the caption glossary / corrections ("" = built-in list).
struct GlossaryFileRow: View {
    let title: String
    @Binding var path: String
    let types: [String]

    var body: some View {
        LabeledContent(title) {
            HStack(spacing: 6) {
                Text(path.isEmpty ? L("기본 (내장)") : (path as NSString).lastPathComponent)
                    .foregroundColor(.secondary).lineLimit(1).truncationMode(.middle)
                Button(L("선택…")) {
                    let p = NSOpenPanel()
                    p.allowedContentTypes = types.compactMap { UTType(filenameExtension: $0) }
                    if p.runModal() == .OK, let u = p.url { path = u.path }
                }
                if !path.isEmpty {
                    Button(L("기본으로")) { path = "" }
                }
            }
        }
    }
}
