import Foundation

/// MultiLayout (SuperSource-style boxes, MultiLayout.swift): the parts without AppKit/engine, so tests/multilayout can run them.

/// A rectangle on the output, normalised 0…1 from the top-left.
struct MLRect: Codable, Equatable {
    var x: Double, y: Double, w: Double, h: Double

    static let full = MLRect(x: 0, y: 0, w: 1, h: 1)

    func lerp(to b: MLRect, _ t: Double) -> MLRect {
        MLRect(x: x + (b.x - x) * t, y: y + (b.y - y) * t, w: w + (b.w - w) * t, h: h + (b.h - h) * t)
    }
}

/// How a box comes in (and goes out) when a scene shows it (or no longer does).
enum MLAppear: String, Codable, CaseIterable { case fly, grow, fade, cut }

/// One box in a scene: where it is and whether it shows. The input normally comes from the box (MLBox);
/// a scene may show another input in it.
struct MLSceneBox: Codable, Equatable {
    var visible = false
    var rect = MLRect(x: 0.25, y: 0.25, w: 0.5, h: 0.5)
    var input: UUID? = nil

    init(visible: Bool = false, rect: MLRect = MLRect(x: 0.25, y: 0.25, w: 0.5, h: 0.5), input: UUID? = nil) {
        self.visible = visible; self.rect = rect; self.input = input
    }

    private enum K: String, CodingKey { case visible, rect, input }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: K.self)
        visible = (try? c.decode(Bool.self, forKey: .visible)) ?? false
        rect = (try? c.decode(MLRect.self, forKey: .rect)) ?? MLRect(x: 0.25, y: 0.25, w: 0.5, h: 0.5)
        input = try? c.decode(UUID.self, forKey: .input)
    }
}

/// A box's look and input; the same in every scene (box 1 is box 1 everywhere).
struct MLBox: Codable, Equatable {
    var inputID: UUID? = nil
    var fill = true                         // true: crop to fill the box; false: fit inside
    var border = 0.0                        // px at output size
    var borderColor = "#FFFFFF"
    var radius = 0.0                        // rounded corners, px at output size
    var zoom = 1.0                          // ≥ 1, inside the box
    var panX = 0.0, panY = 0.0              // -1…1: which part of the zoomed picture shows
    var cropL = 0.0, cropT = 0.0, cropR = 0.0, cropB = 0.0

    init() {}

    private enum K: String, CodingKey { case inputID, fill, border, borderColor, radius, zoom, panX, panY, cropL, cropT, cropR, cropB }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: K.self)
        inputID = try? c.decode(UUID.self, forKey: .inputID)
        fill = (try? c.decode(Bool.self, forKey: .fill)) ?? true
        border = (try? c.decode(Double.self, forKey: .border)) ?? 0
        borderColor = (try? c.decode(String.self, forKey: .borderColor)) ?? "#FFFFFF"
        radius = (try? c.decode(Double.self, forKey: .radius)) ?? 0
        zoom = (try? c.decode(Double.self, forKey: .zoom)) ?? 1
        panX = (try? c.decode(Double.self, forKey: .panX)) ?? 0
        panY = (try? c.decode(Double.self, forKey: .panY)) ?? 0
        cropL = (try? c.decode(Double.self, forKey: .cropL)) ?? 0
        cropT = (try? c.decode(Double.self, forKey: .cropT)) ?? 0
        cropR = (try? c.decode(Double.self, forKey: .cropR)) ?? 0
        cropB = (try? c.decode(Double.self, forKey: .cropB)) ?? 0
    }
}

/// A scene: where each box is, and how the change to it animates.
struct MLScene: Codable, Equatable, Identifiable {
    static let boxCount = 8

    var id = UUID()
    var name: String
    var boxes = Array(repeating: MLSceneBox(), count: MLScene.boxCount)

    /// The visible box under a point (0…1 of the picture), the top one when boxes overlap (later = on top).
    func box(atX x: Double, y: Double) -> Int? {
        boxes.indices.reversed().first { k in
            let b = boxes[k]
            return b.visible && x >= b.rect.x && x <= b.rect.x + b.rect.w && y >= b.rect.y && y <= b.rect.y + b.rect.h
        }
    }
    var seconds = 0.5                       // 0 = cut
    var appear = MLAppear.fly

    init(name: String) { self.name = name }

    private enum K: String, CodingKey { case id, name, boxes, seconds, appear }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: K.self)
        id = (try? c.decode(UUID.self, forKey: .id)) ?? UUID()
        name = (try? c.decode(String.self, forKey: .name)) ?? ""
        var b = (try? c.decode([MLSceneBox].self, forKey: .boxes)) ?? []
        b = Array(b.prefix(MLScene.boxCount))
        b += Array(repeating: MLSceneBox(), count: MLScene.boxCount - b.count)
        boxes = b
        seconds = (try? c.decode(Double.self, forKey: .seconds)) ?? 0.5
        appear = (try? c.decode(MLAppear.self, forKey: .appear)) ?? .fly
    }
}

