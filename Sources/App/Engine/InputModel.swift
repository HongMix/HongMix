import Foundation
import CoreVideo

enum InputKind: String, Codable, CaseIterable {
    case camera, media, stream, ndi, decklink, color, image, title, screen, browser, audio

    var label: String {
        switch self {
        case .camera: return L("카메라/캡처")
        case .media: return L("미디어 파일")
        case .stream: return L("스트림 (SRT/RTMP/URL)")
        case .ndi: return "NDI"
        case .decklink: return "DeckLink"
        case .color: return L("컬러/컬러바")
        case .image: return L("이미지")
        case .title: return L("타이틀 (GT)")
        case .screen: return L("화면/창 캡처")
        case .browser: return L("웹 브라우저")
        case .audio: return L("오디오 입력")
        }
    }

    var symbol: String {
        switch self {
        case .camera: return "video"
        case .media: return "film"
        case .stream: return "antenna.radiowaves.left.and.right"
        case .ndi: return "network"
        case .decklink: return "cable.connector"
        case .color: return "paintpalette"
        case .image: return "photo"
        case .title: return "textformat"
        case .screen: return "rectangle.on.rectangle"
        case .browser: return "globe"
        case .audio: return "mic"
        }
    }
}

extension KeyedDecodingContainer {
    /// Decodes a value if present (and valid), otherwise returns the default.
    func value<T: Decodable>(_ key: Key, _ fallback: T) -> T {
        ((try? decodeIfPresent(T.self, forKey: key)) ?? nil) ?? fallback
    }
}

/// Per-input picture settings: position, crop, opacity, colour correction.
struct VideoAdjust: Codable, Equatable {
    /// Nothing that changes where/how the picture sits in the frame (Preview can show the raw input).
    var isIdentityPlacement: Bool {
        zoom == 1 && panX == 0 && panY == 0 && cropL == 0 && cropT == 0 && cropR == 0 && cropB == 0 && alpha >= 1
            && !mirror && !keyOn
    }

    var zoom: Float = 1
    var panX: Float = 0
    var panY: Float = 0
    var cropL: Float = 0
    var cropT: Float = 0
    var cropR: Float = 0
    var cropB: Float = 0
    var alpha: Float = 1
    var mirror = false
    var deinterlace = false
    var sharpen = false
    var gainR: Float = 1
    var gainG: Float = 1
    var gainB: Float = 1
    var gammaR: Float = 1
    var gammaG: Float = 1
    var gammaB: Float = 1
    var liftR: Float = 0
    var liftG: Float = 0
    var liftB: Float = 0
    var saturation: Float = 1
    var hue: Float = 0
    // colour key / chroma key
    var keyOn = false
    var keyColor: String = "#00B140"
    var keyTolerance: Float = 0.12
    var keySoftness: Float = 0.08
    var keySpill: Float = 0.5

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = VideoAdjust()
        zoom = c.value(.zoom, d.zoom)
        panX = c.value(.panX, d.panX)
        panY = c.value(.panY, d.panY)
        cropL = c.value(.cropL, d.cropL)
        cropT = c.value(.cropT, d.cropT)
        cropR = c.value(.cropR, d.cropR)
        cropB = c.value(.cropB, d.cropB)
        alpha = c.value(.alpha, d.alpha)
        mirror = c.value(.mirror, d.mirror)
        deinterlace = c.value(.deinterlace, d.deinterlace)
        sharpen = c.value(.sharpen, d.sharpen)
        gainR = c.value(.gainR, d.gainR)
        gainG = c.value(.gainG, d.gainG)
        gainB = c.value(.gainB, d.gainB)
        gammaR = c.value(.gammaR, d.gammaR)
        gammaG = c.value(.gammaG, d.gammaG)
        gammaB = c.value(.gammaB, d.gammaB)
        liftR = c.value(.liftR, d.liftR)
        liftG = c.value(.liftG, d.liftG)
        liftB = c.value(.liftB, d.liftB)
        saturation = c.value(.saturation, d.saturation)
        hue = c.value(.hue, d.hue)
        keyOn = c.value(.keyOn, d.keyOn)
        keyColor = c.value(.keyColor, d.keyColor)
        keyTolerance = c.value(.keyTolerance, d.keyTolerance)
        keySoftness = c.value(.keySoftness, d.keySoftness)
        keySpill = c.value(.keySpill, d.keySpill)
    }

    var hasColorCorrection: Bool {
        gainR != 1 || gainG != 1 || gainB != 1 || gammaR != 1 || gammaG != 1 || gammaB != 1 ||
            liftR != 0 || liftG != 0 || liftB != 0 || saturation != 1 || hue != 0
    }

    mutating func resetColor() {
        let d = VideoAdjust()
        gainR = d.gainR; gainG = d.gainG; gainB = d.gainB
        gammaR = d.gammaR; gammaG = d.gammaG; gammaB = d.gammaB
        liftR = d.liftR; liftG = d.liftG; liftB = d.liftB
        saturation = d.saturation; hue = d.hue
    }

    func layerParams(premultiplied: Bool, mixAlpha: Float = 1) -> LayerParams {
        var p = LayerParams()
        p.premul = premultiplied ? 1 : 0
        p.mirror = mirror ? 1 : 0
        p.deinterlace = deinterlace ? 1 : 0
        p.sharpen = sharpen ? 1 : 0
        p.hasCC = hasColorCorrection ? 1 : 0
        p.zoom = zoom
        p.panX = panX
        p.panY = panY
        p.cropL = cropL
        p.cropT = cropT
        p.cropR = cropR
        p.cropB = cropB
        p.alpha = alpha
        p.mixAlpha = mixAlpha
        p.gainR = gainR; p.gainG = gainG; p.gainB = gainB
        p.gammaR = gammaR; p.gammaG = gammaG; p.gammaB = gammaB
        p.liftR = liftR; p.liftG = liftG; p.liftB = liftB
        p.saturation = saturation
        p.hue = hue
        if keyOn, let k = HexColor.parse(keyColor) {
            p.keyOn = 1
            p.keyR = Float(k.0)
            p.keyG = Float(k.1)
            p.keyB = Float(k.2)
            p.keyTol = keyTolerance
            p.keySoft = keySoftness
            p.keySpill = keySpill
        }
        return p
    }
}

