import SwiftUI
import AppKit

struct OutputsSheet: View {
    @EnvironmentObject var engine: SwitcherEngine
    @Environment(\.dismiss) private var dismiss
    var focusKind: OutputKind? = nil
    @ViewState private var selection: UUID? = nil

    init(focusKind: OutputKind? = nil) {
        self.focusKind = focusKind
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(L("출력")).font(.headline)
                Spacer()
                Menu {
                    ForEach(OutputKind.allCases, id: \.self) { k in
                        Button {
                            var c = OutputConfig.defaultConfig(kind: k)
                            let same = engine.outputs.filter { $0.config.kind == k }.count
                            if same > 0 { c.name += " \(same + 1)" }
                            engine.addOutput(c)
                            selection = c.id
                        } label: {
                            Label(k.label, systemImage: k.symbol)
                        }
                    }
                    Divider()
                    Button {
                        selection = engine.addReturnFeed().id
                    } label: {
                        Label(L("리턴 피드 (SRT, 현장으로 되돌려 보내기)"), systemImage: "arrow.uturn.backward.circle")
                    }
                } label: {
                    Label(L("출력 추가"), systemImage: "plus")
                }
                .fixedSize()
            }
            .padding()

            BusSourcesBar()
                .padding(.horizontal)
                .padding(.bottom, 8)

            HSplitView {
                List(selection: $selection) {
                    ForEach(engine.outputs) { o in
                        OutputRow(output: o).tag(o.id)
                    }
                }
                .frame(minWidth: 300, idealWidth: 320, maxWidth: 380)

                Group {
                    if let id = selection, let o = engine.outputs.first(where: { $0.id == id }) {
                        OutputEditor(output: o)
                    } else {
                        Text(L("왼쪽에서 출력을 선택하거나 새로 추가하세요."))
                            .foregroundColor(.secondary)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }
                .frame(minWidth: 560)
            }

            HStack {
                Text(Lf("프로그램 포맷: %@ — 모든 출력은 이 포맷으로 인코딩됩니다.", "\(engine.format.name)"))
                    .font(.caption)
                    .foregroundColor(.secondary)
                Spacer()
                Button(L("닫기")) { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding()
        }
        .frame(minWidth: 980, idealWidth: 1040, minHeight: 700, idealHeight: 760)
        .onAppear {
            guard selection == nil else { return }
            if let k = focusKind {
                // Open the existing output of this kind, or create one (vMix-style "Record ⚙" etc.)
                if let o = engine.outputs.first(where: { $0.config.kind == k }) {
                    selection = o.id
                } else {
                    let c = OutputConfig.defaultConfig(kind: k)
                    engine.addOutput(c)
                    selection = c.id
                }
            } else {
                selection = engine.outputs.last?.id
            }
        }
    }
}

/// Output 2–4 source selection (SetOutput2/3/4).
struct BusSourcesBar: View {
    @EnvironmentObject var engine: SwitcherEngine

    var body: some View {
        HStack(spacing: 12) {
            Text(L("Output 1 = 프로그램")).font(.caption).foregroundColor(.secondary).fixedSize()
            ForEach(2...4, id: \.self) { b in
                HStack(spacing: 4) {
                    Text("Output \(b)").font(.system(size: 12, weight: .semibold))
                        .lineLimit(1)
                        .fixedSize()
                    Menu {
                        Button(L("Output (프로그램)")) { engine.setBusSource(b, .program) }
                        Button(L("Clean (오버레이 제외)")) { engine.setBusSource(b, .clean) }
                        Button("Preview") { engine.setBusSource(b, .preview) }
                        Button("MultiView") { engine.setBusSource(b, .multiview) }
                        Section(L("입력")) {
                            ForEach(engine.inputs) { i in
                                Button("\(engine.number(of: i)). \(i.name)") { engine.setBusSource(b, .input(i.id)) }
                            }
                        }
                    } label: {
                        Text(sourceName(engine.busSources[b - 2]))
                    }
                    .fixedSize()
                }
            }
            Spacer()
        }
    }