/// Everything of one MultiLayout input (saved with the input).
struct MultiLayoutSettings: Codable, Equatable {
    var boxes = Array(repeating: MLBox(), count: MLScene.boxCount)
    var scenes: [MLScene] = []
    var scene = 0                            // the scene on air
    var inputFade = 0.3                      // a box changing input crossfades (0 = cut)
    var background = MLBackground()
    var foregroundPath = ""                  // a PNG with transparency drawn over the boxes (frame, logo, lower third)
    var animateOnAir = false                 // going on air plays the live scene's way in (enter(from:))

    init() {}

    /// A new MultiLayout: a few scenes to start from (box 1 and 2 are the same inputs in each).
    static var starter: MultiLayoutSettings {
        var s = MultiLayoutSettings()
        func make(_ name: String, _ p: MLPreset) -> MLScene { var sc = MLScene(name: name); sc.apply(p.rects); return sc }
        s.scenes = [make(L("나란히"), .sideBySide), make(L("전체 화면"), .full), make("PIP", .pipBR), make(L("4분할"), .quad)]
        return s
    }

    private enum K: String, CodingKey { case boxes, scenes, scene, inputFade, background, foregroundPath, animateOnAir }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: K.self)
        var b = (try? c.decode([MLBox].self, forKey: .boxes)) ?? []
        b = Array(b.prefix(MLScene.boxCount))
        boxes = b + Array(repeating: MLBox(), count: MLScene.boxCount - b.count)
        scenes = (try? c.decode([MLScene].self, forKey: .scenes)) ?? []
        scene = (try? c.decode(Int.self, forKey: .scene)) ?? 0
        inputFade = (try? c.decode(Double.self, forKey: .inputFade)) ?? 0.3
        background = (try? c.decode(MLBackground.self, forKey: .background)) ?? MLBackground()
        foregroundPath = (try? c.decode(String.self, forKey: .foregroundPath)) ?? ""
        animateOnAir = (try? c.decode(Bool.self, forKey: .animateOnAir)) ?? false
    }
}

/// Behind the boxes: a colour, a picture, or another input (a looping video, a camera, a title …).
struct MLBackground: Codable, Equatable {
    enum Kind: String, Codable, CaseIterable { case color, image, input }
    var kind = Kind.color
    var color = "#101014"
    var path = ""
    var inputID: UUID? = nil
}

/// An own layout in the shared library (Application Support), usable in any MultiLayout.
struct MLLayout: Codable, Equatable, Identifiable {
    var id = UUID()
    var name: String
    var rects: [MLRect]
}

/// One box as drawn at a moment: which input, where, how visible. Two entries for the same box while
/// its input crossfades (the old one first, under the new one).
struct MLBoxFrame: Equatable {
    var box: Int
    var input: UUID?
    var rect: MLRect
    var opacity = 1.0
    /// 0 = the box's own look (border, corners, zoom, crop), 1 = the plain input as it is on Program
    /// (going from / to full screen on air, so the cut doesn't jump).
    var plain = 0.0
}

/// Ease in and out (cubic): slow start, slow arrival.
func mlEase(_ t: Double) -> Double {
    let p = min(1, max(0, t))
    return p < 0.5 ? 4 * p * p * p : 1 - pow(-2 * p + 2, 3) / 2
}

/// Plays the scenes of a MultiLayout: taking a scene animates every box from where it is now.
struct MLPlayer {
    var settings: MultiLayoutSettings
    /// Where the boxes were when the current change started (nil = not shown).
    private var from: [MLBoxFrame?] = Array(repeating: nil, count: MLScene.boxCount)
    private var to: MLScene?
    private var start = 0.0
    private var instant = false
    /// A box drawn above the others (the one growing to full screen when leaving air).
    private var top: Int?
    /// Per box: the input it showed before its input changed, and when (for the crossfade).
    private var inputWas: [(input: UUID?, at: Double)?] = Array(repeating: nil, count: MLScene.boxCount)

    init(settings: MultiLayoutSettings) { self.settings = settings }

    mutating func take(scene index: Int, at t: Double) {
        guard settings.scenes.indices.contains(index) else { return }
        let now = boxes(at: t)
        from = (0..<MLScene.boxCount).map { k in now[k] }
        instant = to == nil                     // the first scene is simply there
        top = nil
        to = settings.scenes[index]
        settings.scene = index
        start = t
        for k in 0..<MLScene.boxCount { noteInputChange(box: k, was: now[k], at: t) }
    }