/// Per-input audio processing (the input's Audio Settings window).
struct AudioFX: Codable, Equatable {
    var channelMode: Int = 0          // 0 stereo, 1 mono (left), 2 mono (right), 3 separate mono (L/R swapped)
    var delayMs: Int = 0
    var eqOn = false
    var eqLow: Float = 0              // dB, low shelf 100 Hz
    var eqMid: Float = 0              // dB, peak 1 kHz
    var eqHigh: Float = 0             // dB, high shelf 8 kHz
    var compOn = false
    var compThreshold: Float = -18    // dBFS
    var compRatio: Float = 4
    var gateOn = false
    var gateThreshold: Float = -50    // dBFS
    var visibleInMixer = true
    /// Auto ducking: this input's voice lowers the 'ducked' inputs (e.g. presenter mic)
    var duckTrigger = false
    /// Auto ducking: this input is lowered while a trigger input speaks (e.g. music, VT)
    var ducked = false

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = AudioFX()
        channelMode = c.value(.channelMode, d.channelMode)
        delayMs = c.value(.delayMs, d.delayMs)
        eqOn = c.value(.eqOn, d.eqOn)
        eqLow = c.value(.eqLow, d.eqLow)
        eqMid = c.value(.eqMid, d.eqMid)
        eqHigh = c.value(.eqHigh, d.eqHigh)
        compOn = c.value(.compOn, d.compOn)
        compThreshold = c.value(.compThreshold, d.compThreshold)
        compRatio = c.value(.compRatio, d.compRatio)
        gateOn = c.value(.gateOn, d.gateOn)
        gateThreshold = c.value(.gateThreshold, d.gateThreshold)
        visibleInMixer = c.value(.visibleInMixer, d.visibleInMixer)
        duckTrigger = c.value(.duckTrigger, d.duckTrigger)
        ducked = c.value(.ducked, d.ducked)
    }
}

