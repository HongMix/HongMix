import Foundation

/// Talent Cue countdown (or count-up). Pure value type: the time comes in as a parameter, so it is testable
/// and every view (control window, Talent Display, web remote) computes the same thing from the same state.
struct TalentTimer: Codable, Equatable {
    enum Phase: String { case normal, warning, critical, overtime }

    /// Length in seconds (countdown)
    var duration: Double = 20 * 60
    /// Remaining seconds at which the colour turns to "warning" / "critical"
    var warnAt: Double = 5 * 60
    var criticalAt: Double = 60
    var countUp = false
    private var startedAt: Date? = nil
    /// Time run before the last start (pauses keep it)
    private var elapsedBefore: Double = 0

    init(duration: Double = 20 * 60, warnAt: Double = 5 * 60, criticalAt: Double = 60, countUp: Bool = false) {
        self.duration = duration
        self.warnAt = warnAt
        self.criticalAt = criticalAt
        self.countUp = countUp
    }

    var running: Bool { startedAt != nil }

    func elapsed(at now: Date) -> Double { elapsedBefore + (startedAt.map { now.timeIntervalSince($0) } ?? 0) }

    /// Negative in overtime.
    func remaining(at now: Date) -> Double { duration - elapsed(at: now) }

    /// What the display shows: elapsed time for count-up, remaining time otherwise.
    func displaySeconds(at now: Date) -> Double { countUp ? elapsed(at: now) : remaining(at: now) }

    func phase(at now: Date) -> Phase {
        if countUp { return .normal }
        let r = remaining(at: now)
        if r <= 0 { return .overtime }
        if r <= criticalAt { return .critical }
        if r <= warnAt { return .warning }
        return .normal
    }

    mutating func start(at now: Date) { if startedAt == nil { startedAt = now } }

    mutating func pause(at now: Date) {
        guard startedAt != nil else { return }
        elapsedBefore = elapsed(at: now)
        startedAt = nil
    }

    mutating func reset() {
        startedAt = nil
        elapsedBefore = 0
    }

    /// +1 / −1 minute buttons: change the length, never below zero.
    mutating func add(seconds: Double) { duration = max(0, duration + seconds) }

    /// "19:59", "1:02:05", "-1:15". Counting down rounds up (the last fraction still reads 0:01).
    static func format(_ seconds: Double) -> String {
        let s = seconds > 0 ? Int(seconds.rounded(.up)) : Int((-seconds).rounded(.down))
        let sign = seconds < 0 && s > 0 ? "-" : ""
        let h = s / 3600, m = (s % 3600) / 60, sec = s % 60
        return h > 0 ? String(format: "%@%d:%02d:%02d", sign, h, m, sec) : String(format: "%@%d:%02d", sign, m, sec)
    }
}
