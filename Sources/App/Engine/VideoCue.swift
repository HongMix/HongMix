import Foundation
import QuartzCore
import CoreVideo

/// Video Cue: cue-list playback (window "Video Cue", input "Video Cue"). The show logic is CueMachine
/// (VideoCueLogic.swift); this runs its commands on two private decks — plain FFmpeg/Image inputs that are
/// not in the input list, so they are no tiles, not saved and not mixed on their own. The Video Cue input
/// composes the decks (each faded by its level) on the GPU and sums their sound into one mixer channel.
/// Main thread, except `layers` and `pumpAudio` (render thread, under `lock`).
final class VideoCueEngine: ObservableObject {
    static let shared = VideoCueEngine()

    @Published var list = VideoCueList() {
        didSet {
            machine.cues = list.cues
            // picture settings of a cue on air apply at once (the render thread reads its copy under the lock)
            lock.lock()
            for d in 0..<2 { if let c = machine.deckCue[d], list.cues.indices.contains(c) { looks[d] = list.cues[c] } }
            lock.unlock()
            if list.background != oldValue.background { applyBackground() }
            publish()
        }
    }
    @Published private(set) var selected = 0
    @Published private(set) var live: Int?
    @Published private(set) var deckCue: [Int?] = [nil, nil]
    // not @Published: they change 20×/s; the window reads them in its 10×/s TimelineView only
    private(set) var positions: [Double] = [0, 0]
    private(set) var durations: [Double] = [0, 0]

    private var machine = CueMachine(cues: [])
    private let lock = NSLock()
    private var decks: [InputSource?] = [nil, nil]
    private var fades: [Fade?] = [nil, nil]
    private var looks: [VideoCue?] = [nil, nil]  // render thread's copy of each deck's cue (picture, outputs)
    private var background: InputSource?          // the list's fallback picture (under `lock`)
    private var fadeOpen = [false, false]        // a fade whose end the machine hasn't heard yet
    private var wasPlaying = [false, false]
    private var startedAt: [Double] = [0, 0]     // stills: when GO showed them
    private var timer: Timer?
    private let closeQueue = DispatchQueue(label: "videocue.close", qos: .userInitiated)

    // MARK: Actions (window, API)

    func go() { run(machine.go()) }
    func stop() { run(machine.stop()) }
    func panic() { run(machine.panic()) }
    func next() { machine.next(); publish() }
    func previous() { machine.previous(); publish() }
    func select(_ index: Int) { machine.select(index); publish() }

    func add(paths: [String]) { list.cues += paths.map { VideoCue(path: $0) } }

    func remove(at index: Int) {
        // shortcut: the machine counts cues by position, so no removing while a deck holds a cue; ids if reordering comes
        machine.remove(at: index)
        list.cues = machine.cues
    }

    /// Opening a project: its own list, everything off, its first cue next.
    func load(_ new: VideoCueList) {
        let cmds = machine.replaceList(new.cues)
        list = new
        run(cmds)
    }

    /// API: VideoCueGo, VideoCueStop, VideoCuePanic, VideoCueNext, VideoCuePrevious, VideoCueSelect (Value = cue
    /// number), VideoCueAdd (Value = file path), VideoCueBackground. Returns an error text, nil = done.
    func api(_ fn: String, _ value: String) -> String? {
        // the HTTP/TCP API calls in on its own queues; the machine and the decks belong to the main thread
        guard Thread.isMainThread else { return DispatchQueue.main.sync { api(fn, value) } }
        switch fn {
        case "videocuego": go()
        case "videocuestop": stop()
        case "videocuepanic": panic()
        case "videocuenext": next()
        case "videocueprevious": previous()
        case "videocueselect":
            guard let n = Int(value), list.cues.indices.contains(n - 1) else { return "Value=1…\(list.cues.count)" }
            select(n - 1)
        case "videocuebackground":     // Value = none | color,#RRGGBB | image,path | video,path
            let parts = value.split(separator: ",", maxSplits: 1).map(String.init)
            guard let k = parts.first?.lowercased() else { return "Value=none|color,#RRGGBB|image,path|video,path" }
            if k == "none" { list.background = nil; return nil }
            guard parts.count == 2, let kind = CueBackground.Kind(rawValue: k) else { return "Value=none|color,#RRGGBB|image,path|video,path" }
            var b = CueBackground(kind: kind)
            if kind == .color { b.color = parts[1] } else {
                guard FileManager.default.fileExists(atPath: parts[1]) else { return "File not found" }
                b.path = parts[1]
            }
            list.background = b
        case "videocueadd":
            guard !value.isEmpty, FileManager.default.fileExists(atPath: value) else { return "Value=file path" }
            add(paths: [value])
        default: return "Unknown Video Cue function"
        }
        return nil
    }

    /// Remaining seconds of the live cue (nil = nothing live, or a still that holds).
    var remaining: Double? {
        guard let d = live, let c = deckCue[d], list.cues.indices.contains(c) else { return nil }
        let cue = list.cues[c]
        if cue.kind == .still { return cue.stillSeconds > 0 ? max(0, cue.stillSeconds - (CACurrentMediaTime() - startedAt[d])) : nil }
        let end = cue.outPoint > 0 ? cue.outPoint : durations[d]
        return end > 0 ? max(0, end - positions[d]) : nil
    }