/// One vMix-style layer of an input: another input placed in a rectangle (normalised 0…1, top-left).
struct InputLayer: Codable, Equatable, Identifiable {
    var id = UUID()
    var inputID: UUID? = nil
    var visible = true
    var x: Double = 0, y: Double = 0, w: Double = 0.5, h: Double = 0.5
    var fill = true                 // true: crop to fill the box; false: fit inside (letterbox)
    var cropL: Float = 0, cropT: Float = 0, cropR: Float = 0, cropB: Float = 0
    var border: Double = 0          // px at output size
    var borderColor: String = "#FFFFFF"

    init(inputID: UUID? = nil, x: Double, y: Double, w: Double, h: Double, fill: Bool = true) {
        self.inputID = inputID; self.x = x; self.y = y; self.w = w; self.h = h; self.fill = fill
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = c.value(.id, UUID())
        inputID = c.value(.inputID, UUID?.none)
        visible = c.value(.visible, true)
        x = c.value(.x, 0); y = c.value(.y, 0); w = c.value(.w, 0.5); h = c.value(.h, 0.5)
        fill = c.value(.fill, true)
        cropL = c.value(.cropL, Float(0)); cropT = c.value(.cropT, Float(0))
        cropR = c.value(.cropR, Float(0)); cropB = c.value(.cropB, Float(0))
        border = c.value(.border, 0)
        borderColor = c.value(.borderColor, "#FFFFFF")
    }
}

/// Ready-made layer layouts (vMix MultiView templates: split screens, PIP …).
enum LayerLayout: String, CaseIterable, Identifiable {
    case split2, split2Fit, split3, quad, nine, sixteen, onePlus3, onePlus5, pipBR, pipBL, pipTR, twoPip
    var id: String { rawValue }
    var label: String {
        switch self {
        case .split2: return L("2분할 좌우 (꽉 채우기)")
        case .split2Fit: return L("2분할 좌우 (16:9 그대로)")
        case .split3: return L("3분할 세로")
        case .quad: return L("4분할 (2×2)")
        case .nine: return L("9분할 (3×3)")
        case .sixteen: return L("16분할 (4×4)")
        case .onePlus3: return L("1 + 3 (큰 화면 + 오른쪽 3개)")
        case .onePlus5: return L("1 + 5 (큰 화면 + L자 5개)")
        case .pipBR: return L("PIP 오른쪽 아래")
        case .pipBL: return L("PIP 왼쪽 아래")
        case .pipTR: return L("PIP 오른쪽 위")
        case .twoPip: return L("PIP 2개 (아래 좌우)")
        }
    }

    /// Rectangles with `gap` (fraction of width) between cells and around the edge.
    func rects(gap g: Double) -> [(Double, Double, Double, Double, Bool)] {
        func grid(_ n: Int) -> [(Double, Double, Double, Double, Bool)] {
            let gy = g * 16 / 9
            let cw = (1 - g * Double(n + 1)) / Double(n), ch = (1 - gy * Double(n + 1)) / Double(n)
            var r: [(Double, Double, Double, Double, Bool)] = []
            for row in 0..<n { for col in 0..<n {
                r.append((g + Double(col) * (cw + g), gy + Double(row) * (ch + gy), cw, ch, true))
            } }
            return r
        }
        let gy = g * 16 / 9
        switch self {
        case .split2:
            let w = (1 - 3 * g) / 2
            return [(g, gy, w, 1 - 2 * gy, true), (2 * g + w, gy, w, 1 - 2 * gy, true)]
        case .split2Fit:
            let w = (1 - 3 * g) / 2, h = w * 1 // same aspect as the frame: h fraction = w fraction
            let y = (1 - h) / 2
            return [(g, y, w, h, true), (2 * g + w, y, w, h, true)]
        case .split3:
            let w = (1 - 4 * g) / 3
            return (0..<3).map { (g + Double($0) * (w + g), gy, w, 1 - 2 * gy, true) }
        case .quad: return grid(2)
        case .nine: return grid(3)
        case .sixteen: return grid(4)
        case .onePlus3:
            let small = (1 - 4 * gy) / 3                     // height of each right cell
            let sw = small                                    // 16:9 cells: width fraction == height fraction
            let bw = 1 - 3 * g - sw
            var r: [(Double, Double, Double, Double, Bool)] = [(g, gy, bw, 1 - 2 * gy, true)]
            for k in 0..<3 { r.append((2 * g + bw, gy + Double(k) * (small + gy), sw, small, true)) }
            return r
        case .onePlus5:
            let c = (1 - 4 * g) / 3, ch = (1 - 4 * gy) / 3
            var r: [(Double, Double, Double, Double, Bool)] = [(g, gy, 2 * c + g, 2 * ch + gy, true)]
            r.append((3 * g + 2 * c, gy, c, ch, true))
            r.append((3 * g + 2 * c, 2 * gy + ch, c, ch, true))
            for k in 0..<3 { r.append((g + Double(k) * (c + g), 3 * gy + 2 * ch, c, ch, true)) }
            return r
        case .pipBR: return [(0.66, 0.66, 0.3, 0.3, true)]
        case .pipBL: return [(0.04, 0.66, 0.3, 0.3, true)]
        case .pipTR: return [(0.66, 0.04, 0.3, 0.3, true)]
        case .twoPip: return [(0.04, 0.62, 0.32, 0.32, true), (0.64, 0.62, 0.32, 0.32, true)]
        }
    }
}