    private func sourceName(_ s: BusSource) -> String {
        if case .input(let id) = s { return engine.input(withID: id).map { Lf("입력: %@", "\($0.name)") } ?? L("입력 (없음)") }
        return s.label
    }
}

struct OutputRow: View {
    @EnvironmentObject var engine: SwitcherEngine
    @ObservedObject var output: OutputChannel

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: output.config.kind.symbol)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 2) {
                Text(output.config.name).font(.system(size: 13, weight: .semibold))
                Text(output.message.isEmpty ? output.config.kind.label : output.message)
                    .font(.system(size: 11))
                    .foregroundColor(output.state == Int32(MC_STATE_ERROR) ? .orange : .secondary)
                    .lineLimit(1)
                if !output.statsText.isEmpty {
                    Text(output.statsText)
                        .font(.system(size: 10).monospacedDigit())
                        .foregroundColor(.secondary)
                }
            }
            Spacer()
            Button {
                if output.running { engine.stopOutput(output) } else { _ = engine.startOutput(output) }
            } label: {
                Text(output.running ? L("중지") : L("시작"))
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(.white)
                    .frame(width: 52, height: 24)
                    .background(output.running ? Theme.live : Theme.program)
                    .clipShape(RoundedRectangle(cornerRadius: 5))
            }
            .buttonStyle(.plain)
        }
        .padding(.vertical, 3)
        .contextMenu {
            Button(L("삭제"), role: .destructive) { engine.removeOutput(output) }
        }
    }
}

struct OutputEditor: View {
    @EnvironmentObject var engine: SwitcherEngine
    @ObservedObject var output: OutputChannel

