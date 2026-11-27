import Foundation
import CoreGraphics

/// Ready-made MultiView layouts. Every cell keeps the canvas aspect ratio (16:9 on a 16:9 canvas).
enum MultiViewLayoutKind: String, Codable, CaseIterable, Identifiable {
    case bigTop          // 2 large on top, 8 small below (the classic layout)
    case bigBottom       // 8 small on top, 2 large below
    case bigLeft         // 2 large stacked on the left, 8 small on the right
    case bigRight        // 8 small on the left, 2 large stacked on the right
    case fourBig         // 2 × 2
    case grid9           // 3 × 3
    case grid16          // 4 × 4

    var id: String { rawValue }

    var title: String {
        switch self {
        case .bigTop: return L("2 크게 위 + 8 작게 아래")
        case .bigBottom: return L("8 작게 위 + 2 크게 아래")
        case .bigLeft: return L("2 크게 왼쪽 + 8 작게 오른쪽")
        case .bigRight: return L("8 작게 왼쪽 + 2 크게 오른쪽")
        case .fourBig: return L("4 크게 (2×2)")
        case .grid9: return "3×3"
        case .grid16: return "4×4"
        }
    }

    /// Number of large cells (they come first in `rects`).
    var bigCount: Int {
        switch self {
        case .bigTop, .bigBottom, .bigLeft, .bigRight: return 2
        case .fourBig: return 4
        case .grid9, .grid16: return 0
        }
    }

    /// Cell rectangles on a W × H canvas (top-left origin): large cells first, then small, reading order.
    func rects(width: CGFloat, height: CGFloat) -> [CGRect] {
        let W = width, H = height
        func grid(x: CGFloat, y: CGFloat, w: CGFloat, h: CGFloat, cols: Int, rows: Int) -> [CGRect] {
            let cw = w / CGFloat(cols), ch = h / CGFloat(rows)
            var out: [CGRect] = []
            for r in 0..<rows { for c in 0..<cols {
                out.append(CGRect(x: x + CGFloat(c) * cw, y: y + CGFloat(r) * ch, width: cw, height: ch))
            } }
            return out
        }
        switch self {
        case .bigTop:
            return grid(x: 0, y: 0, w: W, h: H / 2, cols: 2, rows: 1) + grid(x: 0, y: H / 2, w: W, h: H / 2, cols: 4, rows: 2)
        case .bigBottom:
            return grid(x: 0, y: H / 2, w: W, h: H / 2, cols: 2, rows: 1) + grid(x: 0, y: 0, w: W, h: H / 2, cols: 4, rows: 2)
        case .bigLeft:
            return grid(x: 0, y: 0, w: W / 2, h: H, cols: 1, rows: 2) + grid(x: W / 2, y: 0, w: W / 2, h: H, cols: 2, rows: 4)
        case .bigRight:
            return grid(x: W / 2, y: 0, w: W / 2, h: H, cols: 1, rows: 2) + grid(x: 0, y: 0, w: W / 2, h: H, cols: 2, rows: 4)
        case .fourBig:
            return grid(x: 0, y: 0, w: W, h: H, cols: 2, rows: 2)
        case .grid9:
            return grid(x: 0, y: 0, w: W, h: H, cols: 3, rows: 3)
        case .grid16:
            return grid(x: 0, y: 0, w: W, h: H, cols: 4, rows: 4)
        }
    }

    var cellCount: Int { rects(width: 16, height: 9).count }

    /// What a fresh cell shows: Preview + Output in the first two large cells, inputs in order after that.
    func defaultSlot(_ index: Int) -> MultiViewSlot {
        index == 0 ? .preview : (index == 1 ? .program : .auto)
    }
}

/// What one MultiView cell shows.
enum MultiViewSlot: Codable, Hashable {
    /// The next input in input order (the n-th "auto" cell shows input n)
    case auto
    case preview
    case program
    case input(UUID)
    case empty
    /// The Talent Cue screen (TalentFrames)
    case talent
}

/// One user-made MultiView: a layout plus what each cell shows.
struct MultiViewConfig: Codable, Identifiable, Equatable {
    var id = UUID()
    var name: String
    var layout: MultiViewLayoutKind = .bigTop
    /// One entry per cell (missing entries fall back to the layout default).
    var slots: [MultiViewSlot] = []
    var showLabels = true
    var showTally = true
    /// Own label per cell ("" = automatic: PREVIEW, PROGRAM, "3  Cam 3" …)
    var labels: [String] = []
    /// Labels in a strip under each picture (pictures get a bit smaller, with room around them) instead of on it
    var labelsBelow = false

    init(id: UUID = UUID(), name: String, layout: MultiViewLayoutKind = .bigTop, slots: [MultiViewSlot] = [],
         showLabels: Bool = true, showTally: Bool = true, labels: [String] = [], labelsBelow: Bool = false) {
        self.id = id; self.name = name; self.layout = layout; self.slots = slots
        self.showLabels = showLabels; self.showTally = showTally; self.labels = labels; self.labelsBelow = labelsBelow
    }

    private enum K: String, CodingKey { case id, name, layout, slots, showLabels, showTally, labels, labelsBelow }