    // MARK: Running the machine's commands

    private func run(_ cmds: [DeckCommand]) {
        let now = CACurrentMediaTime()
        for c in cmds {
            switch c {
            case let .load(d, i): load(deck: d, cue: list.cues[i])
            case let .play(d):
                decks[d]?.playing = true
                startedAt[d] = now
                wasPlaying[d] = true
            case let .fade(d, to, seconds):
                lock.lock()
                fades[d] = Fade(from: fades[d]?.level(at: now) ?? 0, to: to, start: now, seconds: seconds)
                lock.unlock()
                fadeOpen[d] = true
            case let .stop(d): close(deck: d)
            }
        }
        if timer == nil {
            let t = Timer(timeInterval: 0.05, repeats: true) { [weak self] _ in self?.tick() }
            RunLoop.main.add(t, forMode: .common)
            timer = t
        }
        publish()
    }

    private func load(deck d: Int, cue: VideoCue) {
        close(deck: d)
        var cfg = InputConfig(kind: cue.kind == .still ? .image : .media, name: "Video Cue \(d + 1)")
        cfg.url = cue.path
        cfg.imagePath = cue.path
        cfg.loop = cue.endAction == .loop
        cfg.markIn = cue.inPoint > 0 ? cue.inPoint : -1
        cfg.markOut = cue.outPoint > 0 ? cue.outPoint : -1
        let deck: InputSource = cue.kind == .still ? ImageInput(config: cfg) : FFmpegInput(config: cfg)
        deck.playing = false                 // opens on its first frame; .play starts it
        deck.start()
        if cue.inPoint > 0 { deck.seek(seconds: cue.inPoint) }   // marks reach the decoder after it opened
        lock.lock(); decks[d] = deck; fades[d] = nil; looks[d] = cue; lock.unlock()
        fadeOpen[d] = false
        wasPlaying[d] = false
        positions[d] = 0; durations[d] = 0
    }

    /// Black and silent at once; the decoder closes off the main thread (it can block).
    private func close(deck d: Int) {
        lock.lock(); let old = decks[d]; decks[d] = nil; fades[d] = nil; looks[d] = nil; lock.unlock()
        fadeOpen[d] = false
        wasPlaying[d] = false
        if let old { closeQueue.async { old.stop() } }
    }

    /// (Re)open the background deck: a colour, a still or a looping silent video.
    private func applyBackground() {
        lock.lock(); let old = background; background = nil; lock.unlock()
        if let old { closeQueue.async { old.stop() } }
        guard let b = list.background else { return }
        let deck: InputSource
        switch b.kind {
        case .color:
            var cfg = InputConfig(kind: .color, name: "Video Cue background"); cfg.color = b.color
            deck = ColorInput(config: cfg)
        case .image:
            guard FileManager.default.fileExists(atPath: b.path) else { return }
            var cfg = InputConfig(kind: .image, name: "Video Cue background"); cfg.imagePath = b.path
            deck = ImageInput(config: cfg)
        case .video:
            guard FileManager.default.fileExists(atPath: b.path) else { return }
            var cfg = InputConfig(kind: .media, name: "Video Cue background"); cfg.url = b.path; cfg.loop = true
            deck = FFmpegInput(config: cfg)
        }
        deck.start()
        lock.lock(); background = deck; lock.unlock()
    }

    /// 20×/s: fade ends, deck positions, early fade-out before the end, end of a cue.
    private func tick() {
        let now = CACurrentMediaTime()
        for d in 0..<2 {
            lock.lock(); let deck = decks[d], fade = fades[d]; lock.unlock()
            if fadeOpen[d], let fade, fade.done(at: now) {
                fadeOpen[d] = false
                run(machine.fadeFinished(deck: d))
            }
            guard let deck, let c = machine.deckCue[d], list.cues.indices.contains(c) else { continue }
            let cue = list.cues[c]
            if cue.kind == .still {
                if let lead = machine.fadeOutLead(deck: d), cue.stillSeconds > 0, now - startedAt[d] >= cue.stillSeconds - lead {
                    run(machine.nearEnd(deck: d))
                }
                if wasPlaying[d], cue.stillSeconds > 0, now - startedAt[d] >= cue.stillSeconds {
                    wasPlaying[d] = false
                    run(machine.deckEnded(deck: d))
                }
                continue
            }
            deck.pollPosition()
            if positions[d] != deck.position { positions[d] = deck.position }
            if durations[d] != deck.duration { durations[d] = deck.duration }
            let end = cue.outPoint > 0 ? cue.outPoint : deck.duration
            if let lead = machine.fadeOutLead(deck: d), end > 0, end - deck.position <= lead {
                run(machine.nearEnd(deck: d))
            }
            if wasPlaying[d] && !deck.playing {          // reached the out point / end of the file
                wasPlaying[d] = false
                run(machine.deckEnded(deck: d))
            }
        }
        // a background video behind a cue that fills the picture at full level isn't seen: don't decode it
        lock.lock(); let bg = background; lock.unlock()
        if let bg, list.background?.kind == .video {
            let covered = (0..<2).contains { d in
                guard decks[d] != nil, let f = fades[d], f.to == 1, f.done(at: now), let c = looks[d] else { return false }
                return c.kind != .audio && c.fit != .fit && c.zoom >= 1 && c.panX == 0 && c.panY == 0
                    && c.cropL + c.cropT + c.cropR + c.cropB == 0
            }
            if bg.playing == covered { bg.playing = !covered }
        }
        if decks.allSatisfy({ $0 == nil }) {
            bg?.playing = true
            timer?.invalidate(); timer = nil
        }
    }

