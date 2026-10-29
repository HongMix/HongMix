import Foundation

/// Rolling 2-minute history of engine / stream health, sampled once per second on the main thread.
/// Shown as graphs in Statistics so a hiccup that happened while you were looking elsewhere is still visible.
final class HealthHistory {
    struct Sample {
        var time: Date
        var renderAvgMs: Double
        var renderMaxMs: Double
        var droppedFrames: Int       // render ticks dropped in this second
        var streamKbps: Double       // sum of running stream outputs
        var srtRttMs: Double         // worst SRT link (inputs + outputs), 0 = none
        var srtLossPct: Double
        var uiStallMs: Double
        var lostInputs: Int
    }
    static let capacity = 120
    private(set) var samples: [Sample] = []

    func append(_ s: Sample) {
        samples.append(s)
        if samples.count > HealthHistory.capacity { samples.removeFirst(samples.count - HealthHistory.capacity) }
    }

    func series(_ key: KeyPath<Sample, Double>) -> [Double] { samples.map { $0[keyPath: key] } }
    func intSeries(_ key: KeyPath<Sample, Int>) -> [Double] { samples.map { Double($0[keyPath: key]) } }

    /// Seconds ago of the last sample where `bad` held (for "last problem: 37 s ago").
    func lastEvent(where bad: (Sample) -> Bool) -> TimeInterval? {
        guard let s = samples.last(where: bad) else { return nil }
        return Date().timeIntervalSince(s.time)
    }
}