    // Tolerant: MultiViews saved by an older HongMix miss the newer keys.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: K.self)
        id = (try? c.decode(UUID.self, forKey: .id)) ?? UUID()
        name = (try? c.decode(String.self, forKey: .name)) ?? "MultiView"
        layout = (try? c.decode(MultiViewLayoutKind.self, forKey: .layout)) ?? .bigTop
        slots = (try? c.decode([MultiViewSlot].self, forKey: .slots)) ?? []
        showLabels = (try? c.decode(Bool.self, forKey: .showLabels)) ?? true
        showTally = (try? c.decode(Bool.self, forKey: .showTally)) ?? true
        labels = (try? c.decode([String].self, forKey: .labels)) ?? []
        labelsBelow = (try? c.decode(Bool.self, forKey: .labelsBelow)) ?? false
    }

    /// Labels below: the picture (cell aspect, centred, a margin all round) and the label strip right under it.
    static func labelBelowRects(cell r: CGRect, labelHeight: CGFloat) -> (picture: CGRect, label: CGRect) {
        let m = r.height * 0.04
        let h = max(1, r.height - 2 * m - labelHeight)
        let w = h * r.width / max(1, r.height)
        let pic = CGRect(x: r.midX - w / 2, y: r.minY + m, width: w, height: h)
        return (pic, CGRect(x: pic.minX, y: pic.maxY, width: w, height: labelHeight))
    }

    func customLabel(_ i: Int) -> String? {
        guard labels.indices.contains(i) else { return nil }
        let t = labels[i].trimmingCharacters(in: .whitespaces)
        return t.isEmpty ? nil : t
    }

    /// Automatic label of a cell showing `target` (nil = no label).
    static func defaultLabel(_ target: MultiViewSlot, number: Int?, name: String?) -> String? {
        switch target {
        case .preview: return "PREVIEW"
        case .program: return "PROGRAM"
        case .talent: return "TALENT"
        case .input: return number.map { "\($0)  \(name ?? "")" }
        case .empty, .auto: return nil
        }
    }

    func slot(_ i: Int) -> MultiViewSlot { slots.indices.contains(i) ? slots[i] : layout.defaultSlot(i) }

    /// Slots for every cell of the current layout.
    var resolvedSlots: [MultiViewSlot] { (0..<layout.cellCount).map(slot) }

    /// Slots with every Auto cell turned into the input it shows (the n-th Auto cell = input n), or .empty.
    /// The renderer and the editor labels both use this, so they always agree.
    func cellTargets(inputIDs: [UUID]) -> [MultiViewSlot] {
        var next = 0
        return resolvedSlots.map { s in
            guard s == .auto else { return s }
            defer { next += 1 }
            return next < inputIDs.count ? .input(inputIDs[next]) : .empty
        }
    }

    mutating func setLayout(_ l: MultiViewLayoutKind) {
        guard l != layout else { return }
        // keep what the user picked for cells that still exist, defaults for new ones
        let old = resolvedSlots
        let oldLayout = layout
        layout = l
        slots = (0..<l.cellCount).map { i in
            if i < old.count && old[i] != oldLayout.defaultSlot(i) { return old[i] }
            return l.defaultSlot(i)
        }
        labels = Array(labels.prefix(l.cellCount))     // labels stay with their cell number, like the slots
    }

    /// Own label for cell `i` ("" = automatic).
    mutating func setLabel(_ text: String, at i: Int) {
        guard (0..<layout.cellCount).contains(i) else { return }
        if labels.count <= i { labels += Array(repeating: "", count: i + 1 - labels.count) }
        labels[i] = text
    }

    /// Height of the label bar on a frame `frameHeight` px high (MetalMixer.drawLabels draws it; labels-below makes room for it).
    static func labelBarHeight(frameHeight: CGFloat) -> CGFloat { frameHeight / 45 * 1.5 }

    static func standard() -> MultiViewConfig { MultiViewConfig(name: "MultiView 1") }
}

/// When rendering gets tight, MultiViews drop frames first (render every n-th frame, repeat the last one in
/// between) so Program and the other live outputs keep full rate. Render thread only; `evaluate` once a second.
struct MultiViewThrottle {
    static let maxDivider = 8
    /// MultiViews render on every n-th frame
    private(set) var divider = 1
    private var sumMs = 0.0, count = 0, calmSeconds = 0

    mutating func add(ms: Double) { sumMs += ms; count += 1 }

    func renders(tick: Int64) -> Bool { tick % Int64(divider) == 0 }

    /// `active`: a MultiView was on a screen or output this second. Returns true when `divider` changed.
    mutating func evaluate(budgetMs: Double, dropped: Int, active: Bool) -> Bool {
        let avg = count > 0 ? sumMs / Double(count) : 0
        sumMs = 0; count = 0
        let old = divider
        if !active {
            divider = 1; calmSeconds = 0
        } else if dropped > 0 || avg > budgetMs * 0.7 {
            divider = min(Self.maxDivider, divider * 2); calmSeconds = 0
        } else if avg < budgetMs * 0.4 && divider > 1 {
            calmSeconds += 1
            // wait a few calm seconds before stepping back up, so it doesn't flip every second
            if calmSeconds >= 5 { divider /= 2; calmSeconds = 0 }
        } else {
            calmSeconds = 0
        }
        return divider != old
    }
}