    var body: some View {
        Form {
            TextField(L("이름"), text: $output.config.name)
            Section(L("라우팅")) {
                Picker(L("비디오 소스"), selection: $output.config.bus) {
                    ForEach(1...4, id: \.self) { b in
                        Text(b == 1 ? L("Output 1 (프로그램)") : "Output \(b) — \(engine.busSources[b - 2].label)").tag(b)
                    }
                }
                Picker(L("오디오 버스"), selection: $output.config.audioBus) {
                    ForEach(AudioBus.all, id: \.self) { b in
                        Text(b == "M" ? "Master" : "Bus \(b)").tag(b)
                    }
                }
            }
            switch output.config.kind {
            case .stream: streamFields
            case .record: recordFields
            case .ndi:
                Section("NDI") {
                    TextField(L("NDI 소스 이름"), text: $output.config.ndiName)
                    if mc_ndi_available() == 0 {
                        Text(L("NDI 런타임이 설치되어 있지 않습니다.")).foregroundColor(.orange)
                    }
                }
            case .decklink:
                Section("DeckLink") {
                    Stepper(Lf("장치 번호: %@", "\(output.config.deckLinkIndex + 1)"), value: $output.config.deckLinkIndex, in: 0...15)
                    Text(deckLinkList())
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Text(L("프로그램 포맷과 같은 해상도/프레임레이트로 출력됩니다 (8-bit YUV, 48kHz 2ch)."))
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
            if output.config.kind == .stream || output.config.kind == .record { encoderFields }
            if output.config.kind == .record, !output.lastFile.isEmpty {
                Button(L("Finder에서 보기")) {
                    NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: output.lastFile)])
                }
            }
            HStack {
                Spacer()
                Button(role: .destructive) {
                    engine.removeOutput(output)
                } label: {
                    Text(L("이 출력 삭제"))
                }
            }
        }
        .formStyle(.grouped)
        .textFieldStyle(.roundedBorder)
        .disabled(output.running)
        .overlay(alignment: .top) {
            if output.running {
                Text(L("실행 중에는 설정을 바꿀 수 없습니다"))
                    .font(.caption)
                    .padding(6)
                    .background(Color.orange.opacity(0.3))
                    .clipShape(Capsule())
                    .padding(.top, 4)
            }
        }
    }

    @ViewBuilder private var streamFields: some View {
        Section(L("대상")) {
            Picker(L("프로토콜"), selection: $output.config.proto) {
                ForEach(StreamProtocol.allCases, id: \.self) { Text($0.label).tag($0) }
            }
            switch output.config.proto {
            case .rtmp:
                TextField(L("서버 URL"), text: $output.config.rtmpServer)
                SecureField(L("스트림 키"), text: $output.config.streamKey)
                TextField(L("사용자 이름 (선택)"), text: $output.config.rtmpUsername)
                SecureField(L("비밀번호 (선택)"), text: $output.config.rtmpPassword)
                HStack {
                    Text(L("빠른 설정")).foregroundColor(.secondary)
                    Spacer()
                    Button("YouTube") { output.config.rtmpServer = "rtmp://a.rtmp.youtube.com/live2" }
                    Button("Twitch") { output.config.rtmpServer = "rtmp://live.twitch.tv/app" }
                    Button("Facebook") { output.config.rtmpServer = "rtmps://live-api-s.facebook.com:443/rtmp" }
                }
                .controlSize(.small)
            case .srt:
                Picker(L("모드"), selection: $output.config.srtMode) {
                    Text(L("콜러 (상대에게 접속)")).tag("caller")
                    Text(L("리스너 (접속 대기)")).tag("listener")
                }
                if output.config.srtMode == "caller" {
                    TextField(L("호스트"), text: $output.config.srtHost)
                }
                NumberField(L("포트"), value: $output.config.srtPort, in: 1...65535)
                NumberField(L("지연 (latency)"), value: $output.config.srtLatencyMs, in: 20...8000, unit: "ms")
                SecureField(L("암호 (선택, 10자 이상)"), text: $output.config.srtPassphrase)
                TextField(L("Stream ID (선택)"), text: $output.config.srtStreamID)
            case .custom:
                TextField("URL", text: $output.config.customURL)
                Text(L("예: srt://host:port?mode=caller, rtmp://…, udp://239.0.0.1:5000?pkt_size=1316"))
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            Text(maskedURL)
                .font(.caption.monospaced())
                .foregroundColor(.secondary)
                .textSelection(.enabled)
        }
        Section(L("이중 경로 (백업 송출)")) {
            HStack {
                Button(L("보조 경로 추가")) { engine.addBackupPath(of: output) }
                Text(L("같은 설정의 출력을 하나 더 만듭니다 — 다른 서버/회선(예: SRT 두 번째 주소, YouTube 백업 URL)을 넣으면 Stream 버튼 한 번으로 두 경로가 동시에 나갑니다."))
                    .font(.caption).foregroundColor(.secondary)
            }
        }
    }

    private var maskedURL: String {
        let url = output.config.streamURL()
        var masked = url
        if !output.config.streamKey.isEmpty {
            masked = masked.replacingOccurrences(of: output.config.streamKey, with: "••••")
        }
        if !output.config.srtPassphrase.isEmpty {
            masked = masked.replacingOccurrences(of: output.config.srtPassphrase, with: "••••")
        }
        return masked
    }

    @ViewBuilder private var recordFields: some View {
        Section(L("녹화")) {
            HStack {
                TextField(L("폴더"), text: $output.config.recordFolder)
                Button(L("선택…")) {
                    let p = NSOpenPanel()
                    p.canChooseDirectories = true
                    p.canChooseFiles = false
                    p.canCreateDirectories = true
                    if p.runModal() == .OK, let u = p.url { output.config.recordFolder = u.path }
                }
            }
            Picker(L("컨테이너"), selection: $output.config.recordContainer) {
                Text("MOV").tag("mov")
                Text("MP4").tag("mp4")
                Text(L("MPEG-TS (중단에 강함)")).tag("ts")
            }
            .disabled(output.config.videoCodec == "prores")
            Stepper(output.config.splitMinutes == 0 ? L("새 파일 분할: 끔") : Lf("새 파일 분할: %@분마다", "\(output.config.splitMinutes)"),
                    value: $output.config.splitMinutes, in: 0...240, step: 5)
        }
        Section(L("멀티트랙 오디오")) {
            HStack(spacing: 6) {
                Text(L("트랙 1:")).foregroundColor(.secondary)
                Text(output.config.audioBus == "M" ? "Master" : "Bus \(output.config.audioBus)").fontWeight(.semibold)
                Text(L("· 추가 트랙:")).foregroundColor(.secondary)
                ForEach(AudioBus.all, id: \.self) { b in
                    Toggle(b, isOn: Binding(get: { output.config.extraAudioBuses.uppercased().contains(b) },
                                            set: { on in
                                                var s = output.config.extraAudioBuses.uppercased().filter { String($0) != b }
                                                if on { s += b }
                                                output.config.extraAudioBuses = AudioBus.all.filter { s.contains($0) }.joined()
                                            }))
                    .toggleStyle(.button)
                }
            }
            if !output.config.extraBusIndices.isEmpty {
                Text(Lf("파일에 오디오 트랙 %@개가 들어갑니다: 1 = %@, %@", "\(output.config.extraBusIndices.count + 1)",
                        output.config.audioBus == "M" ? "Master" : output.config.audioBus,
                        output.config.extraBusIndices.enumerated().map { "\($0.offset + 2) = \(AudioBus.all[$0.element] == "M" ? "Master" : AudioBus.all[$0.element])" }.joined(separator: ", ")))
                    .font(.caption).foregroundColor(.secondary)
            } else {
                Text(L("버스(마이크만, 음악만 …)를 각각 별도 트랙으로 녹화해 편집에서 다시 믹스할 수 있습니다. MOV/MP4/TS 모두 지원."))
                    .font(.caption).foregroundColor(.secondary)
            }
        }
    }

    @ViewBuilder private var encoderFields: some View {
        Section(L("인코딩")) {
            Picker(L("비디오 코덱"), selection: $output.config.videoCodec) {
                Text("H.264").tag("h264")
                Text("HEVC (H.265)").tag("hevc")
                if output.config.kind == .record { Text("ProRes 422").tag("prores") }
            }
            if output.config.videoCodec != "prores" {
                NumberField(L("비디오 비트레이트"), value: $output.config.videoKbps, in: 500...100000, unit: "kbps")
                Stepper(Lf("키프레임 간격: %@ 초", "\(String(format: "%.0f", output.config.keyintSeconds))"),
                        value: $output.config.keyintSeconds, in: 1...10, step: 1)
            }
            Picker(L("오디오 비트레이트 (AAC)"), selection: $output.config.audioKbps) {
                ForEach([96, 128, 160, 192, 256, 320], id: \.self) { Text("\($0) kbps").tag($0) }
            }
            Toggle(L("하드웨어 인코더 (VideoToolbox) 우선"), isOn: $output.config.hardwareEncoder)
            Picker(L("방송 딜레이"), selection: $output.config.delaySeconds) {
                Text(L("끔 (실시간)")).tag(0)
                ForEach([5, 10, 15, 30, 60, 120, 300, 600, 900], id: \.self) { s in
                    Text(s < 60 ? Lf("%@초", "\(s)") : Lf("%@분", "\(s / 60)")).tag(s)
                }
            }
            if output.config.delaySeconds > 0 {
                Text(L("인코딩된 영상을 그만큼 늦게 내보냅니다 (화질 손실 없음, 메모리 ≈ 비트레이트 × 시간). 위쪽 DUMP 버튼으로 지연분을 버리고 즉시 실시간으로 넘어갈 수 있습니다."))
                    .font(.caption).foregroundColor(.secondary)
            }
        }
    }

    private func deckLinkList() -> String {
        var buf = [CChar](repeating: 0, count: 4096)
        let n = mc_decklink_list(&buf, Int32(buf.count))
        return n == 0 ? L("감지된 DeckLink 장치 없음") : String(cString: buf).trimmingCharacters(in: .newlines)
    }
}