/// Everything needed to recreate an input (saved in project files).
struct InputConfig: Codable, Identifiable, Equatable {
    var id = UUID()
    var kind: InputKind
    var name: String
    // media / stream
    var url: String = ""
    var loop: Bool = true
    var lowLatency: Bool = true
    var hardwareDecode: Bool = true
    var autoPlay: Bool = true
    var autoPause: Bool = false
    var autoRestart: Bool = false
    var markIn: Double = -1
    var markOut: Double = -1
    var rate: Double = 1
    // ndi
    var ndiSource: String = ""
    var ndiLowBandwidth: Bool = false
    // decklink
    var deckLinkIndex: Int = 0
    // camera
    var cameraID: String = ""
    var audioDeviceID: String = ""
    /// Capture format (vMix "Format"): "" = automatic (match the program), else "1920x1080@29.97"
    var cameraFormat: String = ""
    // color
    var color: String = "bars"   // "bars", "black", "white", or "#RRGGBB"
    // image
    var imagePath: String = ""
    // title
    var title: TitleDocument? = nil
    // screen / window capture (ScreenCaptureKit)
    var screenDisplayID: UInt32 = 0     // 0 = main display
    var screenWindowID: UInt32 = 0      // 0 = whole display
    var showCursor: Bool = true
    var captureFPS: Int = 30
    // web browser
    var browserURL: String = "https://"
    var browserWidth: Int = 1920
    var browserHeight: Int = 1080
    var browserTransparent: Bool = true
    /// false = embedded Chromium (default, like vMix); true = Safari/WebKit (plays H.264/AAC pages,
    /// but needs Screen Recording permission for smooth frames)
    var browserUseWebKit: Bool = false
    // picture
    var adjust = VideoAdjust()
    // audio
    var volume: Float = 0.8
    var muted: Bool = false
    var audioFollowsVideo: Bool = true
    var buses: String = "M"          // any of "MABCDEFG"
    var gainDB: Float = 0
    var balance: Float = 0
    var channel1: Float = 1
    var channel2: Float = 1
    var audioFX = AudioFX()
    // recording
    var multiCorder: Bool = false
    /// vMix: right-click an input's title to collapse it (title bar only)
    var collapsed: Bool = false
    /// Signal loss (live inputs): 0 keep last frame, 1 black, 2 colour bars "NO SIGNAL"
    var lossMode: Int = 2
    var backupInputID: UUID? = nil      // failover: cut to this input when this one is live and loses signal
    var autoReturn: Bool = true         // cut back when the signal returns
    var lossAlert: Bool = true          // sound + red banner
    /// vMix Layers / MultiView: up to 10 inputs drawn on top of this one (split screens, PIP, backgrounds)
    var layers: [InputLayer] = []
    /// vMix input category (colour tab): 0 none, 1…6 red, green, orange, purple, aqua, blue
    var category: Int = 0
    /// vMix Triggers: run functions when this input goes on air, comes off, finishes …
    var triggers: [InputTrigger] = []
    /// List input: files played one after another (empty = single file in `url`)
    var playlist: [String] = []
    var playlistIndex: Int = 0
    /// 3D LUT (.cube) applied to this input's picture
    var lutPath: String = ""
    var lutStrength: Float = 1

