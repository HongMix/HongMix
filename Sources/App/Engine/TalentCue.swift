import Foundation
import Combine

/// Talent Cue (a simple stage timer): what the presenter's "Talent Display" shows — a message pushed by
/// the operator, a countdown with colour phases, or an idle screen (clock, logo, title, black).
/// Controlled from the Talent Cue window and by a moderator through `/talent?key=…` (TalentRemote.swift).
/// Main thread only.
final class TalentCue: ObservableObject {
    static let shared = TalentCue()

    struct Message: Codable, Identifiable, Equatable {
        var id = UUID()
        var text: String
        var color = "#FFFFFF"
    }

    enum Idle: String, Codable, CaseIterable, Identifiable {
        case clock, logo, title, black
        var id: String { rawValue }
        var label: String {
            switch self {
            case .clock: return L("시계")
            case .logo: return L("로고")
            case .title: return L("제목만")
            case .black: return L("검은 화면")
            }
        }
    }

    struct Settings: Codable, Equatable {
        var title = ""
        var idle: Idle = .clock
        var background = "#000000"
        var backgroundImage = ""
        var logoPath = ""
        var timerScale = 1.0
        var messageScale = 1.0
        var clockUnderTimer = true
        var clock24h = true
        var colorNormal = "#2ECC40"
        var colorWarning = "#FF9F1A"
        var colorCritical = "#FF3B30"
        var flashOvertime = true
    }

    @Published var settings = Settings() { didSet { save() } }
    /// Prepared messages; one of them can be on the display.
    @Published var messages: [Message] = [] { didSet { save() } }
    @Published var timer = TalentTimer() { didSet { save() } }
    @Published var liveMessageID: UUID? = nil
    /// Make the live message stand out (it blinks)
    @Published var flash = false
    @Published var timerOnDisplay = false
    /// Everything off: a black screen
    @Published var blackout = false
    /// Secret part of the moderator link
    @Published private(set) var token: String

    var liveMessage: Message? { messages.first { $0.id == liveMessageID } }

    private static let key = "talentCue"
    private struct Saved: Codable { var settings: Settings; var messages: [Message]; var timer: TalentTimer }

    private init() {
        token = UserDefaults.standard.string(forKey: "talentCueToken") ?? TalentCue.newToken()
        UserDefaults.standard.set(token, forKey: "talentCueToken")
        if let d = UserDefaults.standard.data(forKey: Self.key), let s = try? JSONDecoder().decode(Saved.self, from: d) {
            settings = s.settings
            messages = s.messages
            timer = s.timer
        } else {
            messages = [L("1분 남았습니다"), L("마무리해 주세요"), L("조금 더 크게 말씀해 주세요"), L("질문 받기")]
                .map { Message(text: $0) }
        }
    }

    private func save() {
        if let d = try? JSONEncoder().encode(Saved(settings: settings, messages: messages, timer: timer)) {
            UserDefaults.standard.set(d, forKey: Self.key)
        }
    }

    private static func newToken() -> String {
        (0..<4).map { _ in String(UInt32.random(in: 0...UInt32.max), radix: 36) }.joined()
    }

    /// New moderator link; the old one stops working.
    func regenerateToken() {
        token = TalentCue.newToken()
        UserDefaults.standard.set(token, forKey: "talentCueToken")
    }

    // MARK: Actions (window and web remote)

    func show(_ id: UUID) {
        guard messages.contains(where: { $0.id == id }) else { return }
        liveMessageID = id
        blackout = false
    }

    func hideMessage() {
        liveMessageID = nil
        flash = false
    }

    func addMessage(_ text: String, color: String = "#FFFFFF") -> Message? {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return nil }
        let m = Message(text: String(t.prefix(500)), color: color)
        messages.append(m)
        return m
    }

    func deleteMessage(_ id: UUID) {
        if liveMessageID == id { hideMessage() }
        messages.removeAll { $0.id == id }
    }

    func startTimer() { timer.start(at: Date()); timerOnDisplay = true; blackout = false }
    func pauseTimer() { timer.pause(at: Date()) }
    func resetTimer() { timer.reset() }
    func setTimer(seconds: Double) {
        timer.reset()
        timer.duration = max(0, min(24 * 3600, seconds))
    }

    /// Moderator page commands (`/talent/cmd?key=…&a=…`). Returns an error text, nil = done.
    func perform(_ q: [String: String]) -> String? {
        let id = q["id"].flatMap(UUID.init(uuidString:))
        let on = q["on"] == "1"
        switch q["a"] ?? "" {
        case "show": guard let id else { return "id?" }; show(id)
        case "hide": hideMessage()
        case "flash": flash = on
        case "add":
            guard let m = addMessage(q["text"] ?? "", color: q["color"] ?? "#FFFFFF") else { return "text?" }
            if q["show"] == "1" { show(m.id) }
        case "delete": guard let id else { return "id?" }; deleteMessage(id)
        case "start": startTimer()
        case "pause": pauseTimer()
        case "reset": resetTimer()
        case "set": guard let s = q["sec"].flatMap(Double.init) else { return "sec?" }; setTimer(seconds: s)
        case "plus": guard let s = q["sec"].flatMap(Double.init) else { return "sec?" }; timer.add(seconds: max(-3600, min(3600, s)))
        case "timer": timerOnDisplay = on
        case "blackout": blackout = on
        default: return "unknown action"
        }
        return nil
    }

    /// State for the moderator page (polled). No file paths.
    func stateJSON(now: Date = Date()) -> String {
        let colors: [TalentTimer.Phase: String] = [.normal: settings.colorNormal, .warning: settings.colorWarning,
                                                   .critical: settings.colorCritical, .overtime: settings.colorCritical]
        let phase = timer.phase(at: now)
        let s: [String: Any] = [
            "title": settings.title, "idle": settings.idle.rawValue, "blackout": blackout,
            "live": liveMessageID?.uuidString ?? "", "flash": flash,
            "messages": messages.map { ["id": $0.id.uuidString, "text": $0.text, "color": $0.color] },
            "timer": ["text": TalentTimer.format(timer.displaySeconds(at: now)), "phase": phase.rawValue,
                      "color": colors[phase] ?? "#FFFFFF", "running": timer.running, "visible": timerOnDisplay,
                      "duration": Int(timer.duration)],
        ]
        return WebRemote.json(s)
    }
}