    /// Give a box another input (in every scene that doesn't choose its own for that box).
    mutating func setInput(_ id: UUID?, box k: Int, at t: Double) {
        guard settings.boxes.indices.contains(k) else { return }
        let now = boxes(at: t)
        settings.boxes[k].inputID = id
        noteInputChange(box: k, was: now[k], at: t)
    }

    /// The MultiLayout goes on air after `input` (Cut / transition): the box showing that input starts full
    /// screen and moves to its place, the other boxes come in the live scene's way.
    mutating func enter(from input: UUID?, at t: Double) {
        if settings.scenes.indices.contains(settings.scene) { to = settings.scenes[settings.scene] }   // after an exit
        top = nil
        guard let to else { return }
        from = (0..<MLScene.boxCount).map { k in
            let b = to.boxes[k]
            guard b.visible, let input, (b.input ?? settings.boxes[k].inputID) == input else { return nil }
            return MLBoxFrame(box: k, input: input, rect: .full, plain: 1)
        }
        instant = false
        start = t
    }

    /// The switcher leaves this MultiLayout for `input`: if a box of the live scene shows it, that box grows
    /// to full screen on top and the others go (the scene's way). Returns how long that takes (then the
    /// switcher cuts), or nil when no box shows the input.
    mutating func exit(to input: UUID?, at t: Double) -> Double? {
        guard let input, settings.scenes.indices.contains(settings.scene) else { return nil }
        let live = settings.scenes[settings.scene]
        guard let k = (0..<MLScene.boxCount).first(where: { live.boxes[$0].visible && (live.boxes[$0].input ?? settings.boxes[$0].inputID) == input })
        else { return nil }
        var out = live
        for j in 0..<MLScene.boxCount where j != k { out.boxes[j].visible = false }
        out.boxes[k].rect = .full
        from = boxes(at: t)
        to = out
        top = k
        instant = false
        start = t
        return live.seconds
    }

    /// Back to the live scene at once (an exit whose switch didn't happen, or the MultiLayout left Program).
    mutating func restoreLive(at t: Double) {
        guard settings.scenes.indices.contains(settings.scene) else { return }
        to = settings.scenes[settings.scene]
        from = Array(repeating: nil, count: MLScene.boxCount)
        top = nil
        instant = true
        inputWas = Array(repeating: nil, count: MLScene.boxCount)
    }

    /// New settings from the editor. The live scene's new places show at once (no animation while
    /// dragging); a box that now shows another input crossfades.
    mutating func edit(_ new: MultiLayoutSettings, at t: Double) {
        let now = boxes(at: t)
        settings = new
        guard settings.scenes.indices.contains(settings.scene) else { return }
        if to == nil { restoreLive(at: t); return }          // e.g. the first scene added to an empty list
        let live = settings.scenes[settings.scene]
        if live != to {
            from = now
            to = live
            instant = true
        }
        for k in 0..<MLScene.boxCount { noteInputChange(box: k, was: now[k], at: t) }
    }

    private mutating func noteInputChange(box k: Int, was: MLBoxFrame?, at t: Double) {
        guard let was, let to, to.boxes[k].visible else { return }
        let input = to.boxes[k].input ?? settings.boxes[k].inputID
        if input != was.input { inputWas[k] = (was.input, t) }
    }

    func frames(at t: Double) -> [MLBoxFrame] {
        var out: [MLBoxFrame] = []
        var all = boxes(at: t)
        if let top, let f = all[top] { all.remove(at: top); all.append(f) }
        for f in all {
            guard let f else { continue }
            if let w = inputWas[f.box], w.input != f.input, settings.inputFade > 0, t - w.at < settings.inputFade {
                var old = f; old.input = w.input
                var new = f; new.opacity = f.opacity * max(0, t - w.at) / settings.inputFade
                out += [old, new]
            } else {
                out.append(f)
            }
        }
        return out
    }


    private func boxes(at t: Double) -> [MLBoxFrame?] {
        guard let to else { return Array(repeating: nil, count: MLScene.boxCount) }
        let p = to.seconds > 0 && !instant ? mlEase((t - start) / to.seconds) : 1
        return (0..<MLScene.boxCount).map { k in
            let b = to.boxes[k], was = from[k]
            if b.visible {
                let input = b.input ?? settings.boxes[k].inputID
                let plain = k == top ? 1.0 : 0.0
                let start = was ?? MLPlayer.hidden(b.rect, to.appear)
                guard let start, p < 1 else { return MLBoxFrame(box: k, input: input, rect: b.rect, plain: plain) }
                return MLBoxFrame(box: k, input: input, rect: start.rect.lerp(to: b.rect, p),
                                  opacity: start.opacity + (1 - start.opacity) * p,
                                  plain: start.plain + (plain - start.plain) * p)
            }
            guard let was, p < 1, let end = MLPlayer.hidden(was.rect, to.appear) else { return nil }
            return MLBoxFrame(box: k, input: was.input, rect: was.rect.lerp(to: end.rect, p),
                              opacity: was.opacity + (end.opacity - was.opacity) * p)
        }
    }

