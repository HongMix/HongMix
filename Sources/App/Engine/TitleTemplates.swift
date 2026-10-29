import Foundation

/// How a title enters and leaves (TitleBeginAnimation / overlay in-out / going live).
enum TitleAnimation: String, Codable, CaseIterable, Identifiable {
    case fade, slideLeft, slideUp, wipe, pop
    var id: String { rawValue }
    var label: String {
        switch self {
        case .fade: return L("페이드")
        case .slideLeft: return L("왼쪽에서 슬라이드")
        case .slideUp: return L("아래에서 올라오기")
        case .wipe: return L("와이프 (왼→오 드러내기)")
        case .pop: return L("팝 (확대)")
        }
    }
}

/// Built-in title templates (vMix "GT" style graphics without the GT Designer).
/// Field names follow vMix conventions (Headline.Text, Description.Text, …) so SetText works the same.
enum TitleTemplate: String, Codable, CaseIterable, Identifiable {
    // lower thirds
    case lowerThird, ltModern, ltMinimal, ltGradient, ltRight, nameStrap, ltTwoLine
    // poker
    case playerCard, potDisplay, blindsBug, playerVs
    // full screen
    case fullText, titleCard, startingSoon, brb, quote
    // corner bugs
    case liveBug, social, logo
    // time / data
    case countdown, clock, scoreboard
    // tickers
    case ticker, breakingTicker
    // live
    case liveCaptions

    var id: String { rawValue }

    enum Category: String, CaseIterable, Identifiable {
        case lowerThird = "하단 자막", poker = "포커", full = "전체 화면", bug = "코너 / 로고", time = "시간 · 점수", ticker = "티커"
        var id: String { rawValue }
    }

    var category: Category {
        switch self {
        case .lowerThird, .ltModern, .ltMinimal, .ltGradient, .ltRight, .nameStrap, .ltTwoLine: return .lowerThird
        case .playerCard, .potDisplay, .blindsBug, .playerVs: return .poker
        case .fullText, .titleCard, .startingSoon, .brb, .quote: return .full
        case .liveBug, .social, .logo: return .bug
        case .countdown, .clock, .scoreboard: return .time
        case .ticker, .breakingTicker: return .ticker
        case .liveCaptions: return .time
        }
    }

    var label: String {
        switch self {
        case .lowerThird: return L("기본 하단 자막")
        case .ltModern: return L("모던 (태그 + 바)")
        case .ltMinimal: return L("미니멀 (라인)")
        case .ltGradient: return L("그라데이션 바")
        case .ltRight: return L("오른쪽 하단 자막")
        case .nameStrap: return L("이름 자막 (중앙)")
        case .ltTwoLine: return L("2줄 자막 (이름 + 소속)")
        case .playerCard: return L("플레이어 카드 (칩)")
        case .potDisplay: return L("팟 (POT)")
        case .blindsBug: return L("블라인드 / 레벨")
        case .playerVs: return L("헤즈업 VS")
        case .fullText: return L("전체 화면 텍스트")
        case .titleCard: return L("오프닝 타이틀 카드")
        case .startingSoon: return L("곧 시작합니다 (카운트다운)")
        case .brb: return L("잠시 후 계속됩니다")
        case .quote: return L("인용구")
        case .liveBug: return L("LIVE 표시")
        case .social: return L("소셜 핸들")
        case .logo: return L("로고 / 버그")
        case .countdown: return L("카운트다운")
        case .clock: return L("시계")
        case .scoreboard: return L("스코어보드")
        case .ticker: return L("티커 (흐르는 자막)")
        case .breakingTicker: return L("속보 티커")
        case .liveCaptions: return L("실시간 자막 (음성 인식)")
        }
    }

    var defaultAnimation: TitleAnimation {
        switch self {
        case .lowerThird, .ltModern, .ltRight, .ltTwoLine, .playerCard: return .slideLeft
        case .ltMinimal, .ltGradient: return .wipe
        case .liveBug, .social, .potDisplay: return .pop
        case .nameStrap, .ticker, .breakingTicker, .blindsBug: return .slideUp
        default: return .fade
        }
    }

