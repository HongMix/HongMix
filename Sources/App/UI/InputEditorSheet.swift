import SwiftUI
import AVFoundation
import AppKit
import UniformTypeIdentifiers

/// "Add Input" window: category list on the left, options on the right, OK / Cancel at the bottom.
/// Also used to change the source of an existing input.
struct InputEditorSheet: View {
    @EnvironmentObject var engine: SwitcherEngine
    @Environment(\.dismiss) private var dismiss

    enum Category: String, CaseIterable, Identifiable {
        case video = "Video"
        case list = "List"
        case colour = "Colour"
        case ndiDesktop = "NDI / Desktop Capture"
        case image = "Image"
        case photos = "Photos"
        case powerpoint = "PowerPoint"
        case title = "Title"
        case camera = "Camera"
        case stream = "Stream / SRT"
        case browser = "Web Browser"
        case audio = "Audio Input"
        case videoCall = "Video Call"
        case virtualSet = "Virtual Set"
        case replay = "Instant Replay"

        var id: String { rawValue }
        var available: Bool {
            switch self {
            case .list, .photos, .powerpoint, .videoCall, .virtualSet, .replay: return false
            default: return true
            }
        }
        var symbol: String {
            switch self {
            case .video: return "film"
            case .list: return "list.bullet"
            case .colour: return "paintpalette"
            case .ndiDesktop: return "network"
            case .image: return "photo"
            case .photos: return "photo.on.rectangle"
            case .powerpoint: return "rectangle.on.rectangle.angled"
            case .title: return "textformat"
            case .camera: return "video"
            case .stream: return "antenna.radiowaves.left.and.right"
            case .browser: return "globe"
            case .audio: return "mic"
            case .videoCall: return "phone.connection"
            case .virtualSet: return "cube"
            case .replay: return "gobackward"
            }
        }
        static func of(_ k: InputKind) -> Category {
            switch k {
            case .media: return .video
            case .color: return .colour
            case .ndi, .screen: return .ndiDesktop
            case .image: return .image
            case .title: return .title
            case .camera, .decklink: return .camera
            case .stream: return .stream
            case .browser: return .browser
            case .audio: return .audio
            }
        }
    }

    enum StreamType: String, CaseIterable, Identifiable {
        case srtCaller = "SRT (Caller)"
        case srtListener = "SRT (Listener)"
        case srtRendezvous = "SRT (Rendezvous)"
        case rtmpServer = "RTMP (Server — 푸시 받기)"
        case pull = "RTMP / HLS / HTTP (URL)"
        case rtspUDP = "RTSP over UDP"
        case rtspTCP = "RTSP over TCP"
        case tsUDP = "Transport Stream over UDP"
        case tsTCP = "Transport Stream over TCP (Server)"
        case tsTCPPull = "Transport Stream over TCP Pull"
        var id: String { rawValue }
        var isSRT: Bool { self == .srtCaller || self == .srtListener || self == .srtRendezvous }
        var needsHost: Bool { self == .srtCaller || self == .srtRendezvous || self == .tsTCPPull }
        var needsURL: Bool { self == .pull || self == .rtspUDP || self == .rtspTCP }
    }

    let editing: InputSource?
    @ViewState private var category: Category
    @ViewState private var cfg: InputConfig
    @ViewState private var nameEdited = false

    // stream
    @ViewState private var streamType: StreamType = .srtListener
    @ViewState private var host = ""
    @ViewState private var port = 9000
    @ViewState private var latency = 200
    @ViewState private var passphrase = ""
    @ViewState private var streamID = ""
    @ViewState private var rtmpPath = "live/stream"
    @ViewState private var pullURL = ""
    // NDI / desktop
    @ViewState private var ndiMode = 0           // 0 NDI, 1 Desktop Capture
    @ViewState private var ndiSources: [String] = []
    @ViewState private var ndiSearching = false
    @ViewState private var targets = CaptureTargets()
    @ViewState private var targetsError: String? = nil
    // camera
    @ViewState private var deckLinkDevices: [String] = []
    @ViewState private var cameraSelection = ""  // "av:<uniqueID>" or "dl:<index>"
    @ViewState private var colorValue = Color.blue