    private func publish() {
        if selected != machine.selected { selected = machine.selected }
        if live != machine.live { live = machine.live }
        if deckCue != machine.deckCue { deckCue = machine.deckCue }
    }

    // MARK: Render thread

    /// One Video Cue output's picture: black, the background, then each deck shown there, at its fade level,
    /// framed by its cue's picture settings.
    func layers(width W: CGFloat, height H: CGFloat, output: UUID) -> [ComposeLayer] {
        let now = CACurrentMediaTime()
        lock.lock(); let ds = decks, fs = fades, ls = looks, bg = background; lock.unlock()
        let full = CGRect(x: 0, y: 0, width: W, height: H)
        var p = LayerParams(); p.premul = 0
        var parts = [ComposeLayer(buffer: Slates.black, params: p, rect: full)]
        if let bg, let buf = bg.video.latest() {
            var bp = LayerParams(); bp.premul = bg.alphaPremultiplied ? 1 : 0; bp.fitMode = 1    // fill
            parts.append(ComposeLayer(buffer: buf, params: bp, rect: full))
        }
        for d in 0..<2 {
            guard let deck = ds[d], let look = ls[d], look.shows(on: output), let buf = deck.video.latest() else { continue }
            let level = fs[d]?.level(at: now) ?? 0
            guard level > 0.001 else { continue }
            var lp = deck.videoAdjust.layerParams(premultiplied: deck.alphaPremultiplied)
            lp.fitMode = Int32(look.fit.rawValue)
            lp.zoom = Float(look.zoom); lp.zoomX = 1; lp.zoomY = 1
            lp.panX = Float(look.panX); lp.panY = Float(look.panY)
            lp.cropL = Float(look.cropL); lp.cropT = Float(look.cropT); lp.cropR = Float(look.cropR); lp.cropB = Float(look.cropB)
            lp.mixAlpha = Float(level)
            parts.append(ComposeLayer(buffer: buf, params: lp, rect: full))
        }
        return parts
    }

    // sized up front (1 s of stereo) so the audio thread doesn't allocate; grows only for a larger block
    private var deckBuf = [[Float]](repeating: [Float](repeating: 0, count: AudioMixer.rate * 2), count: 2)
    private var mixBuf = [Float](repeating: 0, count: AudioMixer.rate * 2)

    /// Each Video Cue output's sound: the decks shown there, each ramped across the block by its fade level.
    /// Always exactly `frames` per ring, silence when idle, so the mixer channels never starve.
    func pumpAudio(into rings: [(output: UUID, ring: AudioRing)], frames: Int) {
        guard frames > 0 else { return }
        let now = CACurrentMediaTime(), dt = Double(frames) / Double(AudioMixer.rate)
        lock.lock(); let ds = decks, fs = fades, ls = looks; lock.unlock()
        if mixBuf.count < frames * 2 {
            mixBuf = [Float](repeating: 0, count: frames * 2)
            deckBuf = [mixBuf, mixBuf]
        }
        var got = [0, 0]
        for d in 0..<2 {      // read each deck once, whatever the number of outputs
            guard let deck = ds[d] else { continue }
            got[d] = deckBuf[d].withUnsafeMutableBufferPointer { deck.audio.read(into: $0.baseAddress!, frames: frames, diagnose: false) }
        }
        for (output, ring) in rings {
            for k in 0..<(frames * 2) { mixBuf[k] = 0 }
            for d in 0..<2 where got[d] > 0 && ls[d]?.shows(on: output) == true {
                let a = Float(fs[d]?.level(at: now) ?? 0), b = Float(fs[d]?.level(at: now + dt) ?? 0)
                guard a > 0 || b > 0 else { continue }
                for k in 0..<got[d] {
                    let g = a + (b - a) * Float(k) / Float(frames)
                    mixBuf[2 * k] += deckBuf[d][2 * k] * g
                    mixBuf[2 * k + 1] += deckBuf[d][2 * k + 1] * g
                }
            }
            mixBuf.withUnsafeBufferPointer { ring.write($0.baseAddress!, frames: frames) }
        }
    }
}

/// The switcher input "Video Cue": shows and sounds whatever the cue list plays.
final class VideoCueInput: InputSource {
    override func start() { postStatus(Int32(MC_STATE_RUNNING), "Video Cue") }
    override func stop() {
        video.clear()
        audio.clear()
    }
}