    func makeFields() -> [TitleField] {
        typealias F = TitleField
        let gold = "#E3B02A", navy = "#0B1F3AD9"
        switch self {
        case .lowerThird:
            return [
                F(id: "Background.Fill", kind: .shape, color: navy, x: 0.06, y: 0.74, w: 0.52, h: 0.16),
                F(id: "Accent.Fill", kind: .shape, color: gold, x: 0.06, y: 0.74, w: 0.008, h: 0.16),
                F(id: "Headline.Text", text: L("이름"), x: 0.085, y: 0.755, w: 0.48, h: 0.075, fontSize: 0.055),
                F(id: "Description.Text", text: L("직함 / 설명"), color: "#D0D8E8", x: 0.085, y: 0.83, w: 0.48,
                  h: 0.055, fontSize: 0.036, bold: false),
            ]
        case .ltModern:
            return [
                F(id: "Tag.Fill", kind: .shape, color: gold, x: 0.06, y: 0.725, w: 0.16, h: 0.05),
                F(id: "Description.Text", text: "GUEST", color: "#111111", x: 0.07, y: 0.727, w: 0.14, h: 0.046,
                  fontSize: 0.03),
                F(id: "Background.Fill", kind: .shape, color: "#111827F0", x: 0.06, y: 0.775, w: 0.46, h: 0.095)
                    .with { $0.color2 = "#1F2937F0" },
                F(id: "Headline.Text", text: L("홍길동"), x: 0.075, y: 0.785, w: 0.43, h: 0.075, fontSize: 0.052),
            ]
        case .ltMinimal:
            return [
                F(id: "Headline.Text", text: L("이름"), x: 0.06, y: 0.765, w: 0.5, h: 0.075, fontSize: 0.055)
                    .with { $0.shadow = true },
                F(id: "Line.Fill", kind: .shape, color: "#FFFFFF", x: 0.06, y: 0.845, w: 0.26, h: 0.004),
                F(id: "Description.Text", text: L("직함 / 설명"), color: "#E5E7EB", x: 0.06, y: 0.855, w: 0.5, h: 0.05,
                  fontSize: 0.032, bold: false).with { $0.shadow = true },
            ]
        case .ltGradient:
            return [
                F(id: "Background.Fill", kind: .shape, color: "#7C3AEDF2", x: 0.06, y: 0.75, w: 0.5, h: 0.14,
                  cornerRadius: 0.018).with { $0.color2 = "#2563EBF2" },
                F(id: "Headline.Text", text: L("이름"), x: 0.085, y: 0.762, w: 0.45, h: 0.07, fontSize: 0.052),
                F(id: "Description.Text", text: L("직함 / 설명"), color: "#E0E7FF", x: 0.085, y: 0.83, w: 0.45,
                  h: 0.05, fontSize: 0.033, bold: false),
            ]
        case .ltRight:
            return [
                F(id: "Background.Fill", kind: .shape, color: navy, x: 0.42, y: 0.74, w: 0.52, h: 0.16),
                F(id: "Accent.Fill", kind: .shape, color: gold, x: 0.932, y: 0.74, w: 0.008, h: 0.16),
                F(id: "Headline.Text", text: L("이름"), x: 0.435, y: 0.755, w: 0.48, h: 0.075, fontSize: 0.055,
                  align: "right"),
                F(id: "Description.Text", text: L("직함 / 설명"), color: "#D0D8E8", x: 0.435, y: 0.83, w: 0.48,
                  h: 0.055, fontSize: 0.036, bold: false, align: "right"),
            ]
        case .nameStrap:
            return [
                F(id: "Background.Fill", kind: .shape, color: "#000000B3", x: 0.25, y: 0.78, w: 0.5, h: 0.13,
                  cornerRadius: 0.01),
                F(id: "Headline.Text", text: "PLAYER NAME", x: 0.26, y: 0.79, w: 0.48, h: 0.065,
                  fontSize: 0.05, align: "center"),
                F(id: "Description.Text", text: "Chip count 1,250,000", color: gold, x: 0.26, y: 0.85,
                  w: 0.48, h: 0.05, fontSize: 0.034, bold: false, align: "center"),
            ]
        case .ltTwoLine:
            return [
                F(id: "Name.Fill", kind: .shape, color: "#FFFFFFF2", x: 0.06, y: 0.74, w: 0.4, h: 0.08),
                F(id: "Headline.Text", text: L("이름"), color: "#111111", x: 0.075, y: 0.745, w: 0.37, h: 0.07,
                  fontSize: 0.05),
                F(id: "Org.Fill", kind: .shape, color: "#C8102EF2", x: 0.06, y: 0.82, w: 0.3, h: 0.055),
                F(id: "Description.Text", text: L("소속 / 팀"), x: 0.075, y: 0.823, w: 0.27, h: 0.05, fontSize: 0.032,
                  bold: false),
            ]
        case .playerCard:
            return [
                F(id: "Background.Fill", kind: .shape, color: "#0A0A0AE8", x: 0.06, y: 0.72, w: 0.4, h: 0.18,
                  cornerRadius: 0.008).with { $0.color2 = "#1A1A1AE8" },
                F(id: "Accent.Fill", kind: .shape, color: "#C8102E", x: 0.06, y: 0.72, w: 0.4, h: 0.006),
                F(id: "Name.Text", text: "PLAYER NAME", x: 0.08, y: 0.738, w: 0.36, h: 0.065, fontSize: 0.05),
                F(id: "Country.Text", text: "KOREA", color: "#9CA3AF", x: 0.08, y: 0.805, w: 0.2, h: 0.04,
                  fontSize: 0.028, bold: false),
                F(id: "ChipsLabel.Text", text: "CHIPS", color: "#9CA3AF", x: 0.26, y: 0.805, w: 0.18, h: 0.04,
                  fontSize: 0.026, bold: false, align: "right"),
                F(id: "Chips.Text", text: "1,250,000", color: gold, x: 0.08, y: 0.845, w: 0.36, h: 0.05,
                  fontSize: 0.042, align: "right"),
            ]
        case .potDisplay:
            return [
                F(id: "Background.Fill", kind: .shape, color: "#000000CC", x: 0.4, y: 0.05, w: 0.2, h: 0.1,
                  cornerRadius: 0.05),
                F(id: "Label.Text", text: "POT", color: "#9CA3AF", x: 0.4, y: 0.058, w: 0.2, h: 0.035,
                  fontSize: 0.026, align: "center"),
                F(id: "Pot.Text", text: "245,000", color: gold, x: 0.4, y: 0.09, w: 0.2, h: 0.05, fontSize: 0.042,
                  align: "center"),
            ]
        case .blindsBug:
            return [
                F(id: "Level.Fill", kind: .shape, color: "#C8102EF0", x: 0.03, y: 0.04, w: 0.09, h: 0.06),
                F(id: "Level.Text", text: "LV 12", x: 0.03, y: 0.045, w: 0.09, h: 0.05, fontSize: 0.03,
                  align: "center"),
                F(id: "Background.Fill", kind: .shape, color: "#0A0A0AE0", x: 0.12, y: 0.04, w: 0.26, h: 0.06),
                F(id: "Blinds.Text", text: "1,000 / 2,000  ·  ANTE 2,000", x: 0.13, y: 0.045, w: 0.24, h: 0.05,
                  fontSize: 0.028, bold: false),
            ]
        case .playerVs:
            return [
                F(id: "Left.Fill", kind: .shape, color: "#1D4ED8E8", x: 0.1, y: 0.78, w: 0.36, h: 0.1),
                F(id: "Right.Fill", kind: .shape, color: "#C8102EE8", x: 0.54, y: 0.78, w: 0.36, h: 0.1),
                F(id: "VS.Fill", kind: .shape, color: "#111111", x: 0.46, y: 0.775, w: 0.08, h: 0.11),
                F(id: "VS.Text", text: "VS", color: gold, x: 0.46, y: 0.79, w: 0.08, h: 0.08, fontSize: 0.05,
                  align: "center"),
                F(id: "PlayerA.Text", text: "PLAYER A", x: 0.115, y: 0.79, w: 0.33, h: 0.08, fontSize: 0.045),
                F(id: "PlayerB.Text", text: "PLAYER B", x: 0.555, y: 0.79, w: 0.33, h: 0.08, fontSize: 0.045,
                  align: "right"),
            ]
        case .fullText:
            return [
                F(id: "Background.Fill", kind: .shape, color: "#00000099", x: 0, y: 0, w: 1, h: 1),
                F(id: "Headline.Text", text: L("제목"), x: 0.08, y: 0.38, w: 0.84, h: 0.14, fontSize: 0.1,
                  align: "center"),
                F(id: "Description.Text", text: L("부제목"), color: "#DDDDDD", x: 0.08, y: 0.53, w: 0.84, h: 0.08,
                  fontSize: 0.045, bold: false, align: "center"),
            ]
        case .titleCard:
            return [
                F(id: "Background.Fill", kind: .shape, color: "#0F172A", x: 0, y: 0, w: 1, h: 1)
                    .with { $0.color2 = "#1E3A8A" },
                F(id: "Line.Fill", kind: .shape, color: gold, x: 0.42, y: 0.56, w: 0.16, h: 0.006),
                F(id: "Headline.Text", text: "EVENT TITLE", x: 0.08, y: 0.4, w: 0.84, h: 0.15, fontSize: 0.11,
                  align: "center").with { $0.shadow = true },
                F(id: "Description.Text", text: "Day 1 · Main Event", color: "#CBD5E1", x: 0.08, y: 0.59, w: 0.84,
                  h: 0.07, fontSize: 0.042, bold: false, align: "center"),
            ]
        case .startingSoon:
            return [
                F(id: "Background.Fill", kind: .shape, color: "#111827", x: 0, y: 0, w: 1, h: 1)
                    .with { $0.color2 = "#312E81" },
                F(id: "Headline.Text", text: L("곧 시작합니다"), x: 0.08, y: 0.36, w: 0.84, h: 0.13, fontSize: 0.09,
                  align: "center"),
                F(id: "Time.Text", mode: .countdown, text: "05:00", color: gold, x: 0.3, y: 0.52, w: 0.4, h: 0.12,
                  fontSize: 0.1, align: "center"),
                F(id: "Description.Text", text: "STARTING SOON", color: "#9CA3AF", x: 0.08, y: 0.66, w: 0.84,
                  h: 0.06, fontSize: 0.034, bold: false, align: "center"),
            ]
        case .brb:
            return [
                F(id: "Background.Fill", kind: .shape, color: "#000000D9", x: 0, y: 0, w: 1, h: 1),
                F(id: "Headline.Text", text: L("잠시 후 계속됩니다"), x: 0.08, y: 0.42, w: 0.84, h: 0.13,
                  fontSize: 0.085, align: "center"),
                F(id: "Description.Text", text: "BE RIGHT BACK", color: gold, x: 0.08, y: 0.56, w: 0.84, h: 0.06,
                  fontSize: 0.036, align: "center"),
            ]
        case .quote:
            return [
                F(id: "Background.Fill", kind: .shape, color: "#000000B3", x: 0.12, y: 0.3, w: 0.76, h: 0.4,
                  cornerRadius: 0.02),
                F(id: "Mark.Text", text: "“", color: gold, x: 0.14, y: 0.3, w: 0.1, h: 0.14, fontSize: 0.14),
                F(id: "Headline.Text", text: L("인용문을 여기에 입력하세요"), x: 0.16, y: 0.42, w: 0.68, h: 0.12,
                  fontSize: 0.05, align: "center"),
                F(id: "Description.Text", text: L("— 이름"), color: "#D1D5DB", x: 0.16, y: 0.57, w: 0.68, h: 0.06,
                  fontSize: 0.032, bold: false, align: "right"),
            ]
        case .liveBug:
            return [
                F(id: "Background.Fill", kind: .shape, color: "#DC2626F2", x: 0.86, y: 0.045, w: 0.1, h: 0.055,
                  cornerRadius: 0.0275),
                F(id: "Headline.Text", text: "● LIVE", x: 0.86, y: 0.048, w: 0.1, h: 0.05, fontSize: 0.03,
                  align: "center"),
            ]
        case .social:
            return [
                F(id: "Background.Fill", kind: .shape, color: "#000000B3", x: 0.72, y: 0.86, w: 0.25, h: 0.07,
                  cornerRadius: 0.035),
                F(id: "Icon.Fill", kind: .shape, color: "#E1306C", x: 0.727, y: 0.8705, w: 0.028, h: 0.049,
                  cornerRadius: 0.012),
                F(id: "Headline.Text", text: "@hongmix", x: 0.765, y: 0.865, w: 0.2, h: 0.06, fontSize: 0.032),
            ]
        case .logo:
            return [F(id: "Logo.Source", kind: .image, x: 0.86, y: 0.04, w: 0.11, h: 0.11)]
        case .countdown:
            return [
                F(id: "Background.Fill", kind: .shape, color: "#000000B3", x: 0.4, y: 0.8, w: 0.2, h: 0.14,
                  cornerRadius: 0.01),
                F(id: "Label.Text", text: "BREAK", color: gold, x: 0.4, y: 0.81, w: 0.2, h: 0.04,
                  fontSize: 0.03, align: "center"),
                F(id: "Time.Text", mode: .countdown, text: "05:00", x: 0.4, y: 0.85, w: 0.2, h: 0.08,
                  fontSize: 0.065, align: "center"),
            ]
        case .clock:
            return [
                F(id: "Background.Fill", kind: .shape, color: "#00000099", x: 0.83, y: 0.04, w: 0.14, h: 0.065,
                  cornerRadius: 0.008),
                F(id: "Time.Text", mode: .clock, text: "", x: 0.83, y: 0.045, w: 0.14, h: 0.055,
                  fontSize: 0.042, align: "center"),
            ]
        case .scoreboard:
            return [
                F(id: "Background.Fill", kind: .shape, color: "#101010E0", x: 0.03, y: 0.04, w: 0.46, h: 0.075,
                  cornerRadius: 0.008),
                F(id: "TeamA.Text", text: "HOME", x: 0.04, y: 0.05, w: 0.13, h: 0.055, fontSize: 0.04),
                F(id: "ScoreA.Text", text: "0", color: gold, x: 0.17, y: 0.05, w: 0.05, h: 0.055,
                  fontSize: 0.045, align: "center"),
                F(id: "TeamB.Text", text: "AWAY", x: 0.23, y: 0.05, w: 0.13, h: 0.055, fontSize: 0.04),
                F(id: "ScoreB.Text", text: "0", color: gold, x: 0.36, y: 0.05, w: 0.05, h: 0.055,
                  fontSize: 0.045, align: "center"),
                F(id: "Period.Text", text: "1", color: "#BBBBBB", x: 0.42, y: 0.05, w: 0.06, h: 0.055,
                  fontSize: 0.035, bold: false, align: "center"),
            ]
        case .ticker:
            return [
                F(id: "Background.Fill", kind: .shape, color: "#0B1F3AE6", x: 0, y: 0.91, w: 1, h: 0.07),
                F(id: "Ticker.Text", mode: .ticker, text: L("흐르는 자막 텍스트를 여기에 입력하세요 · "),
                  x: 0, y: 0.915, w: 1, h: 0.06, fontSize: 0.04, bold: false),
            ]
        case .liveCaptions:
            return [
                F(id: "Background.Fill", kind: .shape, color: "#000000B8", x: 0.12, y: 0.78, w: 0.76, h: 0.15,
                  cornerRadius: 0.012),
                F(id: "Caption.Text", text: L("실시간 자막이 여기에 표시됩니다"), x: 0.14, y: 0.79, w: 0.72, h: 0.07,
                  fontSize: 0.045, align: "center").with { $0.shadow = true },
                F(id: "Translation.Text", text: "", color: "#FFD966", x: 0.14, y: 0.855, w: 0.72, h: 0.06,
                  fontSize: 0.038, bold: false, align: "center").with { $0.shadow = true },
            ]
        case .breakingTicker:
            return [
                F(id: "Background.Fill", kind: .shape, color: "#0A0A0AF0", x: 0, y: 0.91, w: 1, h: 0.07),
                F(id: "Ticker.Text", mode: .ticker, text: L("속보 내용을 여기에 입력하세요 · "),
                  x: 0.14, y: 0.915, w: 0.86, h: 0.06, fontSize: 0.038, bold: false),
                F(id: "Label.Fill", kind: .shape, color: "#DC2626", x: 0, y: 0.91, w: 0.14, h: 0.07),
                F(id: "Label.Text", text: L("속보"), x: 0, y: 0.915, w: 0.14, h: 0.06, fontSize: 0.038,
                  align: "center"),
            ]
        }
    }
}