    /// Where (and how visible) a box at `r` is just before it comes in / just after it went: off the
    /// nearest edge, a point at its centre, or in place but transparent. nil = it simply cuts.
    static func hidden(_ r: MLRect, _ how: MLAppear) -> MLBoxFrame? {
        switch how {
        case .cut: return nil
        case .fade: return MLBoxFrame(box: 0, input: nil, rect: r, opacity: 0)
        case .grow: return MLBoxFrame(box: 0, input: nil, rect: MLRect(x: r.x + r.w / 2, y: r.y + r.h / 2, w: 0, h: 0))
        case .fly:
            let cx = r.x + r.w / 2, cy = r.y + r.h / 2
            let d = [cx, 1 - cx, cy, 1 - cy]                    // left, right, top, bottom
            var o = r
            switch d.firstIndex(of: d.min()!)! {
            case 0: o.x = -r.w
            case 1: o.x = 1
            case 2: o.y = -r.h
            default: o.y = 1
            }
            return MLBoxFrame(box: 0, input: nil, rect: o)
        }
    }
}

extension MLScene {
    /// Put the first boxes on a layout's places and hide the others (inputs and animation stay).
    mutating func apply(_ rects: [MLRect]) {
        for k in 0..<MLScene.boxCount {
            boxes[k].visible = k < rects.count
            if k < rects.count { boxes[k].rect = rects[k] }
        }
    }
}

/// Ready-made layouts (SuperSource / H2R style). Gaps are 2 % of the width; boxes for cameras are 16:9.
enum MLPreset: String, CaseIterable, Identifiable {
    case full, sideBySide, split2, threeUp, quad, onePlus2, onePlus3, sixGrid, eightGrid, pipBR, pipBL, twoPip
    var id: String { rawValue }

    static let gap = 0.02

    /// The places, box 1 first (output assumed 16:9: a 16:9 box has equal width and height fractions).
    var rects: [MLRect] {
        let g = MLPreset.gap, gy = g * 16 / 9
        func grid(_ cols: Int, _ rows: Int) -> [MLRect] {
            let w = (1 - g * Double(cols + 1)) / Double(cols), h = (1 - gy * Double(rows + 1)) / Double(rows)
            return (0..<rows).flatMap { r in (0..<cols).map { c in
                MLRect(x: g + Double(c) * (w + g), y: gy + Double(r) * (h + gy), w: w, h: h) } }
        }
        func row(_ n: Int) -> [MLRect] {                    // n 16:9 boxes side by side, centred
            let w = (1 - g * Double(n + 1)) / Double(n), y = (1 - w) / 2
            return (0..<n).map { MLRect(x: g + Double($0) * (w + g), y: y, w: w, h: w) }
        }
        switch self {
        case .full: return [.full]
        case .sideBySide: return row(2)
        case .split2:
            let w = (1 - 3 * g) / 2
            return [MLRect(x: g, y: gy, w: w, h: 1 - 2 * gy), MLRect(x: 2 * g + w, y: gy, w: w, h: 1 - 2 * gy)]
        case .threeUp: return row(3)
        case .quad: return grid(2, 2)
        case .onePlus2:                                     // big 16:9 left, two stacked right
            let s = (1 - 3 * gy) / 2, bw = 1 - 3 * g - s
            return [MLRect(x: g, y: (1 - bw) / 2, w: bw, h: bw),
                    MLRect(x: 2 * g + bw, y: gy, w: s, h: s), MLRect(x: 2 * g + bw, y: 2 * gy + s, w: s, h: s)]
        case .onePlus3:
            let s = (1 - 4 * gy) / 3, bw = 1 - 3 * g - s
            return [MLRect(x: g, y: gy, w: bw, h: 1 - 2 * gy)] +
                (0..<3).map { MLRect(x: 2 * g + bw, y: gy + Double($0) * (s + gy), w: s, h: s) }
        case .sixGrid: return grid(3, 2)
        case .eightGrid: return grid(4, 2)
        case .pipBR: return [.full, MLRect(x: 0.66, y: 0.66, w: 0.3, h: 0.3)]
        case .pipBL: return [.full, MLRect(x: 0.04, y: 0.66, w: 0.3, h: 0.3)]
        case .twoPip: return [.full, MLRect(x: 0.04, y: 0.62, w: 0.32, h: 0.32), MLRect(x: 0.64, y: 0.62, w: 0.32, h: 0.32)]
        }
    }
}
