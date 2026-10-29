import Foundation

/// One scheduled API call ("at 19:00 on weekdays: StartStreaming"). Any vMix-style function works,
/// so a schedule can cut, start/stop streaming or recording, play a clip, bring in an overlay, etc.
struct ScheduledAction: Codable, Identifiable, Equatable {
    var id = UUID()
    var enabled = true
    var name = ""
    var hour = 9, minute = 0, second = 0
    var weekdays: [Int] = []          // Calendar weekday 1 = Sun … 7 = Sat; empty = every day
    var date: Date? = nil             // set = one-shot on that day (disables itself after firing)
    var function = "StartStreaming"
    var input = ""                    // input key, number or title ("" = none)
    var value = ""
    var extra = ""                    // more query parameters, e.g. "Duration=1000&SelectedName=Title.Text"
    var lastFired: Date? = nil

    var timeText: String { String(format: "%02d:%02d:%02d", hour, minute, second) }

    /// Next time this fires after `now` (nil = disabled / one-shot already passed).
    func nextFire(after now: Date, calendar cal: Calendar = .current) -> Date? {
        guard enabled else { return nil }
        if let d = date {
            var c = cal.dateComponents([.year, .month, .day], from: d)
            c.hour = hour; c.minute = minute; c.second = second
            guard let t = cal.date(from: c), t > now else { return nil }
            return t
        }
        for dayOffset in 0..<8 {
            guard let day = cal.date(byAdding: .day, value: dayOffset, to: now) else { continue }
            var c = cal.dateComponents([.year, .month, .day], from: day)
            c.hour = hour; c.minute = minute; c.second = second
            guard let t = cal.date(from: c), t > now else { continue }
            if weekdays.isEmpty || weekdays.contains(cal.component(.weekday, from: t)) { return t }
        }
        return nil
    }

    var query: [String: String] {
        var q = APIProcessor.parseQuery(extra)
        if !input.isEmpty { q["input"] = input }
        if !value.isEmpty { q["value"] = value }
        return q
    }
}

/// Runs scheduled actions on the main thread. Checked once per second; an action fires when its time
/// falls inside the last check window, so it fires exactly once even if a tick is late (and never
/// "catches up" on schedules missed while the app was closed).
final class Scheduler: ObservableObject {
    @Published var actions: [ScheduledAction] = []
    @Published private(set) var log: [String] = []      // newest first, last 50
    private var lastCheck = Date()

    func load(_ a: [ScheduledAction]) {
        actions = a
        lastCheck = Date()
    }

    func tick(_ engine: SwitcherEngine, now: Date = Date()) {
        defer { lastCheck = now }
        // clock jumped (sleep/wake, manual change): don't fire a backlog
        guard now > lastCheck, now.timeIntervalSince(lastCheck) < 30 else { return }
        for idx in actions.indices {
            let a = actions[idx]
            guard let t = a.nextFire(after: lastCheck), t <= now else { continue }
            run(idx, engine, now: now)
        }
    }

    func runNow(_ id: UUID, _ engine: SwitcherEngine) {
        if let idx = actions.firstIndex(where: { $0.id == id }) { run(idx, engine, now: Date(), manual: true) }
    }

    private func run(_ idx: Int, _ engine: SwitcherEngine, now: Date, manual: Bool = false) {
        let a = actions[idx]
        let err = APIProcessor.perform(a.function, a.query, engine)
        actions[idx].lastFired = now
        if a.date != nil && !manual { actions[idx].enabled = false }
        let f = DateFormatter(); f.dateFormat = "HH:mm:ss"
        let label = a.name.isEmpty ? a.function : "\(a.name) (\(a.function))"
        log.insert("\(f.string(from: now))  \(manual ? "수동 " : "")\(label)" + (err.map { Lf(" — 오류: %@", "\($0)") } ?? " ✓"), at: 0)
        if log.count > 50 { log.removeLast(log.count - 50) }
        engine.lastMessage = err == nil ? Lf("⏰ 스케줄 실행: %@", "\(label)") : Lf("⚠︎ 스케줄 실패: %@ — %@", "\(label)", "\(err!)")
    }

    var nextUp: (ScheduledAction, Date)? {
        let now = Date()
        return actions.compactMap { a in a.nextFire(after: now).map { (a, $0) } }.min { $0.1 < $1.1 }
    }
}