struct SettingsView: View {
    @EnvironmentObject var engine: SwitcherEngine
    @AppStorage("ndiExtraIPs") private var ndiExtraIPs = ""
    @AppStorage(APIAccess.modeKey) private var apiMode = "lan"
    @AppStorage(APIAccess.passwordKey) private var apiPassword = ""
    @AppStorage(APIAccess.allowKey) private var apiAllowed = ""
    @ViewState private var formatMessage = ""

    var body: some View {
        TabView {
            Form {
                Picker(L("프로그램 포맷"), selection: Binding(get: { engine.format.id }, set: { id in
                    if !engine.setFormat(VideoFormat.preset(id: id)) {
                        formatMessage = L("출력을 모두 중지한 뒤 포맷을 바꿀 수 있습니다.")
                    } else {
                        formatMessage = ""
                    }
                })) {
                    ForEach(VideoFormat.presets) { Text($0.name).tag($0.id) }
                }
                if !formatMessage.isEmpty {
                    Text(formatMessage).foregroundColor(.orange)
                }
                Text(L("입력은 해상도/비율과 관계없이 프로그램 포맷에 맞춰 레터박스로 스케일됩니다."))
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            .formStyle(.grouped)
            .textFieldStyle(.roundedBorder)
            .tabItem { Label(L("비디오"), systemImage: "film") }

            Form {
                TextField(L("NDI 추가 검색 IP (쉼표로 구분)"), text: $ndiExtraIPs)
                    .onSubmit { mc_ndi_set_extra_ips(ndiExtraIPs) }
                Text(L("다른 서브넷/원격지의 NDI 장비 IP를 입력하면 mDNS 없이도 소스를 찾습니다."))
                    .font(.caption)
                    .foregroundColor(.secondary)
                LabeledContent(L("NDI 런타임"), value: String(cString: mc_ndi_version()))
                LabeledContent(L("웹 브라우저 엔진"), value: mc_web_available() != 0 ? String(cString: mc_web_version()) : L("Safari/WebKit (내장 엔진 없음)"))
                LabeledContent("DeckLink", value: mc_decklink_available() != 0 ? L("사용 가능") : L("없음"))
                LabeledContent(L("웹 리모트 / API"), value: engine.apiStatus)
                Section(L("원격 제어 보안 (API 8088 / 8099)")) {
                    Picker(L("허용"), selection: $apiMode) {
                        Text(L("같은 네트워크의 장비 (Companion·Stream Deck·휴대폰)")).tag("lan")
                        Text(L("이 맥에서만")).tag("local")
                        Text(L("끄기")).tag("off")
                    }
                    if apiMode == "lan" {
                        TextField(L("허용할 IP만 (쉼표로 구분, 비우면 모두)"), text: $apiAllowed)
                    }
                    SecureField(L("웹/HTTP 비밀번호 (비우면 없음)"), text: $apiPassword)
                    Text(L("다른 웹사이트가 브라우저를 통해 명령을 보내는 것은 항상 차단됩니다. 비밀번호를 정하면 웹 리모트·HTTP API 접속 때 묻습니다(사용자 이름은 아무거나). TCP 8099(Companion vMix 모듈)는 IP 제한만 적용됩니다. 바꾼 설정은 바로 적용됩니다."))
                        .font(.caption).foregroundColor(.secondary)
                }
            }
            .formStyle(.grouped)
            .textFieldStyle(.roundedBorder)
            .tabItem { Label(L("네트워크"), systemImage: "network") }

            GeneralSettings()
                .tabItem { Label(L("일반"), systemImage: "gearshape") }

            AboutView()
                .tabItem { Label(L("정보"), systemImage: "info.circle") }

            ShortcutsEditor()
                .tabItem { Label(L("단축키"), systemImage: "keyboard") }
        }
        .frame(width: 860, height: 520)
    }
}