struct TitleDocument: Codable, Equatable {
    var template: TitleTemplate
    var fields: [TitleField]
    /// Saved text sets (field id -> text), selectable with SelectTitlePreset.
    var presets: [[String: String]] = []
    var selectedPreset: Int = -1
    var countdownSeconds: Double = 300
    /// Countdown starts by itself when the title goes to Output or an overlay (restarts if it had finished)
    var autoStartCountdown = true
    var tickerSpeed: Double = 0.12          // fraction of frame width per second
    var animateSeconds: Double = 0.4
    var inOutEffect: TitleAnimation = .fade
    var name: String = ""                   // user template name ("" = built-in)

    init(template: TitleTemplate) {
        self.template = template
        self.fields = template.makeFields()
        self.inOutEffect = template.defaultAnimation
        self.animateSeconds = template.category == .full ? 0.6 : 0.4
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let t = c.value(.template, TitleTemplate.lowerThird)
        let d = TitleDocument(template: t)
        template = t
        fields = c.value(.fields, d.fields)
        presets = c.value(.presets, d.presets)
        selectedPreset = c.value(.selectedPreset, d.selectedPreset)
        countdownSeconds = c.value(.countdownSeconds, d.countdownSeconds)
        autoStartCountdown = c.value(.autoStartCountdown, d.autoStartCountdown)
        tickerSpeed = c.value(.tickerSpeed, d.tickerSpeed)
        animateSeconds = c.value(.animateSeconds, d.animateSeconds)
        inOutEffect = c.value(.inOutEffect, TitleAnimation.fade)
        name = c.value(.name, "")
    }

