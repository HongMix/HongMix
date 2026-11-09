import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// Live input properties (changes apply immediately): position/crop, colour, audio, playback, recording.
struct InputPropertiesSheet: View {
    @EnvironmentObject var engine: SwitcherEngine
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var input: InputSource
    @ObservedObject private var transport: InputTransportState
    var initialTab: Int = 0
    var onChangeSource: (() -> Void)? = nil
    @ViewState private var tab = 0

    init(input: InputSource, initialTab: Int = 0, onChangeSource: (() -> Void)? = nil) {
        self.input = input
        self._transport = ObservedObject(wrappedValue: input.transport)
        self.initialTab = initialTab
        self.onChangeSource = onChangeSource
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Image(systemName: input.kind.symbol)
                Text(Lf("%@. %@ — 속성", "\(engine.number(of: input))", "\(input.name)")).font(.headline)
                    .lineLimit(1).truncationMode(.middle)
                InputFormatLabel(slot: input.video, size: 11)
                Spacer()
                MonitorView(fps: 12) { input.monitorFrame() }
                    .frame(width: 160, height: 90)
                    .background(Color.black)
            }
            .padding()

            HStack(spacing: 0) {
                ScrollView {
                    VStack(spacing: 3) {
                        ForEach(propertyTabs, id: \.id) { item in
                            Button {
                                tab = item.id
                            } label: {
                                HStack(spacing: 8) {
                                    Image(systemName: item.icon).frame(width: 17)
                                    Text(item.title).lineLimit(1)
                                    Spacer(minLength: 0)
                                }
                                .font(.system(size: 11, weight: tab == item.id ? .semibold : .regular))
                                .foregroundColor(tab == item.id ? .white : Theme.buttonText.opacity(0.82))
                                .padding(.horizontal, 9)
                                .frame(height: 30)
                                .background(tab == item.id ? Theme.accent : Color.clear)
                                .clipShape(RoundedRectangle(cornerRadius: 5))
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(8)
                }
                .frame(width: 158)
                .background(Theme.panel.opacity(0.55))

                Divider()

                Group {
                    switch tab {
                    case 1: colorTab
                    case 2: keyTab
                    case 3: positionTab
                    case 4: audioTab
                    case 5: playbackTab
                    case 6: LayersEditor(input: input)
                    case 7: TriggersEditor(input: input)
                    case 8: if let f = input as? FFmpegInput { ListEditor(input: f) }
                    case 9: PTZPanel(ptz: PTZManager.shared.controller(for: input))
                    default: generalTab
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(.horizontal, 12)
            }
            .onAppear { tab = initialTab }

            HStack {
                Button(L("모두 초기화")) {
                    input.adjust = VideoAdjust()
                }
                Spacer()
                Button(L("닫기")) { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding()
        }
        .frame(width: 900, height: 680)
    }

    private var propertyTabs: [(id: Int, title: String, icon: String)] {
        var tabs: [(Int, String, String)] = [
            (0, "General", "slider.horizontal.3"),
            (1, "Colour Adjust", "sun.max"),
            (2, L("Key / Fill & Key"), "viewfinder"),
            (3, "Position", "rectangle.dashed"),
            (6, "Layers", "square.3.layers.3d"),
            (4, "Audio Settings", "speaker.wave.2"),
        ]
        if input.supportsTransport { tabs.append((5, "Playback", "play.rectangle")) }
        if input.supportsTransport, input is FFmpegInput { tabs.append((8, "List", "list.number")) }
        tabs.append((7, "Triggers", "bolt"))
        if input.isLiveSource { tabs.append((9, "PTZ", "camera.metering.center.weighted")) }
        return tabs.map { (id: $0.0, title: $0.1, icon: $0.2) }
    }

    private var generalTab: some View {
        Form {
            Section("General") {
                TextField("Name", text: $input.name)
                LabeledContent("Type", value: input.kind.label)
                LabeledContent("Status", value: input.status)
                if let change = onChangeSource {
                    Button(L("Change… (소스 바꾸기, 설정 유지)")) { change() }
                }
            }
            Section("Video") {
                Toggle("Deinterlace (Blend)", isOn: $input.adjust.deinterlace)
                Toggle("Sharpen", isOn: $input.adjust.sharpen)
                Toggle("Mirror", isOn: $input.adjust.mirror)
            }
            Section(L("Audio / 전환")) {
                Toggle("Automatically mix audio (Audio Auto)", isOn: $input.audioFollowsVideo)
                if input.supportsTransport {
                    Toggle("Automatically Play with transition", isOn: $input.autoPlay)
                    Toggle("Automatically Pause with transition", isOn: $input.autoPause)
                    Toggle("Automatically Restart with transition", isOn: $input.autoRestart)
                }
            }
            Section("MultiCorder") {
                Toggle(L("MultiCorder로 녹화 (입력별 ISO)"), isOn: $input.multiCorder)
            }
            if input.isLiveSource {
                Section(L("신호 끊김 / 페일오버")) {
                    Picker(L("끊겼을 때 화면"), selection: $input.lossMode) {
                        Text(L("마지막 화면 유지")).tag(0)
                        Text(L("검정")).tag(1)
                        Text(L("컬러바 + NO SIGNAL")).tag(2)
                    }
                    Picker(L("백업 입력 (온에어 중 끊기면 자동 전환)"), selection: $input.backupInputID) {
                        Text(L("없음")).tag(UUID?.none)
                        ForEach(engine.inputs.filter { $0.id != input.id }) { i in
                            Text("\(engine.number(of: i)). \(i.name)").tag(UUID?.some(i.id))
                        }
                    }
                    Toggle(L("신호가 돌아오면 원래 입력으로 복귀"), isOn: $input.autoReturn)
                    Toggle(L("경고음 + 알림"), isOn: $input.lossAlert)
                    Text(L("1초 이상 프레임이 안 들어오면 끊김으로 판단하고, 2초 이상 안정되면 복구로 봅니다."))
                        .font(.caption).foregroundColor(.secondary)
                }
            }
            if let b = input as? BrowserInput {
                Section("Web Browser") {
                    HStack {
                        Button("Back") { b.goBack() }
                        Button("Forward") { b.goForward() }
                        Button("Reload") { b.reload() }
                        Button(L("브라우저 창 열기 (조작)")) { b.showInteractive(true) }
                    }
                }
            }
        }
        .formStyle(.grouped)
        .textFieldStyle(.roundedBorder)
    }

    private var keyTab: some View {
        Form {
            AlphaKeySection(input: input)
            BGRemovalSection(input: input)
            Section("Colour Key / Chroma Key") {
                Toggle(L("Colour Key 사용"), isOn: $input.adjust.keyOn)
                HStack {
                    Text(L("Key 색상"))
                    TextField("#RRGGBB", text: $input.adjust.keyColor)
                        .frame(width: 100)
                        .font(.system(size: 12).monospaced())
                    ColorSwatch(hex: input.adjust.keyColor)
                    Button("Green") { input.adjust.keyColor = "#00B140" }
                    Button("Blue") { input.adjust.keyColor = "#0047BB" }
                }
                slider("Tolerance", $input.adjust.keyTolerance, 0...0.5, reset: 0.12)
                slider("Softness", $input.adjust.keySoftness, 0...0.3, reset: 0.08)
                slider(L("Spill 제거"), $input.adjust.keySpill, 0...1, reset: 0.5)
                Text(L("초록/파랑 배경을 투명하게 합니다. 키를 건 입력을 오버레이(1~8)로 올리면 배경 위에 합성됩니다."))
                    .font(.caption).foregroundColor(.secondary)
            }
        }
        .formStyle(.grouped)
        .textFieldStyle(.roundedBorder)
    }

    private func slider(_ label: String, _ value: Binding<Float>, _ range: ClosedRange<Float>, format: String = "%.2f",
                        reset: Float) -> some View {
        HStack {
            // natural width (never wraps/truncates English labels like "Gate Threshold dB"), min 120 keeps columns aligned
            Text(label).lineLimit(1).fixedSize().frame(minWidth: 120, alignment: .leading)
            Slider(value: value, in: range)
            Text(String(format: format, value.wrappedValue))
                .font(.system(size: 11).monospacedDigit())
                .frame(width: 50, alignment: .trailing)
            Button {
                value.wrappedValue = reset
            } label: {
                Image(systemName: "arrow.counterclockwise")
            }
            .buttonStyle(.borderless)
            .help(L("초기값"))
        }
    }

    private var positionTab: some View {
        Form {
            Section(L("위치 (SetZoom / SetPanX / SetPanY)")) {
                slider(L("줌"), $input.adjust.zoom, 0.1...5, reset: 1)
                slider(L("가로 이동 (Pan X)"), $input.adjust.panX, -2...2, reset: 0)
                slider(L("세로 이동 (Pan Y)"), $input.adjust.panY, -2...2, reset: 0)
            }
            Section(L("크롭 (가장자리에서 잘라낼 비율)")) {
                slider(L("왼쪽"), $input.adjust.cropL, 0...0.9, reset: 0)
                slider(L("오른쪽"), $input.adjust.cropR, 0...0.9, reset: 0)
                slider(L("위"), $input.adjust.cropT, 0...0.9, reset: 0)
                slider(L("아래"), $input.adjust.cropB, 0...0.9, reset: 0)
            }
            Section(L("기타")) {
                slider(L("불투명도 (Alpha)"), $input.adjust.alpha, 0...1, reset: 1)
                Toggle(L("좌우 반전 (Mirror)"), isOn: $input.adjust.mirror)
                Toggle(L("디인터레이스"), isOn: $input.adjust.deinterlace)
                Toggle(L("샤픈"), isOn: $input.adjust.sharpen)
            }
        }
        .formStyle(.grouped)
        .textFieldStyle(.roundedBorder)
    }

    private var colorTab: some View {
        Form {
            Section(L("Gain (밝은 영역)")) {
                slider("R", $input.adjust.gainR, 0...2, reset: 1)
                slider("G", $input.adjust.gainG, 0...2, reset: 1)
                slider("B", $input.adjust.gainB, 0...2, reset: 1)
            }
            Section(L("Gamma (중간 영역)")) {
                slider("R", $input.adjust.gammaR, 0.2...3, reset: 1)
                slider("G", $input.adjust.gammaG, 0.2...3, reset: 1)
                slider("B", $input.adjust.gammaB, 0.2...3, reset: 1)
            }
            Section(L("Lift (어두운 영역)")) {
                slider("R", $input.adjust.liftR, -0.5...0.5, reset: 0)
                slider("G", $input.adjust.liftG, -0.5...0.5, reset: 0)
                slider("B", $input.adjust.liftB, -0.5...0.5, reset: 0)
            }
            Section(L("전체")) {
                slider(L("채도"), $input.adjust.saturation, 0...2, reset: 1)
                slider(L("색상 (Hue°)"), $input.adjust.hue, -180...180, format: "%.0f", reset: 0)
                Button(L("색보정 초기화 (ColourCorrectionReset)")) { input.adjust.resetColor() }
            }
            LUTSection(input: input)
        }
        .formStyle(.grouped)
        .textFieldStyle(.roundedBorder)
    }

    private var audioTab: some View {
        Form {
            Section(L("레벨")) {
                slider(L("볼륨"), $input.volume, 0...1, reset: 0.8)
                slider(L("게인 (dB)"), $input.gainDB, 0...24, format: "%.1f", reset: 0)
                slider(L("밸런스"), $input.balance, -1...1, reset: 0)
                slider(L("채널 1 (L)"), $input.channel1, 0...1, reset: 1)
                slider(L("채널 2 (R)"), $input.channel2, 0...1, reset: 1)
            }
            Section("Audio Settings") {
                Picker("Channel", selection: $input.audioFX.channelMode) {
                    Text("Stereo").tag(0)
                    Text("Mono (Left)").tag(1)
                    Text("Mono (Right)").tag(2)
                    Text("Swap L/R").tag(3)
                }
                NumberField("Delay", value: $input.audioFX.delayMs, in: 0...1000, unit: "ms", step: 10)
                Toggle("Visible in Mixer", isOn: $input.audioFX.visibleInMixer)
            }
            Section("EQ") {
                Toggle(L("EQ 사용"), isOn: $input.audioFX.eqOn)
                slider("Low (100Hz) dB", $input.audioFX.eqLow, -15...15, format: "%.1f", reset: 0)
                slider("Mid (1kHz) dB", $input.audioFX.eqMid, -15...15, format: "%.1f", reset: 0)
                slider("High (8kHz) dB", $input.audioFX.eqHigh, -15...15, format: "%.1f", reset: 0)
            }
            Section("Compressor / Noise Gate") {
                Toggle("Compressor", isOn: $input.audioFX.compOn)
                slider("Threshold dB", $input.audioFX.compThreshold, -60...0, format: "%.0f", reset: -18)
                slider("Ratio", $input.audioFX.compRatio, 1...20, format: "%.1f:1", reset: 4)
                Toggle("Noise Gate", isOn: $input.audioFX.gateOn)
                slider("Gate Threshold dB", $input.audioFX.gateThreshold, (-90)...(-10), format: "%.0f", reset: -50)
            }
            DuckingSection(input: input)
            Section(L("버스 라우팅")) {
                HStack(spacing: 6) {
                    ForEach(AudioBus.all, id: \.self) { b in
                        Toggle(b, isOn: Binding(get: { input.onBus(b) }, set: { input.setBus(b, $0) }))
                            .toggleStyle(.button)
                    }
                }
                Toggle(L("Audio Auto (비디오가 Output에 있을 때만 오디오 On)"), isOn: $input.audioFollowsVideo)
                Toggle(L("음소거"), isOn: $input.muted)
                Toggle(L("Solo (헤드폰)"), isOn: $input.solo)
            }
        }
        .formStyle(.grouped)
        .textFieldStyle(.roundedBorder)
    }

    private var playbackTab: some View {
        Form {
            Section(L("재생")) {
                HStack {
                    Button(input.playing ? L("일시정지") : L("재생")) { input.playing.toggle() }
                    Button(L("처음부터")) { input.restart() }
                    Toggle(L("반복"), isOn: $input.looping)
                }
                HStack {
                    Text(String(format: L("%.2f / %.2f 초"), transport.position, transport.duration))
                        .font(.system(size: 12).monospacedDigit())
                    Slider(value: Binding(get: { transport.position },
                                          set: { input.seek(seconds: $0); transport.position = $0 }),
                           in: 0...max(0.1, transport.duration))
                }
                HStack {
                    Text(L("재생 속도"))
                    Slider(value: $input.rate, in: 0.25...2, step: 0.05)
                    Text(String(format: "%.2fx", input.rate)).frame(width: 50)
                    Button("1x") { input.rate = 1 }
                }
                Text(L("1x가 아니면 오디오는 음소거됩니다.")).font(.caption).foregroundColor(.secondary)
            }
            Section(L("마크 인/아웃")) {
                HStack {
                    Button(L("Mark In (현재)")) { input.markIn = transport.position }
                    Text(input.markIn >= 0 ? String(format: L("%.2f초"), input.markIn) : L("없음"))
                    Spacer()
                    Button(L("Mark Out (현재)")) { input.markOut = transport.position }
                    Text(input.markOut > 0 ? String(format: L("%.2f초"), input.markOut) : L("없음"))
                    Button("Reset") {
                        input.markIn = -1
                        input.markOut = -1
                    }
                }
            }
            Section(L("자동 동작")) {
                Toggle(L("Auto Play — Output/오버레이로 갈 때 자동 재생"), isOn: $input.autoPlay)
                Toggle(L("Auto Pause — Output에서 빠질 때 일시정지"), isOn: $input.autoPause)
                Toggle(L("Auto Restart — Output에서 빠질 때 처음으로"), isOn: $input.autoRestart)
            }
        }
        .formStyle(.grouped)
        .textFieldStyle(.roundedBorder)
    }

    private var recordTab: some View {
        Form {
            Section(L("MultiCorder (입력별 ISO 녹화)")) {
                Toggle(L("이 입력을 MultiCorder로 녹화"), isOn: $input.multiCorder)
                Text(L("하단 MultiCorder 버튼으로 시작하면 체크된 입력이 각각 별도 파일로 녹화됩니다. 오디오는 이 입력의 프리페이더 신호입니다."))
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
        .formStyle(.grouped)
        .textFieldStyle(.roundedBorder)
    }
}

/// Live title editor (GT): edit texts/colours/visibility, countdown, presets.
struct TitleEditorSheet: View {
    @EnvironmentObject var engine: SwitcherEngine
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var title: TitleInput
    @ViewState private var countdownText = "05:00"
    @ViewState private var selectedField: String? = nil

    init(title: TitleInput) {
        self.title = title
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top, spacing: 14) {
                TitleCanvas(title: title, selected: $selectedField)
                    .frame(width: 480, height: 270)
                VStack(alignment: .leading, spacing: 6) {
                    Text(Lf("%@. %@ — 타이틀 편집", "\(engine.number(of: title))", "\(title.name)")).font(.headline)
                        .lineLimit(2).fixedSize(horizontal: false, vertical: true)
                    Text(Lf("템플릿: %@", "\(title.document.displayName)")).font(.caption).foregroundColor(.secondary)
                        .lineLimit(1).truncationMode(.middle)
                    Text(L("미리보기에서 상자를 드래그해 위치를, 노란 모서리로 크기를 바꿉니다."))
                        .font(.caption).foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(Lf("API: SetText Input=%@ SelectedName=<필드 이름> Value=<텍스트>", "\(engine.number(of: title))"))
                        .font(.caption.monospaced())
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                    Spacer()
                    HStack {
                        Button(L("내 템플릿으로 저장…")) { saveTemplate() }
                        Button(L("파일로 내보내기…")) { exportTemplate() }
                    }
                    HStack {
                        Menu(L("필드 추가")) {
                            Button(L("텍스트")) { addField(.text) }
                            Button(L("도형 (박스)")) { addField(.shape) }
                            Button(L("이미지")) { addField(.image) }
                        }
                        .fixedSize()
                        Button(L("선택 필드 삭제"), role: .destructive) {
                            if let id = selectedField { title.document.fields.removeAll { $0.id == id }; selectedField = nil }
                        }
                        .disabled(selectedField == nil)
                    }
                }
            }
            .padding()

            Form {
                Section(L("필드")) {
                    ForEach(title.document.fields.indices, id: \.self) { i in
                        fieldRow(i)
                    }
                }
                if title.document.fields.contains(where: { $0.mode == .countdown }) {
                    Section(L("카운트다운")) {
                        TimelineView(.periodic(from: .now, by: 1)) { _ in
                            HStack {
                                Text(L("현재 타이틀에 표시되는 시간"))
                                    .foregroundColor(.secondary)
                                Spacer()
                                if let field = title.document.fields.first(where: { $0.mode == .countdown }) {
                                    Text(title.displayText(field))
                                        .font(.system(.title3, design: .monospaced).weight(.semibold))
                                        .monospacedDigit()
                                } else {
                                    Text("—").foregroundColor(.secondary)
                                }
                            }
                        }
                        HStack {
                            TextField(L("시간 (mm:ss 또는 hh:mm:ss)"), text: $countdownText)
                                .frame(width: 140)
                            Button(L("설정")) {
                                if let s = TitleInput.parseTime(countdownText) { title.setCountdown(s) }
                            }
                            Button(title.countdownRunning && !title.countdownPaused ? L("일시정지") : L("시작")) {
                                if title.countdownRunning { title.pauseCountdown() } else { title.startCountdown() }
                            }
                            Button(L("정지 + 처음 값으로 리셋")) { title.resetCountdown() }
                                .help(L("카운트다운을 멈추고 설정된 시작 시간으로 되돌립니다. Output/오버레이의 타이틀은 그대로 유지됩니다."))
                            Button(L("+30초")) { title.adjustCountdown(by: 30) }
                            Button(L("-30초")) { title.adjustCountdown(by: -30) }
                        }
                        Toggle(L("Output/오버레이에 올리면 자동 시작 (끝난 경우 처음부터)"), isOn: $title.document.autoStartCountdown)
                    }
                }
                if title.document.fields.contains(where: { $0.mode == .ticker }) {
                    Section(L("티커")) {
                        HStack {
                            Text(L("속도"))
                            Slider(value: $title.document.tickerSpeed, in: 0.02...0.5)
                        }
                    }
                }
                Section(L("프리셋 (SelectTitlePreset)")) {
                    HStack {
                        Button(L("현재 텍스트를 프리셋으로 저장")) { title.savePreset() }
                        Spacer()
                        Text(Lf("%@개", "\(title.document.presets.count)"))
                    }
                    ForEach(title.document.presets.indices, id: \.self) { i in
                        HStack {
                            Text("\(i)")
                                .font(.system(size: 11).monospacedDigit())
                                .frame(width: 20)
                            Text(title.document.presets[i].values.sorted().joined(separator: " / "))
                                .lineLimit(1)
                            Spacer()
                            if title.document.selectedPreset == i { Image(systemName: "checkmark") }
                            Button(L("적용")) { title.applyPreset(i) }
                            Button(role: .destructive) {
                                title.document.presets.remove(at: i)
                            } label: {
                                Image(systemName: "trash")
                            }
                            .buttonStyle(.borderless)
                        }
                    }
                }
                Section(L("애니메이션")) {
                    Picker(L("효과"), selection: $title.document.inOutEffect) {
                        ForEach(TitleAnimation.allCases) { Text($0.label).tag($0) }
                    }
                    HStack {
                        Text(L("인/아웃 시간"))
                        Slider(value: $title.document.animateSeconds, in: 0...2)
                        Text(String(format: L("%.1f초"), title.document.animateSeconds)).frame(width: 50)
                        Button(L("In 재생")) { title.beginAnimation() }
                        Button(L("Out 재생")) { title.beginAnimation(out: true) }
                    }
                }
            }
            .formStyle(.grouped)
            .textFieldStyle(.roundedBorder)

            HStack {
                Spacer()
                Button(L("닫기")) { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding()
        }
        .frame(width: 900, height: 760)   // ≤ 780 main window / 13" screen; the Form below scrolls
        .onAppear {
            countdownText = TitleInput.formatCountdown(title.document.countdownSeconds)
        }
    }

    private func addField(_ kind: TitleFieldKind) {
        let base = kind == .text ? "Text" : (kind == .shape ? "Box" : "Image")
        var n = 1
        while title.document.fields.contains(where: { $0.id == "\(base)\(n).\(kind == .text ? "Text" : kind == .shape ? "Fill" : "Source")" }) { n += 1 }
        let id = "\(base)\(n).\(kind == .text ? "Text" : kind == .shape ? "Fill" : "Source")"
        var f = TitleField(id: id, kind: kind, text: kind == .text ? L("텍스트") : "",
                           color: kind == .shape ? "#000000B3" : "#FFFFFF", x: 0.35, y: 0.45, w: 0.3, h: 0.1)
        if kind == .image { f.w = 0.15; f.h = 0.15 }
        // shapes go under the existing texts
        if kind == .shape { title.document.fields.insert(f, at: 0) } else { title.document.fields.append(f) }
        selectedField = id
    }

    private func saveTemplate() {
        let a = NSAlert()
        a.messageText = L("내 템플릿으로 저장")
        a.informativeText = L("이름을 입력하세요. Add Input › Title 목록에 ★로 표시됩니다.")
        let tf = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        tf.stringValue = title.document.name.isEmpty ? title.name : title.document.name
        a.accessoryView = tf
        a.addButton(withTitle: L("저장"))
        a.addButton(withTitle: L("취소"))
        guard a.runModal() == .alertFirstButtonReturn else { return }
        let name = tf.stringValue.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        TitleLibrary.shared.save(title.document, name: name)
        title.document.name = name
    }

    private func exportTemplate() {
        let p = NSSavePanel()
        p.nameFieldStringValue = (title.document.name.isEmpty ? title.name : title.document.name) + ".bmtitle"
        guard p.runModal() == .OK, let url = p.url else { return }
        var d = title.document
        d.presets = []; d.selectedPreset = -1
        if d.name.isEmpty { d.name = url.deletingPathExtension().lastPathComponent }
        let enc = JSONEncoder(); enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try? enc.encode(d).write(to: url)
    }

    @ViewBuilder private func fieldRow(_ i: Int) -> some View {
        let f = title.document.fields[i]
        VStack(alignment: .leading, spacing: 4) {
            if selectedField == f.id {
                HStack(spacing: 8) {
                    Text(L("선택됨")).font(.caption.bold()).foregroundColor(.yellow)
                    if f.kind == .shape {
                        Text(L("그라데이션 끝 색")).font(.caption)
                        TextField("", text: $title.document.fields[i].color2, prompt: Text(L("#RRGGBB(AA) — 비우면 단색"))).labelsHidden().frame(width: 170)
                        ColorSwatch(hex: f.color2.isEmpty ? f.color : f.color2)
                        Text(L("둥글게")).font(.caption)
                        Slider(value: $title.document.fields[i].cornerRadius, in: 0...0.08).frame(width: 90)
                    }
                    if f.kind == .text {
                        Toggle(L("그림자"), isOn: $title.document.fields[i].shadow).toggleStyle(.checkbox)
                        Text(L("외곽선")).font(.caption)
                        TextField("", text: $title.document.fields[i].strokeColor, prompt: Text("#000000")).labelsHidden().frame(width: 80)
                        Slider(value: $title.document.fields[i].strokeWidth, in: 0...8).frame(width: 80)
                    }
                    Text(String(format: "X %.3f Y %.3f W %.3f H %.3f", f.x, f.y, f.w, f.h))
                        .font(.caption.monospacedDigit()).foregroundColor(.secondary)
                }
                .controlSize(.small)
            }
            HStack {
                Toggle("", isOn: $title.document.fields[i].visible)
                    .labelsHidden()
                    .help(L("보이기 (SetTextVisible)"))
                Button { selectedField = f.id } label: { Text(f.id).lineLimit(1).truncationMode(.middle) }
                    .buttonStyle(.plain)
                    .font(.system(size: 11, weight: .semibold).monospaced())
                    .foregroundColor(selectedField == f.id ? .yellow : .primary)
                    .frame(width: 150, alignment: .leading)
                switch f.kind {
                case .text:
                    if f.mode == .plain || f.mode == .ticker {
                        TextField("", text: $title.document.fields[i].text, prompt: Text(L("텍스트"))).labelsHidden()
                    } else {
                        Text(f.mode == .countdown ? L("카운트다운 표시") : L("현재 시각 표시"))
                            .foregroundColor(.secondary)
                        Spacer()
                    }
                case .image:
                    TextField("", text: $title.document.fields[i].imagePath, prompt: Text(L("이미지 경로 또는 URL"))).labelsHidden()
                    Button(L("찾기…")) {
                        let p = NSOpenPanel()
                        p.allowedContentTypes = [.image]
                        if p.runModal() == .OK, let u = p.url { title.document.fields[i].imagePath = u.path }
                    }
                case .shape:
                    Text(L("도형 (SetColor)")).foregroundColor(.secondary)
                    Spacer()
                }
                TextField("", text: $title.document.fields[i].color, prompt: Text("#RRGGBB(AA)"))
                    .labelsHidden()
                    .frame(width: 100)
                    .font(.system(size: 11).monospaced())
                ColorSwatch(hex: f.color)
            }
            if f.kind == .text {
                HStack {
                    Text(L("크기")).font(.caption)
                    Slider(value: $title.document.fields[i].fontSize, in: 0.015...0.2)
                        .frame(width: 140)
                    Picker("", selection: $title.document.fields[i].align) {
                        Text(L("왼쪽")).tag("left")
                        Text(L("가운데")).tag("center")
                        Text(L("오른쪽")).tag("right")
                    }
                    .labelsHidden()
                    .frame(width: 110)
                    Toggle(L("굵게"), isOn: $title.document.fields[i].bold)
                        .toggleStyle(.checkbox)
                    Text(L("폰트")).font(.caption)
                    TextField("", text: $title.document.fields[i].fontName, prompt: Text("Helvetica Neue"))
                        .labelsHidden()
                        .frame(width: 140)
                    Spacer()
                }
                .controlSize(.small)
            }
        }
    }
}

struct ColorSwatch: View {
    let hex: String

    var body: some View {
        let c = HexColor.parse(hex) ?? (1, 1, 1, 1)
        RoundedRectangle(cornerRadius: 3)
            .fill(Color(.sRGB, red: Double(c.0), green: Double(c.1), blue: Double(c.2), opacity: Double(c.3)))
            .frame(width: 18, height: 18)
            .overlay(RoundedRectangle(cornerRadius: 3).stroke(Color.white.opacity(0.4)))
    }
}