    init(kind: InputKind, editing: InputSource?) {
        self.editing = editing
        let c = editing?.currentConfig() ?? InputConfig(kind: kind, name: InputEditorSheet.defaultName(kind))
        _cfg = ViewState(initialValue: c)
        _category = ViewState(initialValue: Category.of(kind))
        _ndiMode = ViewState(initialValue: kind == .screen ? 1 : 0)
        _nameEdited = ViewState(initialValue: editing != nil)
    }

    static func defaultName(_ k: InputKind) -> String {
        switch k {
        case .camera: return "Camera"
        case .media: return "Video"
        case .stream: return "Stream"
        case .ndi: return "NDI"
        case .decklink: return "DeckLink"
        case .color: return "Colour"
        case .image: return "Image"
        case .title: return "Title"
        case .screen: return "Desktop Capture"
        case .browser: return "Web Browser"
        case .audio: return "Audio Input"
        }
    }

    private var kind: InputKind {
        switch category {
        case .video: return .media
        case .colour: return .color
        case .ndiDesktop: return ndiMode == 1 ? .screen : .ndi
        case .image: return .image
        case .title: return .title
        case .camera: return cameraSelection.hasPrefix("dl:") ? .decklink : .camera
        case .stream: return .stream
        case .browser: return .browser
        case .audio: return .audio
        default: return .media
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                // category list
                List(selection: Binding<Category?>(get: { category }, set: { c in
                    if let c = c, c.available, editing == nil { select(c) }
                })) {
                    ForEach(Category.allCases) { c in
                        Label(c.rawValue, systemImage: c.symbol)
                            .foregroundColor(c.available ? .primary : .secondary.opacity(0.5))
                            .tag(c)
                    }
                }
                .listStyle(.sidebar)
                .frame(width: 210)
                .disabled(editing != nil)

                Divider()

                VStack(alignment: .leading, spacing: 0) {
                    Form {
                        content
                        Section {
                            TextField(L("이름"), text: Binding(get: { cfg.name }, set: { cfg.name = $0; nameEdited = true }))
                        }
                    }
                    .formStyle(.grouped)
                    .textFieldStyle(.roundedBorder)
                }
            }

            Divider()
            HStack {
                if editing != nil {
                    Text(L("소스를 바꿔도 위치·색보정·오디오 설정은 유지됩니다."))
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("OK") { commit() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!isValid)
            }
            .padding(12)
        }
        .frame(width: 820, height: 560)
        .onAppear(perform: prepare)
    }

    private func select(_ c: Category) {
        category = c
        if !nameEdited { cfg.name = InputEditorSheet.defaultName(kind) }
        prepareCategory()
    }

    @ViewBuilder private var content: some View {
        switch category {
        case .video: videoSection
        case .colour: colourSection
        case .ndiDesktop: ndiDesktopSection
        case .image: imageSection
        case .title: titleSection
        case .camera: cameraSection
        case .stream: streamSection
        case .browser: browserSection
        case .audio: audioSection
        default:
            Section {
                Text(Lf("%@ 입력은 HongMix에서 아직 지원하지 않습니다.", "\(category.rawValue)"))
                    .foregroundColor(.secondary)
            }
        }
    }

    // MARK: Video

