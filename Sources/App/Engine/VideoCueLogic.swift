import Foundation

/// Video Cue (cue-list playback, VideoCue.swift): the parts without AppKit/engine, so tests/videocue can run them.

/// One line of the cue list.
struct VideoCue: Codable, Identifiable, Equatable {
    enum Kind: String, Codable { case video, still, audio }
    /// What happens when the cue reaches its out point.
    enum EndAction: String, Codable, CaseIterable { case hold, black, loop, next }

    var id = UUID()
    var path: String
    var name = ""
    var kind: Kind
    var inPoint = 0.0           // seconds
    var outPoint = 0.0          // seconds, 0 = end of file
    var fadeIn = 0.0            // seconds, picture and sound together
    var fadeOut = 0.0
    var endAction = EndAction.hold
    var stillSeconds = 0.0      // stills: 0 = until the next GO
    // picture: same meaning as an input's position settings
    enum Fit: Int, Codable, CaseIterable { case fit, fill, stretch }
    var fit = Fit.fit
    var zoom = 1.0
    var panX = 0.0, panY = 0.0                          // -2…2
    var cropL = 0.0, cropT = 0.0, cropR = 0.0, cropB = 0.0  // 0…0.9 of the picture
    /// Video Cue outputs this cue is left off (empty = shows everywhere, also on outputs added later).
    var hiddenOn: [UUID] = []

    func shows(on output: UUID) -> Bool { !hiddenOn.contains(output) }

    init(path: String) {
        self.path = path
        kind = VideoCue.kind(of: path)
    }

    private enum K: String, CodingKey { case id, path, name, kind, inPoint, outPoint, fadeIn, fadeOut, endAction, stillSeconds,
                                        fit, zoom, panX, panY, cropL, cropT, cropR, cropB, hiddenOn }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: K.self)
        path = try c.decode(String.self, forKey: .path)
        kind = (try? c.decode(Kind.self, forKey: .kind)) ?? VideoCue.kind(of: path)
        id = (try? c.decode(UUID.self, forKey: .id)) ?? UUID()
        name = (try? c.decode(String.self, forKey: .name)) ?? ""
        inPoint = (try? c.decode(Double.self, forKey: .inPoint)) ?? 0
        outPoint = (try? c.decode(Double.self, forKey: .outPoint)) ?? 0
        fadeIn = (try? c.decode(Double.self, forKey: .fadeIn)) ?? 0
        fadeOut = (try? c.decode(Double.self, forKey: .fadeOut)) ?? 0
        endAction = (try? c.decode(EndAction.self, forKey: .endAction)) ?? .hold
        stillSeconds = (try? c.decode(Double.self, forKey: .stillSeconds)) ?? 0
        fit = (try? c.decode(Fit.self, forKey: .fit)) ?? .fit
        zoom = (try? c.decode(Double.self, forKey: .zoom)) ?? 1
        panX = (try? c.decode(Double.self, forKey: .panX)) ?? 0
        panY = (try? c.decode(Double.self, forKey: .panY)) ?? 0
        cropL = (try? c.decode(Double.self, forKey: .cropL)) ?? 0
        cropT = (try? c.decode(Double.self, forKey: .cropT)) ?? 0
        cropR = (try? c.decode(Double.self, forKey: .cropR)) ?? 0
        cropB = (try? c.decode(Double.self, forKey: .cropB)) ?? 0
        hiddenOn = (try? c.decode([UUID].self, forKey: .hiddenOn)) ?? []
    }

    var displayName: String {
        name.isEmpty ? ((path as NSString).lastPathComponent as NSString).deletingPathExtension : name
    }

    static func kind(of path: String) -> Kind {
        switch (path as NSString).pathExtension.lowercased() {
        case "png", "jpg", "jpeg", "heic", "tif", "tiff", "gif", "bmp", "webp": return .still
        case "mp3", "wav", "aif", "aiff", "m4a", "aac", "flac", "caf", "ogg": return .audio
        default: return .video
        }
    }
}

/// The project's cue list (saved in the project file).
struct VideoCueList: Codable, Equatable {
    var cues: [VideoCue] = []
    /// What shows when no cue does (nil = black).
    var background: CueBackground? = nil
}

/// The list's fallback picture: a colour, a still or a looping video (silent).
struct CueBackground: Codable, Equatable {
    enum Kind: String, Codable, CaseIterable { case color, image, video }
    var kind = Kind.color
    var color = "#000000"
    var path = ""
}

/// A linear fade of one deck's level (opacity and volume), on a seconds clock.
struct Fade: Equatable {
    var from: Double, to: Double, start: Double, seconds: Double