    var displayName: String { name.isEmpty ? template.label : name }
}

/// User templates: saved title documents in ~/Library/Application Support/BraceletMix/Titles/*.bmtitle (JSON).
/// Shareable between Macs by copying the files (Export / Import in the title editor).
final class TitleLibrary: ObservableObject {
    static let shared = TitleLibrary()
    @Published private(set) var templates: [TitleDocument] = []

    static var folder: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("BraceletMix/Titles", isDirectory: true)
    }

    init() { reload() }

    func reload() {
        let fm = FileManager.default
        try? fm.createDirectory(at: Self.folder, withIntermediateDirectories: true)
        let files = (try? fm.contentsOfDirectory(at: Self.folder, includingPropertiesForKeys: nil)) ?? []
        templates = files.filter { $0.pathExtension == "bmtitle" }
            .compactMap { try? JSONDecoder().decode(TitleDocument.self, from: Data(contentsOf: $0)) }
            .sorted { $0.name.localizedCompare($1.name) == .orderedAscending }
    }

    private static func fileName(_ name: String) -> String {
        let bad = CharacterSet(charactersIn: "/\\:?*\"<>|")
        return name.components(separatedBy: bad).joined(separator: "_") + ".bmtitle"
    }

    @discardableResult
    func save(_ doc: TitleDocument, name: String) -> URL? {
        var d = doc
        d.name = name
        d.presets = []; d.selectedPreset = -1
        let url = Self.folder.appendingPathComponent(Self.fileName(name))
        let enc = JSONEncoder(); enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? enc.encode(d), (try? data.write(to: url)) != nil else { return nil }
        reload()
        return url
    }

    func delete(_ name: String) {
        try? FileManager.default.removeItem(at: Self.folder.appendingPathComponent(Self.fileName(name)))
        reload()
    }

    func importFile(_ url: URL) -> Bool {
        guard let data = try? Data(contentsOf: url), var doc = try? JSONDecoder().decode(TitleDocument.self, from: data)
        else { return false }
        if doc.name.isEmpty { doc.name = url.deletingPathExtension().lastPathComponent }
        return save(doc, name: doc.name) != nil
    }
}