    @ViewBuilder private var videoSection: some View {
        Section("Video") {
            HStack {
                TextField(L("파일"), text: $cfg.url)
                Button("Browse…") {
                    let ps = pickFiles(types: [.movie, .audiovisualContent, .audio, .mpeg4Movie, .quickTimeMovie])
                    if let p = ps.first {
                        cfg.url = p
                        cfg.playlist = ps.count > 1 ? ps : []
                        cfg.playlistIndex = 0
                        if !nameEdited { cfg.name = ps.count > 1 ? Lf("리스트 (%@개)", "\(ps.count)") : (p as NSString).lastPathComponent }
                    }
                }
            }
            if cfg.playlist.count > 1 {
                Text(Lf("리스트 입력: %@개 파일을 차례로 재생합니다 (속성 › List 탭에서 순서 변경·추가).", "\(cfg.playlist.count)"))
                    .font(.caption).foregroundColor(.secondary)
            } else {
                Text(L("여러 파일을 한꺼번에 고르면 차례로 재생되는 리스트 입력이 됩니다 (⌘ 또는 ⇧ 클릭)."))
                    .font(.caption).foregroundColor(.secondary)
            }
            Toggle("Loop", isOn: $cfg.loop)
            Toggle(L("Auto Play (Output으로 갈 때 재생)"), isOn: $cfg.autoPlay)
            Toggle(L("Auto Pause (Output에서 빠질 때 일시정지)"), isOn: $cfg.autoPause)
            Toggle(L("Auto Restart (Output에서 빠질 때 처음으로)"), isOn: $cfg.autoRestart)
            Toggle(L("하드웨어 디코더 사용 (VideoToolbox)"), isOn: $cfg.hardwareDecode)
            Text(L("MP4, MOV(ProRes 4444 알파 포함), MXF, TS, MKV, AVI, MP3, WAV 등 FFmpeg가 읽는 형식"))
                .font(.caption).foregroundColor(.secondary)
        }
    }

    // MARK: Colour

    @ViewBuilder private var colourSection: some View {
        Section("Colour") {
            Picker(L("종류"), selection: $cfg.color) {
                Text("SMPTE Colour Bars").tag("bars")
                Text("Black").tag("black")
                Text("White").tag("white")
                Text(L("투명 (Transparent)")).tag("transparent")
                Text(L("사용자 지정")).tag(cfg.color.hasPrefix("#") ? cfg.color : "#0050C8")
            }
            if cfg.color.hasPrefix("#") {
                ColorPicker(L("색상 (불투명도 포함)"), selection: $colorValue, supportsOpacity: true)
                    .onChange(of: colorValue) { _, newValue in
                        if let c = NSColor(newValue).usingColorSpace(.sRGB) {
                            let a = Int((c.alphaComponent * 255).rounded())
                            cfg.color = a >= 255
                                ? String(format: "#%02X%02X%02X", Int(c.redComponent * 255), Int(c.greenComponent * 255), Int(c.blueComponent * 255))
                                : String(format: "#%02X%02X%02X%02X", Int(c.redComponent * 255), Int(c.greenComponent * 255),
                                         Int(c.blueComponent * 255), a)
                        }
                    }
            }
            Text(L("투명 Colour는 Layers(분할 화면)의 바탕이나 오버레이용 빈 캔버스로 씁니다. 추가한 뒤 ⚙ › Layers 탭에서 4분할·9분할 등을 고르세요."))
                .font(.caption).foregroundColor(.secondary)
        }
    }

    // MARK: NDI / Desktop Capture