    init(kind: InputKind, name: String) {
        self.kind = kind
        self.name = name
        collapsed = kind == .audio          // audio-only inputs start collapsed (no empty picture box)
    }

    private enum LegacyKeys: String, CodingKey { case busMaster }

    // Tolerant decoding: project files from older versions may miss newer keys.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let k = try c.decode(InputKind.self, forKey: .kind)
        let d = InputConfig(kind: k, name: k.label)
        kind = k
        id = c.value(.id, UUID())
        name = c.value(.name, d.name)
        url = c.value(.url, d.url)
        loop = c.value(.loop, d.loop)
        lowLatency = c.value(.lowLatency, d.lowLatency)
        hardwareDecode = c.value(.hardwareDecode, d.hardwareDecode)
        audioFX = c.value(.audioFX, d.audioFX)
        autoPlay = c.value(.autoPlay, d.autoPlay)
        autoPause = c.value(.autoPause, d.autoPause)
        autoRestart = c.value(.autoRestart, d.autoRestart)
        markIn = c.value(.markIn, d.markIn)
        markOut = c.value(.markOut, d.markOut)
        rate = c.value(.rate, d.rate)
        ndiSource = c.value(.ndiSource, d.ndiSource)
        ndiLowBandwidth = c.value(.ndiLowBandwidth, d.ndiLowBandwidth)
        deckLinkIndex = c.value(.deckLinkIndex, d.deckLinkIndex)
        cameraID = c.value(.cameraID, d.cameraID)
        audioDeviceID = c.value(.audioDeviceID, d.audioDeviceID)
        cameraFormat = c.value(.cameraFormat, d.cameraFormat)
        color = c.value(.color, d.color)
        imagePath = c.value(.imagePath, d.imagePath)
        title = c.value(.title, d.title)
        screenDisplayID = c.value(.screenDisplayID, d.screenDisplayID)
        screenWindowID = c.value(.screenWindowID, d.screenWindowID)
        showCursor = c.value(.showCursor, d.showCursor)
        captureFPS = c.value(.captureFPS, d.captureFPS)
        browserURL = c.value(.browserURL, d.browserURL)
        browserWidth = c.value(.browserWidth, d.browserWidth)
        browserHeight = c.value(.browserHeight, d.browserHeight)
        browserTransparent = c.value(.browserTransparent, d.browserTransparent)
        browserUseWebKit = c.value(.browserUseWebKit, d.browserUseWebKit)
        adjust = c.value(.adjust, d.adjust)
        volume = c.value(.volume, d.volume)
        muted = c.value(.muted, d.muted)
        audioFollowsVideo = c.value(.audioFollowsVideo, d.audioFollowsVideo)
        gainDB = c.value(.gainDB, d.gainDB)
        balance = c.value(.balance, d.balance)
        channel1 = c.value(.channel1, d.channel1)
        channel2 = c.value(.channel2, d.channel2)
        multiCorder = c.value(.multiCorder, d.multiCorder)
        collapsed = c.value(.collapsed, d.collapsed)
        lossMode = c.value(.lossMode, d.lossMode)
        backupInputID = c.value(.backupInputID, d.backupInputID)
        autoReturn = c.value(.autoReturn, d.autoReturn)
        lossAlert = c.value(.lossAlert, d.lossAlert)
        layers = c.value(.layers, d.layers)
        category = c.value(.category, d.category)
        triggers = c.value(.triggers, d.triggers)
        playlist = c.value(.playlist, d.playlist)
        playlistIndex = c.value(.playlistIndex, d.playlistIndex)
        lutPath = c.value(.lutPath, d.lutPath)
        lutStrength = c.value(.lutStrength, d.lutStrength)
        if let b: String = try? c.decodeIfPresent(String.self, forKey: .buses) {
            buses = b
        } else {
            let legacy = try? decoder.container(keyedBy: LegacyKeys.self)
            let master = legacy.map { $0.value(.busMaster, true) } ?? true
            buses = master ? "M" : ""
        }
    }
}

