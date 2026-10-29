import Foundation

/// One API call inside a rundown step (same functions as the vMix API / shortcuts / scheduler).
struct RundownAction: Codable, Identifiable, Equatable {
    var id = UUID()
    var function = "Cut"
    var input = ""        // input key, number or title
    var value = ""
    var extra = ""        // more query parameters, e.g. "Duration=1000"

    var query: [String: String] {
        var q = APIProcessor.parseQuery(extra)
        if !input.isEmpty { q["input"] = input }
        if !value.isEmpty { q["value"] = value }
        return q
    }
}

/// One line of the show's running order: what happens when you press NEXT, and how long it should last.
struct RundownItem: Codable, Identifiable, Equatable {
    var id = UUID()
    var title = ""
    var notes = ""
    var durationSec = 60            // planned length (0 = open-ended)
    var autoNext = false            // advance automatically when the planned length is over
    var actions: [RundownAction] = []
}

/// Rundown (cue sheet) player: NEXT runs the next item's actions in order and times every item.
final class Rundown: ObservableObject {
    @Published var items: [RundownItem] = []
    @Published private(set) var current = -1              // -1 = not started
    @Published private(set) var itemStarted: Date? = nil
    @Published private(set) var showStarted: Date? = nil
    @Published private(set) var log: [String] = []

    func load(_ i: [RundownItem]) { items = i; current = -1; itemStarted = nil; showStarted = nil }

    var plannedTotal: Int { items.reduce(0) { $0 + $1.durationSec } }

    /// Planned start offset of item i (seconds from the top of the show).
    func plannedStart(_ i: Int) -> Int { items.prefix(i).reduce(0) { $0 + $1.durationSec } }

    func go(_ index: Int, _ engine: SwitcherEngine) {
        guard items.indices.contains(index) else { return }
        current = index
        let now = Date()
        itemStarted = now
        if showStarted == nil { showStarted = now }
        var errs: [String] = []
        for a in items[index].actions {
            if let e = APIProcessor.perform(a.function, a.query, engine) { errs.append("\(a.function): \(e)") }
        }
        let f = DateFormatter(); f.dateFormat = "HH:mm:ss"
        log.insert("\(f.string(from: now))  \(index + 1). \(items[index].title)" + (errs.isEmpty ? "" : "  ⚠︎ " + errs.joined(separator: ", ")), at: 0)
        if log.count > 100 { log.removeLast(log.count - 100) }
        if !errs.isEmpty { engine.lastMessage = Lf("런다운 %@: %@", "\(index + 1)", errs.joined(separator: ", ")) }
    }

    func next(_ e: SwitcherEngine) { go(current + 1, e) }
    func previous(_ e: SwitcherEngine) { if current > 0 { go(current - 1, e) } }
    func reset() { current = -1; itemStarted = nil; showStarted = nil }

    /// Called every second (main thread): auto-advance.
    func tick(_ e: SwitcherEngine) {
        guard items.indices.contains(current), let s = itemStarted else { return }
        let it = items[current]
        if it.autoNext && it.durationSec > 0 && Date().timeIntervalSince(s) >= Double(it.durationSec) && current + 1 < items.count {
            next(e)
        }
    }

    /// Actions that reproduce what is on air right now (Program input + active overlays).
    static func captureActions(_ e: SwitcherEngine) -> [RundownAction] {
        var a: [RundownAction] = [RundownAction(function: "OverlayInputAllOff")]
        if let p = e.programID { a.append(RundownAction(function: "Fade", input: p.uuidString, extra: "Duration=500")) }
        for k in 0..<e.overlayIDs.count where e.overlayOn[k] {
            if let id = e.overlayIDs[k] { a.append(RundownAction(function: "OverlayInput\(k + 1)In", input: id.uuidString)) }
        }
        return a
    }
}
