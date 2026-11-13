import Foundation
import Combine

/// A saved layer placement (Layers › Preset): position, size, crop, rotation, opacity, border and Fit/Fill.
/// Stored app-wide, so the same "PIP bottom right" works in every input and every project. Values are
/// fractions of the output, so a preset made at 1080p fits a 720p project the same way. The layer's
/// input is never part of a preset.
struct LayerPreset: Codable, Equatable, Identifiable {
    var id = UUID()
    var name: String
    var x: Double, y: Double, w: Double, h: Double
    var cropL: Float = 0, cropT: Float = 0, cropR: Float = 0, cropB: Float = 0
    var rotation: Double = 0
    var opacity: Float = 1
    var border: Double = 0
    var borderColor = "#FFFFFF"
    var fill = true

    init(name: String, from l: InputLayer) {
        self.name = name
        x = l.x; y = l.y; w = l.w; h = l.h
        cropL = l.cropL; cropT = l.cropT; cropR = l.cropR; cropB = l.cropB
        rotation = l.rotation; opacity = l.opacity
        border = l.border; borderColor = l.borderColor; fill = l.fill
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = c.value(.id, UUID())
        name = c.value(.name, "")
        x = c.value(.x, 0); y = c.value(.y, 0); w = c.value(.w, 0.3); h = c.value(.h, 0.3)
        cropL = c.value(.cropL, Float(0)); cropT = c.value(.cropT, Float(0))
        cropR = c.value(.cropR, Float(0)); cropB = c.value(.cropB, Float(0))
        rotation = c.value(.rotation, 0); opacity = c.value(.opacity, Float(1))
        border = c.value(.border, 0); borderColor = c.value(.borderColor, "#FFFFFF"); fill = c.value(.fill, true)
    }

    /// Placement values onto `l`; its input, visibility, lock and id stay.
    func apply(to l: inout InputLayer) {
        l.x = x; l.y = y; l.w = w; l.h = h
        l.cropL = cropL; l.cropT = cropT; l.cropR = cropR; l.cropB = cropB
        l.rotation = rotation; l.opacity = opacity
        l.border = border; l.borderColor = borderColor; l.fill = fill
        l.cropFills = true
    }

    /// Only finite, sane values (a hand-edited or damaged defaults entry must not reach the renderer).
    var isValid: Bool {
        let d = [x, y, w, h, rotation, border], f = [cropL, cropT, cropR, cropB, opacity]
        return d.allSatisfy(\.isFinite) && f.allSatisfy(\.isFinite) && w > 0 && h > 0 && w < 10 && h < 10
            && abs(x) < 10 && abs(y) < 10
            && [cropL, cropT, cropR, cropB].allSatisfy { $0 >= 0 && $0 < 1 } && cropL + cropR < 1 && cropT + cropB < 1
            && opacity >= 0 && opacity <= 1 && border >= 0 && border < 1000
    }
}

/// App-wide list of layer presets (UserDefaults "layerPresets", JSON). Main thread.
final class LayerPresetStore: ObservableObject {
    static let shared = LayerPresetStore()
    static let key = "layerPresets"
    @Published private(set) var items: [LayerPreset] = []

    /// One damaged entry is skipped, not the whole list.
    private struct Lenient: Decodable {
        let preset: LayerPreset?
        init(from decoder: Decoder) throws { preset = try? LayerPreset(from: decoder) }
    }

    private init() {
        guard let d = UserDefaults.standard.data(forKey: Self.key) else { return }
        if let list = try? JSONDecoder().decode([Lenient].self, from: d) {
            items = list.compactMap(\.preset).filter(\.isValid)
        } else {
            // unreadable as a whole: keep a copy instead of overwriting it on the next save
            UserDefaults.standard.set(d, forKey: Self.key + ".unreadable")
        }
    }

    private func save() {
        if let d = try? JSONEncoder().encode(items) { UserDefaults.standard.set(d, forKey: Self.key) }
    }

    /// Same name = replace (keeps its place in the list).
    func add(_ p: LayerPreset) {
        guard p.isValid else { return }
        if let k = items.firstIndex(where: { $0.name.caseInsensitiveCompare(p.name) == .orderedSame }) {
            var q = p; q.id = items[k].id; items[k] = q
        } else {
            items.append(p)
        }
        save()
    }

    func remove(_ id: UUID) { items.removeAll { $0.id == id }; save() }

    /// false = another preset already has that name (names are unique, not case-sensitive).
    @discardableResult
    func rename(_ id: UUID, to name: String) -> Bool {
        let n = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !n.isEmpty, let k = items.firstIndex(where: { $0.id == id }) else { return true }
        if items.contains(where: { $0.id != id && $0.name.caseInsensitiveCompare(n) == .orderedSame }) { return false }
        items[k].name = n
        save()
        return true
    }

    func preset(named n: String) -> LayerPreset? {
        items.first { $0.name.caseInsensitiveCompare(n.trimmingCharacters(in: .whitespaces)) == .orderedSame }
    }
}
