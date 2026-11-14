import Foundation
import Combine

/// SRT connection settings the operator used or saved (Input editor › Stream / SRT › "Recent and saved SRT").
/// Saved entries have a name and stay at the top; recent ones are kept automatically (last 10) whenever an
/// SRT input is added or changed. App-wide (UserDefaults "srtPresets"), so they work in every project.
///
/// The passphrase is stored like the project file already stores it (inside the SRT URL) — not in the
/// Keychain: HongMix is ad-hoc signed, so every update would make macOS ask for Keychain access again.
/// The UI never shows it (••••).
struct SRTPreset: Codable, Equatable, Identifiable {
    var id = UUID()
    var name = ""                  // "" = recent (unnamed)
    var saved = false
    var mode = "caller"            // caller / listener / rendezvous
    var host = ""
    var port = 9000
    var latencyMs = 200
    var passphrase = ""
    var streamID = ""
    var lastUsed = Date()

    init(mode: String, host: String, port: Int, latencyMs: Int, passphrase: String, streamID: String) {
        self.mode = mode; self.host = host; self.port = port; self.latencyMs = latencyMs
        self.passphrase = passphrase; self.streamID = streamID
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = c.value(.id, UUID()); name = c.value(.name, ""); saved = c.value(.saved, false)
        mode = c.value(.mode, "caller"); host = c.value(.host, ""); port = c.value(.port, 9000)
        latencyMs = c.value(.latencyMs, 200); passphrase = c.value(.passphrase, ""); streamID = c.value(.streamID, "")
        lastUsed = c.value(.lastUsed, Date())
    }

    /// Same endpoint = same entry (latency / passphrase are settings of it).
    var key: String { "\(mode)|\(mode == "listener" ? "" : host.lowercased())|\(port)|\(streamID)" }

    var isValid: Bool {
        ["caller", "listener", "rendezvous"].contains(mode) && (1...65535).contains(port)
            && (20...8000).contains(latencyMs) && (mode == "listener" || !host.isEmpty)
    }

    /// "Caller · host:2050 · 1000 ms · passphrase"
    var summary: String {
        var s = (mode == "listener" ? "Listener" : mode == "rendezvous" ? "Rendezvous" : "Caller")
        s += " · " + (mode == "listener" ? ":\(port)" : "\(host):\(port)")
        s += " · \(latencyMs) ms"
        if !passphrase.isEmpty { s += " · " + L("암호") }
        if !streamID.isEmpty { s += " · ID \(streamID)" }
        return s
    }
}

/// Main thread.
final class SRTPresetStore: ObservableObject {
    static let shared = SRTPresetStore()
    static let key = "srtPresets"
    static let maxRecent = 10
    @Published private(set) var items: [SRTPreset] = []

    /// Saved (by name) first, then recent (newest first).
    var ordered: [SRTPreset] {
        items.filter(\.saved).sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            + items.filter { !$0.saved }.sorted { $0.lastUsed > $1.lastUsed }
    }

    private struct Lenient: Decodable {
        let p: SRTPreset?
        init(from decoder: Decoder) throws { p = try? SRTPreset(from: decoder) }
    }

    private init() {
        guard let d = UserDefaults.standard.data(forKey: Self.key) else { return }
        if let list = try? JSONDecoder().decode([Lenient].self, from: d) {
            items = list.compactMap(\.p).filter(\.isValid)
        } else {
            UserDefaults.standard.set(d, forKey: Self.key + ".unreadable")
        }
    }

    private func save() {
        if let d = try? JSONEncoder().encode(items) { UserDefaults.standard.set(d, forKey: Self.key) }
    }

    /// An SRT input was added or changed: remember it (updates the saved / recent entry of that endpoint).
    func recordUse(_ p: SRTPreset) {
        guard p.isValid else { return }
        if let k = items.firstIndex(where: { $0.key == p.key }) {
            items[k].latencyMs = p.latencyMs
            items[k].passphrase = p.passphrase
            items[k].host = p.host
            items[k].lastUsed = Date()
        } else {
            var q = p; q.lastUsed = Date(); q.saved = false; q.name = ""
            items.append(q)
        }
        // keep only the newest recent ones
        let recent = items.filter { !$0.saved }.sorted { $0.lastUsed > $1.lastUsed }
        if recent.count > Self.maxRecent {
            let drop = Set(recent.dropFirst(Self.maxRecent).map(\.id))
            items.removeAll { drop.contains($0.id) }
        }
        save()
    }

    /// Save under a name (same endpoint or same name = that entry is updated). Returns false if another
    /// saved entry already has the name.
    @discardableResult
    func save(_ p: SRTPreset, name: String) -> Bool {
        let n = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !n.isEmpty, p.isValid else { return false }
        if items.contains(where: { $0.saved && $0.key != p.key && $0.name.caseInsensitiveCompare(n) == .orderedSame }) { return false }
        var q = p
        q.name = String(n.prefix(60)); q.saved = true; q.lastUsed = Date()
        if let k = items.firstIndex(where: { $0.key == p.key }) { q.id = items[k].id; items[k] = q } else { items.append(q) }
        save()
        return true
    }

    @discardableResult
    func rename(_ id: UUID, to name: String) -> Bool {
        let n = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !n.isEmpty, let k = items.firstIndex(where: { $0.id == id }) else { return false }
        if items.contains(where: { $0.saved && $0.id != id && $0.name.caseInsensitiveCompare(n) == .orderedSame }) { return false }
        items[k].name = String(n.prefix(60)); items[k].saved = true
        save()
        return true
    }

    func remove(_ id: UUID) { items.removeAll { $0.id == id }; save() }
}