enum AudioBus {
    static let all = ["M", "A", "B", "C", "D", "E", "F", "G"]
    static let aux = ["A", "B", "C", "D", "E", "F", "G"]

    static func index(_ name: String) -> Int? { all.firstIndex(of: name.uppercased()) }

    static func mask(_ buses: String) -> UInt8 {
        var m: UInt8 = 0
        for ch in buses.uppercased() {
            if let i = all.firstIndex(of: String(ch)) { m |= UInt8(1 << i) }
        }
        return m
    }

    static func letters(_ buses: String) -> String {
        all.filter { buses.uppercased().contains($0) }.joined()
    }
}

/// Audio parameters read by the render thread.
struct AudioParams {
    var gain: Float = 0.64            // fader (volume²)
    var trim: Float = 1               // input gain (linear)
    var leftGain: Float = 1           // balance × channel volume
    var rightGain: Float = 1
    var muted = false
    var followsVideo = true
    var busMask: UInt8 = 1            // bit 0 = Master, 1 = A … 7 = G
    var solo = false
    var fx = AudioFX()
}

/// Base class for all inputs.
class InputSource: ObservableObject, Identifiable {
    let id: UUID
    let kind: InputKind
    @Published var name: String
    @Published var status: String = ""
    @Published var state: Int32 = Int32(MC_STATE_IDLE)

    // audio
    @Published var volume: Float { didSet { syncAudioParams() } }
    @Published var muted: Bool { didSet { syncAudioParams() } }
    @Published var audioFollowsVideo: Bool { didSet { syncAudioParams() } }
    @Published var buses: String { didSet { syncAudioParams() } }
    @Published var gainDB: Float { didSet { syncAudioParams() } }
    @Published var balance: Float { didSet { syncAudioParams() } }
    @Published var channel1: Float { didSet { syncAudioParams() } }
    @Published var channel2: Float { didSet { syncAudioParams() } }
    @Published var solo: Bool = false { didSet { syncAudioParams() } }
    @Published var audioFX: AudioFX { didSet { syncAudioParams() } }

    // media transport
    @Published var playing: Bool = true { didSet { applyTransport() } }
    @Published var looping: Bool { didSet { applyTransport() } }
    @Published var markIn: Double { didSet { applyTransport() } }
    @Published var markOut: Double { didSet { applyTransport() } }
    @Published var rate: Double { didSet { applyTransport() } }
    @Published var autoPlay: Bool
    @Published var autoPause: Bool
    @Published var autoRestart: Bool
    @Published var position: Double = 0     // seconds
    @Published var duration: Double = 0     // seconds (0 = live)

    // picture / recording
    @Published var adjust: VideoAdjust { didSet { syncVideoParams() } }
    @Published var multiCorder: Bool
    @Published var collapsed: Bool = false
    @Published var lossMode: Int = 2 { didSet { applyLossSubstitute() } }
    @Published var backupInputID: UUID?
    @Published var autoReturn = true
    @Published var lossAlert = true
    @Published var category: Int = 0
    @Published var triggers: [InputTrigger] = []
    /// 3D LUT (.cube) — snapshot read by the render thread
    @Published var lutPath: String = "" { didSet { syncLUT(); if !lutPath.isEmpty { LUTCache.shared.preload(lutPath) } } }
    @Published var lutStrength: Float = 1 { didSet { syncLUT() } }
    private var lutStore: (String, Float) = ("", 1)
    var lutSnapshot: (path: String, strength: Float) {
        paramsLock.lock(); defer { paramsLock.unlock() }
        return lutStore
    }
    private func syncLUT() { paramsLock.lock(); lutStore = (lutPath, lutStrength); paramsLock.unlock() }
    /// Render thread: last LUT result, reused while the source frame doesn't change.
    var lutCacheSrc: CVPixelBuffer?
    var lutCacheOut: CVPixelBuffer?
    var lutCacheKey = ""
    /// Engine hook for trigger events (main thread).
    static var eventSink: ((InputSource, TriggerEvent) -> Void)?
    func emit(_ e: TriggerEvent) {
        if Thread.isMainThread { InputSource.eventSink?(self, e) }
        else { DispatchQueue.main.async { InputSource.eventSink?(self, e) } }
    }
    /// Layers (MultiView) — edited on the main thread, read by the render thread via `layersSnapshot`.
    @Published var layers: [InputLayer] = [] { didSet { paramsLock.lock(); layersStore = layers; paramsLock.unlock() } }
    private var layersStore: [InputLayer] = []
    var layersSnapshot: [InputLayer] {
        paramsLock.lock(); defer { paramsLock.unlock() }
        return layersStore
    }
    /// Render thread: this input with its layers composed (nil when it has none).
    private var composedStore: CVPixelBuffer?
    var composed: CVPixelBuffer? {
        get { paramsLock.lock(); defer { paramsLock.unlock() }; return composedStore }
        set { paramsLock.lock(); composedStore = newValue; paramsLock.unlock() }
    }
    /// What this input looks like: composed with its layers if it has any, else its own frame.
    func currentFrame() -> CVPixelBuffer? { composed ?? video.latest() }
    /// Live input stopped delivering frames (or errored) after having had signal.
    @Published private(set) var signalLost = false
    private(set) var lostSince: Date?
    private(set) var hadSignal = false
    private var goodSince: CFTimeInterval = 0