    @ViewBuilder private var ndiDesktopSection: some View {
        Section {
            Picker("", selection: $ndiMode) {
                Text("NDI").tag(0)
                Text("Desktop Capture").tag(1)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .onChange(of: ndiMode) { _, _ in
                if !nameEdited { cfg.name = InputEditorSheet.defaultName(kind) }
                prepareCategory()
            }
        }
        if ndiMode == 0 {
            Section(L("NDI 소스")) {
                if mc_ndi_available() == 0 {
                    Text(L("NDI 런타임을 찾을 수 없습니다. NDI Tools 또는 NDI SDK for Apple을 설치하세요."))
                        .foregroundColor(.orange)
                }
                HStack {
                    Text(ndiSearching ? L("검색 중…") : Lf("%@개 발견", "\(ndiSources.count)")).foregroundColor(.secondary)
                    Spacer()
                    Button {
                        refreshNDI()
                    } label: {
                        Label("Refresh", systemImage: "arrow.clockwise")
                    }
                }
                ForEach(ndiSources, id: \.self) { src in
                    sourceRow(src, selected: cfg.ndiSource == src) {
                        cfg.ndiSource = src
                        if !nameEdited { cfg.name = src }
                    }
                }
                TextField(L("직접 입력 (예: MACHINE (Source))"), text: $cfg.ndiSource)
                Toggle("Low Bandwidth", isOn: $cfg.ndiLowBandwidth)
                Text(L("다른 서브넷 장비는 설정 → 네트워크의 'NDI 추가 검색 IP'에 넣으세요."))
                    .font(.caption).foregroundColor(.secondary)
            }
        } else {
            Section(L("디스플레이")) {
                ForEach(targets.displays) { d in
                    sourceRow(d.name, selected: cfg.screenWindowID == 0 && cfg.screenDisplayID == d.id) {
                        cfg.screenDisplayID = d.id
                        cfg.screenWindowID = 0
                        if !nameEdited { cfg.name = d.name }
                    }
                }
            }
            Section(L("창")) {
                if let e = targetsError { Text(e).foregroundColor(.orange) }
                ForEach(targets.windows) { w in
                    sourceRow("\(w.app) — \(w.title)", selected: cfg.screenWindowID == w.id) {
                        cfg.screenWindowID = w.id
                        if !nameEdited { cfg.name = w.app }
                    }
                }
            }
            Section(L("옵션")) {
                Toggle(L("커서 표시"), isOn: $cfg.showCursor)
                Stepper(Lf("프레임레이트: %@ fps", "\(cfg.captureFPS)"), value: $cfg.captureFPS, in: 5...60, step: 5)
            }
        }
    }

    private func sourceRow(_ title: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack {
                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                    .foregroundColor(selected ? .accentColor : .secondary)
                Text(title).lineLimit(1)
                Spacer()
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: Image

    @ViewBuilder private var imageSection: some View {
        Section("Image") {
            HStack {
                TextField(L("파일"), text: $cfg.imagePath)
                Button("Browse…") {
                    if let p = pickFile(types: [.png, .jpeg, .tiff, .gif, .image]) {
                        cfg.imagePath = p
                        if !nameEdited { cfg.name = (p as NSString).lastPathComponent }
                    }
                }
            }
            Text(L("투명 PNG는 오버레이(1~4)로 하단 자막·로고에 사용할 수 있습니다."))
                .font(.caption).foregroundColor(.secondary)
        }
    }

    // MARK: Title

    @ViewBuilder private var titleSection: some View {
        Section(L("Title 템플릿")) {
            if editing == nil {
                TitleGallery(selection: $cfg.title) { doc in
                    if !nameEdited { cfg.name = doc.displayName }
                }
                .frame(minHeight: 340)
            } else {
                Text(Lf("템플릿: %@ — 내용은 ⚙ 메뉴 → '타이틀 편집'에서 바꿉니다.", "\(cfg.title?.displayName ?? "-")"))
            }
            Text(L("추가한 뒤 입력의 ⚙ 메뉴 → '타이틀 편집'에서 텍스트·색·위치(드래그)·애니메이션·프리셋을 바꿉니다. SetText 등 Title API로도 제어됩니다."))
                .font(.caption).foregroundColor(.secondary)
        }
    }

    // MARK: Camera

    @ViewBuilder private var cameraSection: some View {
        Section("Camera") {
            ForEach(CameraInput.videoDevices(), id: \.uniqueID) { d in
                sourceRow(d.localizedName, selected: cameraSelection == "av:" + d.uniqueID) {
                    if cfg.cameraID != d.uniqueID { cfg.cameraFormat = "" }
                    cameraSelection = "av:" + d.uniqueID
                    cfg.cameraID = d.uniqueID
                    if !nameEdited { cfg.name = d.localizedName }
                }
            }
            ForEach(Array(deckLinkDevices.enumerated()), id: \.offset) { item in
                sourceRow(item.element + " (DeckLink)", selected: cameraSelection == "dl:\(item.offset)") {
                    cameraSelection = "dl:\(item.offset)"
                    cfg.deckLinkIndex = item.offset
                    if !nameEdited { cfg.name = item.element }
                }
            }
            if CameraInput.videoDevices().isEmpty && deckLinkDevices.isEmpty {
                Text(L("카메라/캡처 장치를 찾을 수 없습니다.")).foregroundColor(.orange)
            }
        }
        if !cameraSelection.hasPrefix("dl:") {
            Section("Audio") {
                Picker("Audio Device", selection: $cfg.audioDeviceID) {
                    Text(L("없음")).tag("")
                    ForEach(CameraInput.audioDevices(), id: \.uniqueID) { d in
                        Text(d.localizedName).tag(d.uniqueID)
                    }
                }
                Text(L("HDMI/SDI→USB/Thunderbolt 캡처(UltraStudio, Magewell, Elgato 등)도 여기에 나타납니다."))
                    .font(.caption).foregroundColor(.secondary)
            }
            Section(L("포맷 (해상도 · 프레임)")) {
                Picker(L("포맷"), selection: $cfg.cameraFormat) {
                    Text(Lf("자동 — 프로그램(%@)에 맞춤", engine.format.name)).tag("")
                    ForEach(CameraInput.formatOptions(cfg.cameraID), id: \.value) { o in
                        Text(o.label).tag(o.value)
                    }
                    if !cfg.cameraFormat.isEmpty && !CameraInput.formatOptions(cfg.cameraID).contains(where: { $0.value == cfg.cameraFormat }) {
                        Text(cfg.cameraFormat).tag(cfg.cameraFormat)
                    }
                }
                Text(L("자동이면 프로그램 프레임에 맞추고(예: 29.97 → 카메라 30), 어두워도 프레임이 떨어지지 않게 고정합니다. 맥 내장 카메라는 보통 30fps가 최대입니다."))
                    .font(.caption).foregroundColor(.secondary)
            }
        } else {
            Section("DeckLink") {
                Text(L("입력 포맷은 자동 감지되며 임베디드 오디오 2채널을 함께 받습니다."))
                    .font(.caption).foregroundColor(.secondary)
            }
        }
    }

    // MARK: Stream / SRT

    @ViewBuilder private var streamSection: some View {
        Section("Stream / SRT") {
            Picker("Stream Type", selection: $streamType) {
                ForEach(StreamType.allCases) { t in Text(t.rawValue).tag(t) }
            }
            if streamType.needsURL {
                TextField(streamType == .pull ? "URL (rtmp://, https://…m3u8, udp://, rtp://)" : "URL (rtsp://host/stream)",
                          text: $pullURL)
            }
            if streamType.needsHost {
                TextField("Hostname", text: $host)
            }
            if !streamType.needsURL {
                NumberField("Port", value: $port, in: 1...65535)
            }
            if streamType == .rtmpServer {
                TextField(L("App / Stream Key 경로"), text: $rtmpPath)
                Text(Lf("송출 측 URL: rtmp://%@:%@/%@", "\(HTTPAPIServer.localIPAddress() ?? "이 맥 IP")", "\(port)", "\(rtmpPath)")).font(.caption).foregroundColor(.secondary)
            }
            if streamType.isSRT {
                NumberField("Latency", value: $latency, in: 20...8000, unit: "ms")
                SecureField("Passphrase", text: $passphrase)
                TextField("Stream ID", text: $streamID)
                Text(streamType == .srtListener
                     ? Lf("모든 네트워크 어댑터의 이 포트에서 접속을 기다립니다. 송출 장비(LiveU 등)는 srt://%@:%@ 로 Caller 접속하세요.", "\(HTTPAPIServer.localIPAddress() ?? "이 맥 IP")", "\(port)")
                     : streamType == .srtRendezvous ? L("상대방도 같은 포트로 Rendezvous 모드여야 합니다.") : L("지정한 호스트/포트로 접속합니다."))
                    .font(.caption).foregroundColor(.secondary)
                Text(L("Latency는 상대방과 같게, 대략 왕복 지연(ping)의 4배 이상으로 설정하세요."))
                    .font(.caption).foregroundColor(.secondary)
            }
            Toggle("Use Hardware Decoder", isOn: $cfg.hardwareDecode)
            Toggle("Low Latency Mode", isOn: $cfg.lowLatency)
        }
    }

    // MARK: Web Browser

    @ViewBuilder private var browserSection: some View {
        Section("Web Browser") {
            TextField("URL", text: $cfg.browserURL)
            HStack {
                Stepper("Width: \(cfg.browserWidth)", value: $cfg.browserWidth, in: 320...3840, step: 10)
                Stepper("Height: \(cfg.browserHeight)", value: $cfg.browserHeight, in: 180...2160, step: 10)
            }
            Stepper(Lf("프레임레이트: %@ fps", "\(cfg.captureFPS)"), value: $cfg.captureFPS, in: 5...60, step: 5)
            Toggle(L("투명 배경 (body 배경색을 지정하지 않은 페이지)"), isOn: $cfg.browserTransparent)
            Picker(L("엔진"), selection: $cfg.browserUseWebKit) {
                Text(L("Chromium (내장, 권장)")).tag(false)
                Text("Safari / WebKit").tag(true)
            }
            Text(mc_web_available() != 0
                 ? L("Chromium: 권한 없이 60fps, 소리는 오디오 믹서로. 단 H.264/AAC 영상(일부 사이트)은 재생되지 않으니 그런 페이지는 Safari/WebKit을 고르세요 (화면 기록 권한 필요).")
                 : L("이 빌드에는 내장 Chromium이 없어 Safari/WebKit으로 표시됩니다."))
                .font(.caption).foregroundColor(.secondary)
            Text(L("출력보다 작게 지정하면 가운데에 그 크기로 표시됩니다. 위치는 입력 설정 → Position에서 옮깁니다. 페이지는 Preview/Output 화면에서 바로 클릭·스크롤·입력해서 조작합니다 (Esc로 해제)."))
                .font(.caption).foregroundColor(.secondary)
        }
    }

    // MARK: Audio Input

    @ViewBuilder private var audioSection: some View {
        Section("Audio Input") {
            ForEach(CameraInput.audioDevices(), id: \.uniqueID) { d in
                sourceRow(d.localizedName, selected: cfg.audioDeviceID == d.uniqueID) {
                    cfg.audioDeviceID = d.uniqueID
                    if !nameEdited { cfg.name = d.localizedName }
                }
            }
            Picker("Channels", selection: $cfg.audioFX.channelMode) {
                Text("Stereo (1+2)").tag(0)
                Text("Mono (1)").tag(1)
                Text("Mono (2)").tag(2)
            }
            Text(L("마이크, USB 오디오 인터페이스, Dante/AVB 가상 사운드카드 등 macOS에 보이는 장치."))
                .font(.caption).foregroundColor(.secondary)
        }
    }

    // MARK: Logic

    private var isValid: Bool {
        guard category.available else { return false }
        switch kind {
        case .media: return !cfg.url.isEmpty
        case .stream:
            if streamType.needsURL { return !pullURL.isEmpty }
            if streamType.needsHost { return !host.isEmpty }
            return true
        case .ndi: return !cfg.ndiSource.isEmpty
        case .image: return !cfg.imagePath.isEmpty
        case .browser: return cfg.browserURL.count > 8
        default: return true
        }
    }

    private func prepare() {
        if editing != nil {
            switch cfg.kind {
            case .camera: cameraSelection = "av:" + cfg.cameraID
            case .decklink: cameraSelection = "dl:\(cfg.deckLinkIndex)"
            case .stream: parseStreamURL(cfg.url)
            default: break
            }
        }
        prepareCategory()
    }

    private func prepareCategory() {
        switch category {
        case .ndiDesktop:
            if ndiMode == 0 { refreshNDI() } else {
                CaptureTargets.load { t, err in
                    targets = t
                    targetsError = err
                }
            }
        case .camera:
            var buf = [CChar](repeating: 0, count: 4096)
            _ = mc_decklink_list(&buf, Int32(buf.count))
            deckLinkDevices = String(cString: buf).split(separator: "\n").map(String.init)
            if cameraSelection.isEmpty, let first = CameraInput.videoDevices().first {
                cameraSelection = "av:" + first.uniqueID
                cfg.cameraID = first.uniqueID
                if !nameEdited { cfg.name = first.localizedName }
            }
        case .title:
            if cfg.title == nil { cfg.title = TitleDocument(template: .lowerThird) }
        default:
            break
        }
    }

    private func refreshNDI() {
        ndiSearching = true
        DispatchQueue.global(qos: .userInitiated).async {
            var buf = [CChar](repeating: 0, count: 16384)
            _ = mc_ndi_list_sources(&buf, Int32(buf.count), 1500)
            let list = String(cString: buf).split(separator: "\n").map(String.init)
            DispatchQueue.main.async {
                ndiSources = list
                ndiSearching = false
            }
        }
    }

    private func parseStreamURL(_ url: String) {
        guard !url.isEmpty, let comps = URLComponents(string: url.replacingOccurrences(of: "#tcp", with: "")
            .replacingOccurrences(of: "#udp", with: "")) else { return }
        let q = Dictionary((comps.queryItems ?? []).map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { a, _ in a })
        port = comps.port ?? port
        host = comps.host ?? ""
        switch comps.scheme ?? "" {
        case "srt":
            latency = (Int(q["latency"] ?? "") ?? 200_000) / 1000
            passphrase = q["passphrase"] ?? ""
            streamID = q["streamid"] ?? ""
            switch q["mode"] {
            case "listener": streamType = .srtListener
            case "rendezvous": streamType = .srtRendezvous
            default: streamType = .srtCaller
            }
        case "rtmp" where q["listen"] == "1":
            streamType = .rtmpServer
            rtmpPath = String(comps.path.dropFirst())
        case "rtsp":
            streamType = url.hasSuffix("#tcp") ? .rtspTCP : .rtspUDP
            pullURL = url.replacingOccurrences(of: "#tcp", with: "").replacingOccurrences(of: "#udp", with: "")
        case "udp":
            streamType = .tsUDP
        case "tcp":
            streamType = q["listen"] == "1" ? .tsTCP : .tsTCPPull
        default:
            streamType = .pull
            pullURL = url
        }
    }

    private func buildStreamURL() -> String {
        func enc(_ s: String) -> String { s.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? s }
        func srt(_ mode: String, _ h: String) -> String {
            var u = "srt://\(h):\(port)?mode=\(mode)&latency=\(latency * 1000)"
            if !passphrase.isEmpty { u += "&passphrase=\(enc(passphrase))" }
            if !streamID.isEmpty { u += "&streamid=\(enc(streamID))" }
            return u
        }
        switch streamType {
        case .srtCaller: return srt("caller", host)
        case .srtListener: return srt("listener", "0.0.0.0")
        case .srtRendezvous: return srt("rendezvous", host)
        case .rtmpServer: return "rtmp://0.0.0.0:\(port)/\(rtmpPath)?listen=1"
        case .pull: return pullURL
        case .rtspUDP: return pullURL + "#udp"
        case .rtspTCP: return pullURL + "#tcp"
        case .tsUDP: return "udp://0.0.0.0:\(port)"
        case .tsTCP: return "tcp://0.0.0.0:\(port)?listen=1"
        case .tsTCPPull: return "tcp://\(host):\(port)"
        }
    }

    private func commit() {
        var c = cfg
        c.kind = kind
        switch kind {
        case .stream: c.url = buildStreamURL()
        case .media: c.lowLatency = false
        case .title: if c.title == nil { c.title = TitleDocument(template: .lowerThird) }
        case .audio: c.audioFollowsVideo = false
        default: break
        }
        if let e = editing {
            engine.replaceInput(e, with: c)
        } else {
            engine.addInput(c)
        }
        dismiss()
    }

    private func pickFiles(types: [UTType]) -> [String] {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = types
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        return panel.runModal() == .OK ? panel.urls.map { $0.path } : []
    }

    private func pickFile(types: [UTType]) -> String? {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = types
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        return panel.runModal() == .OK ? panel.url?.path : nil
    }
}
