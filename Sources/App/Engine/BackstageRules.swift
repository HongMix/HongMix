import Foundation

/// How often Backstage may restart a HongMix that went away without quitting: at most `limit` times within
/// `window` seconds, so a HongMix that crashes right at launch doesn't loop forever.
struct RelaunchBudget {
    var limit = 3
    var window: TimeInterval = 120
    private var times: [Date] = []

    mutating func allow(at now: Date) -> Bool {
        times.removeAll { now.timeIntervalSince($0) >= window }
        guard times.count < limit else { return false }
        times.append(now)
        return true
    }
}