    /// Inputs that carry a live signal (files, titles, colours, images never "lose signal").
    var isLiveSource: Bool { [.stream, .ndi, .camera, .decklink, .screen].contains(kind) }

    /// Called ~20×/s on the main thread. Returns +1 when the signal was just lost, -1 when it just returned.
    func checkSignal(now: CFTimeInterval) -> Int {
        guard isLiveSource else { return 0 }
        let age = video.age
        let errored = state == Int32(MC_STATE_ERROR)
        let ok = age < 0.8 && !errored
        if ok {
            if !hadSignal { hadSignal = true }
            if signalLost {
                if goodSince == 0 { goodSince = now }
                if now - goodSince > 2.0 {          // stable again for 2 s (jitter buffer settled)
                    signalLost = false
                    lostSince = nil
                    goodSince = 0
                    applyLossSubstitute()
                    return -1
                }
            }
            return 0
        }
        goodSince = 0
        if hadSignal && !signalLost && (age > 1.0 || errored) {
            signalLost = true
            lostSince = Date()
            applyLossSubstitute()
            return 1
        }
        return 0
    }

    func applyLossSubstitute() {
        video.substitute = signalLost ? (lossMode == 1 ? Slates.black : (lossMode == 2 ? Slates.noSignal : nil)) : nil
    }

    let video = VideoSlot()
    let audio = AudioRing()
    var config: InputConfig

    private let paramsLock = NSLock()
    private var audioParamsStore = AudioParams()
    private var adjustStore = VideoAdjust()

    // Render-thread-only mixer state.
    var mixPrimed = false
    var mixLastGains = [Float](repeating: 0, count: 8)
    let dsp = InputDSPState()

    /// Overlay sources with straight alpha (NDI) vs premultiplied (images/titles drawn by CoreGraphics).
    var alphaPremultiplied: Bool { false }
    var supportsTransport: Bool { false }

    init(config: InputConfig) {
        self.id = config.id
        self.kind = config.kind
        self.name = config.name
        self.volume = config.volume
        self.muted = config.muted
        self.audioFollowsVideo = config.audioFollowsVideo
        self.buses = config.buses
        self.gainDB = config.gainDB
        self.balance = config.balance
        self.channel1 = config.channel1
        self.channel2 = config.channel2
        self.audioFX = config.audioFX
        self.looping = config.loop
        self.markIn = config.markIn
        self.markOut = config.markOut
        self.rate = config.rate
        self.autoPlay = config.autoPlay
        self.autoPause = config.autoPause
        self.autoRestart = config.autoRestart
        self.adjust = config.adjust
        self.multiCorder = config.multiCorder
        self.collapsed = config.collapsed
        self.lossMode = config.lossMode
        self.backupInputID = config.backupInputID
        self.autoReturn = config.autoReturn
        self.lossAlert = config.lossAlert
        self.layers = config.layers
        self.category = config.category
        self.triggers = config.triggers
        self.lutPath = config.lutPath
        self.lutStrength = config.lutStrength
        self.config = config
        layersStore = config.layers          // didSet doesn't run in init
        lutStore = (config.lutPath, config.lutStrength)
        if !config.lutPath.isEmpty { LUTCache.shared.preload(config.lutPath) }
        syncAudioParams()
        syncVideoParams()
        // rendered on demand → reported at the program rate (vMix shows these at the output frame rate)
        video.followsProgramRate = [.color, .image, .title, .browser].contains(config.kind)
    }