    func level(at t: Double) -> Double {
        guard seconds > 0 else { return to }
        let p = min(1, max(0, (t - start) / seconds))
        return from + (to - from) * p
    }

    func done(at t: Double) -> Bool { t >= start + seconds }
}

/// What the playback engine must do with its two decks.
enum DeckCommand: Equatable {
    case load(deck: Int, cue: Int)                    // open the cue's file at its in point, paused
    case play(deck: Int)
    case fade(deck: Int, to: Double, seconds: Double) // level = opacity and volume
    case stop(deck: Int)                              // close at once: black and silent
}

/// The show logic of the cue list: GO / STOP / PANIC / end of a cue → deck commands.
/// Two decks: the live cue and the one fading out, so a GO can crossfade into the next cue.
struct CueMachine {
    var cues: [VideoCue]
    /// The cue the next GO starts (cues.count = past the last one).
    private(set) var selected = 0
    /// The deck whose cue is on (nil = nothing, or fading out after STOP).
    private(set) var live: Int?
    /// Which cue each deck holds.
    private(set) var deckCue: [Int?] = [nil, nil]

    init(cues: [VideoCue]) { self.cues = cues }

    mutating func go() -> [DeckCommand] {
        guard cues.indices.contains(selected) else { return [] }
        let deck = live.map { 1 - $0 } ?? (deckCue[0] == nil ? 0 : 1)
        let c = cues[selected]
        var out: [DeckCommand] = deckCue[deck] == nil ? [] : [.stop(deck: deck)]       // still fading out: cut it
        out += [.load(deck: deck, cue: selected), .play(deck: deck), .fade(deck: deck, to: 1, seconds: c.fadeIn)]
        if let old = live { out.append(.fade(deck: old, to: 0, seconds: c.fadeIn)) }     // crossfade
        deckCue[deck] = selected
        live = deck
        selected += 1
        return out
    }

    mutating func stop() -> [DeckCommand] {
        guard let d = live, let c = deckCue[d] else { return [] }
        live = nil
        return [.fade(deck: d, to: 0, seconds: cues.indices.contains(c) ? cues[c].fadeOut : 0)]
    }

    /// Everything off at once: black and silent. The selection stays.
    mutating func panic() -> [DeckCommand] {
        let out = (0..<2).filter { deckCue[$0] != nil }.map { DeckCommand.stop(deck: $0) }
        deckCue = [nil, nil]
        live = nil
        return out
    }

    mutating func next() { selected = min(cues.count, selected + 1) }
    mutating func previous() { selected = max(0, min(cues.count, selected) - 1) }
    mutating func select(_ index: Int) { if cues.indices.contains(index) { selected = index } }

    /// Another project's list: everything off, its first cue next (the old cue numbers mean nothing in it).
    mutating func replaceList(_ new: [VideoCue]) -> [DeckCommand] {
        let out = panic()
        cues = new
        selected = 0
        return out
    }

    /// Delete a cue (only while no deck holds one: decks refer to cues by position). The same cue stays next.
    mutating func remove(at index: Int) {
        guard cues.indices.contains(index), deckCue == [nil, nil] else { return }
        cues.remove(at: index)
        if index < selected { selected -= 1 }
    }

    private func liveCue(_ deck: Int) -> VideoCue? {
        guard deck == live, let c = deckCue[deck], cues.indices.contains(c) else { return nil }
        return cues[c]
    }

    /// Seconds before its out point at which the live cue on `deck` must start fading out (end action "black").
    func fadeOutLead(deck: Int) -> Double? {
        guard let c = liveCue(deck), c.endAction == .black, c.fadeOut > 0 else { return nil }
        return c.fadeOut
    }

    /// The engine reached `fadeOutLead` before the out point.
    mutating func nearEnd(deck: Int) -> [DeckCommand] {
        fadeOutLead(deck: deck) == nil ? [] : stop()
    }

    /// The cue on `deck` reached its out point (or a still its time).
    mutating func deckEnded(deck: Int) -> [DeckCommand] {
        guard let c = liveCue(deck) else { return [] }
        switch c.endAction {
        case .hold, .loop: return []
        case .next: return go()
        case .black:
            live = nil
            deckCue[deck] = nil
            return [.stop(deck: deck)]
        }
    }

    /// The engine finished a fade on `deck`. A deck that faded out (not the live one) is closed.
    mutating func fadeFinished(deck: Int) -> [DeckCommand] {
        guard deck != live, deckCue[deck] != nil else { return [] }
        deckCue[deck] = nil
        return [.stop(deck: deck)]
    }
}