    var busMaster: Bool {
        get { buses.uppercased().contains("M") }
        set { setBus("M", newValue) }
    }

    func onBus(_ bus: String) -> Bool { buses.uppercased().contains(bus.uppercased()) }

    func setBus(_ bus: String, _ on: Bool) {
        var set = Set(buses.uppercased().map { String($0) })
        if on { set.insert(bus.uppercased()) } else { set.remove(bus.uppercased()) }
        buses = AudioBus.letters(set.joined())
    }

    var audioParams: AudioParams {
        paramsLock.lock()
        defer { paramsLock.unlock() }
        return audioParamsStore
    }

    var videoAdjust: VideoAdjust {
        paramsLock.lock()
        defer { paramsLock.unlock() }
        return adjustStore
    }

    private func syncAudioParams() {
        let bal = max(-1, min(1, balance))
        let p = AudioParams(gain: volume * volume,
                            trim: powf(10, gainDB / 20),
                            leftGain: channel1 * (bal > 0 ? 1 - bal : 1),
                            rightGain: channel2 * (bal < 0 ? 1 + bal : 1),
                            muted: muted,
                            followsVideo: audioFollowsVideo,
                            busMask: AudioBus.mask(buses),
                            solo: solo,
                            fx: audioFX)
        paramsLock.lock()
        audioParamsStore = p
        paramsLock.unlock()
    }

    private func syncVideoParams() {
        paramsLock.lock()
        adjustStore = adjust
        paramsLock.unlock()
    }

    /// Snapshot for saving.
    func currentConfig() -> InputConfig {
        var c = config
        c.name = name
        c.volume = volume
        c.muted = muted
        c.audioFollowsVideo = audioFollowsVideo
        c.buses = buses
        c.gainDB = gainDB
        c.balance = balance
        c.channel1 = channel1
        c.channel2 = channel2
        c.audioFX = audioFX
        c.loop = looping
        c.markIn = markIn
        c.markOut = markOut
        c.rate = rate
        c.autoPlay = autoPlay
        c.autoPause = autoPause
        c.autoRestart = autoRestart
        c.adjust = adjust
        c.multiCorder = multiCorder
        c.collapsed = collapsed
        c.lossMode = lossMode
        c.backupInputID = backupInputID
        c.autoReturn = autoReturn
        c.lossAlert = lossAlert
        c.layers = layers
        c.category = category
        c.triggers = triggers
        c.lutPath = lutPath
        c.lutStrength = lutStrength
        return c
    }

    // Overridden by subclasses.
    func applyTransport() {}
    func pollPosition() {}
    func start() {}
    func stop() {}
    func restart() {}
    func seek(seconds: Double) {}
    func setTally(program: Bool, preview: Bool) {}
    /// Called when the input goes to Output (program) or an overlay.
    func didGoLive() {}

    func postStatus(_ state: Int32, _ message: String) {
        DispatchQueue.main.async {
            self.state = state
            self.status = message
        }
    }

    static func make(_ config: InputConfig) -> InputSource {
        switch config.kind {
        case .camera: return CameraInput(config: config)
        case .media, .stream: return FFmpegInput(config: config)
        case .ndi: return NDIInput(config: config)
        case .decklink: return DeckLinkInput(config: config)
        case .color: return ColorInput(config: config)
        case .image: return ImageInput(config: config)
        case .title: return TitleInput(config: config)
        case .screen: return ScreenCaptureInput(config: config)
        case .browser: return BrowserInput(config: config)
        case .audio: return AudioDeviceInput(config: config)
        }
    }
}
