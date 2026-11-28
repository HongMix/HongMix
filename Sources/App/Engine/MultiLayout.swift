import Foundation
import CoreVideo
import QuartzCore

/// MultiLayout (ATEM SuperSource / H2R Layouts / Superbox): up to 8 boxes, each showing an input, over a
/// background, with a foreground picture on top. Scenes place the boxes; taking a scene animates them.
/// Built on the layer system like Virtual Set:
///   * the input's own frame is the background colour or picture (drawn once at output size);
///   * `layersSnapshot` returns the boxes as layers, computed for this moment by MLPlayer (so the
///     engine's composeLayers draws the animation; a still layout is reused from the compose cache);
///   * the foreground picture is drawn last, full frame, through `topOverlayFrame`.
final class MultiLayoutInput: InputSource {
    @Published var multiLayout: MultiLayoutSettings {
        didSet {
            guard multiLayout != oldValue else { return }
            mlLock.lock(); player.edit(multiLayout, at: CACurrentMediaTime()); mlLock.unlock()
            if multiLayout.background != oldValue.background || multiLayout.foregroundPath != oldValue.foregroundPath {
                loadImages()
            }
        }
    }
    private let mlLock = NSLock()
    private var player: MLPlayer
    private var foregroundStore: CVPixelBuffer?
    private var rateObserver: NSObjectProtocol?
    private let loadQueue = DispatchQueue(label: "hongmix.multilayout.load", qos: .userInitiated)
    private var loadGeneration = 0
    private var imageError: String?

    override var alphaPremultiplied: Bool { true }
    /// Engine hook: a scene take replaces a pending exit (switching away animation).
    static var cancelExit: (() -> Void)?

    override init(config: InputConfig) {
        multiLayout = config.multiLayout
        player = MLPlayer(settings: config.multiLayout)
        super.init(config: config)
        player.take(scene: multiLayout.scene, at: CACurrentMediaTime())
    }

    override var layersSnapshot: [InputLayer] {
        let t = CACurrentMediaTime()
        mlLock.lock(); let frames = player.frames(at: t); let s = player.settings; mlLock.unlock()
        var out: [InputLayer] = []
        if s.background.kind == .input, let b = s.background.inputID, b != id {
            out.append(InputLayer(inputID: b, x: 0, y: 0, w: 1, h: 1, fill: true))
        }
        for f in frames {
            guard let input = f.input, input != id, f.rect.w > 0.001, f.rect.h > 0.001 else { continue }
            out.append(MultiLayoutInput.layer(f, s.boxes[f.box]))
        }
        return out + super.layersSnapshot
    }

    /// One box as a layer: zoom and pan inside the box become a crop of the (already cropped) picture.
    static func layer(_ f: MLBoxFrame, _ b: MLBox) -> InputLayer {
        var l = InputLayer(inputID: f.input, x: f.rect.x, y: f.rect.y, w: f.rect.w, h: f.rect.h, fill: b.fill)
        var b = b
        if f.plain > 0 {                                 // towards the plain input (to / from full screen on air)
            let k = 1 - min(1, f.plain)
            b.zoom = 1 + (b.zoom - 1) * k; b.panX *= k; b.panY *= k
            b.cropL *= k; b.cropT *= k; b.cropR *= k; b.cropB *= k
            b.border *= k; b.radius *= k
        }
        let z = max(1, b.zoom)
        let cw = max(0.01, 1 - b.cropL - b.cropR), ch = max(0.01, 1 - b.cropT - b.cropB)
        let sx = (cw - cw / z) / 2, sy = (ch - ch / z) / 2          // what zoom takes off each side
        let px = min(1, max(-1, b.panX)), py = min(1, max(-1, b.panY))
        l.cropL = Float(b.cropL + sx * (1 + px)); l.cropR = Float(b.cropR + sx * (1 - px))
        l.cropT = Float(b.cropT + sy * (1 + py)); l.cropB = Float(b.cropB + sy * (1 - py))
        l.border = b.border
        l.borderColor = b.borderColor
        l.radius = b.radius
        l.opacity = Float(min(1, max(0, f.opacity)))
        return l
    }

    override var topOverlayFrame: CVPixelBuffer? {
        mlLock.lock(); defer { mlLock.unlock() }
        return foregroundStore
    }

    // MARK: control (main thread)

    /// The scene on air (index into scenes).
    var liveScene: Int { multiLayout.scene }

    /// Take a scene: the boxes animate to it (its own length and way in / out).
    func take(scene index: Int) {
        guard multiLayout.scenes.indices.contains(index) else { return }
        MultiLayoutInput.cancelExit?()
        mlLock.lock(); player.take(scene: index, at: CACurrentMediaTime()); let s = player.settings; mlLock.unlock()
        multiLayout = s                        // didSet: edit() sees the live scene unchanged — no jump
    }

    /// Going on Program after `input`: its box grows out of the full screen, the others come in.
    func enterAir(from input: UUID?) {
        guard multiLayout.animateOnAir else { return }
        mlLock.lock(); player.enter(from: input, at: CACurrentMediaTime()); mlLock.unlock()
    }

    /// Program leaves for `input`: its box grows to full screen first. Returns the seconds to wait before
    /// switching (nil = switch at once).
    func exitAir(to input: UUID?) -> Double? {
        guard multiLayout.animateOnAir else { return nil }
        mlLock.lock(); defer { mlLock.unlock() }
        return player.exit(to: input, at: CACurrentMediaTime())
    }

    /// Back to the live scene at once (after an exit, or when an exit's switch didn't happen).
    func restoreLive() {
        mlLock.lock(); player.restoreLive(at: CACurrentMediaTime()); mlLock.unlock()
    }

    /// Replace the settings in one go; `animateLive` takes the (new) live scene with its animation.
    func apply(_ m: MultiLayoutSettings, animateLive: Bool) {
        mlLock.lock()
        if animateLive { player.settings = m; player.take(scene: m.scene, at: CACurrentMediaTime()) }   // from where the boxes are
        else { player.edit(m, at: CACurrentMediaTime()) }
        let s = player.settings
        mlLock.unlock()
        multiLayout = s
    }

    func next() { take(scene: min(multiLayout.scenes.count - 1, multiLayout.scene + 1)) }
    func previous() { take(scene: max(0, multiLayout.scene - 1)) }

    /// Give box `k` another input (crossfades).
    func setInput(_ input: UUID?, box k: Int) {
        guard multiLayout.boxes.indices.contains(k) else { return }
        multiLayout.boxes[k].inputID = input
    }

    /// Show or hide box `k` in the live scene, animated like a scene change.
    func setBox(_ k: Int, visible: Bool) {
        guard multiLayout.scenes.indices.contains(multiLayout.scene), (0..<MLScene.boxCount).contains(k) else { return }
        var s = multiLayout
        guard s.scenes[s.scene].boxes[k].visible != visible else { return }
        s.scenes[s.scene].boxes[k].visible = visible
        mlLock.lock(); player.settings = s; player.take(scene: s.scene, at: CACurrentMediaTime()); mlLock.unlock()
        multiLayout = s
    }

    /// Inputs shown in a box of the live scene (tally, Input list badges).
    var shownInputs: Set<UUID> {
        mlLock.lock(); defer { mlLock.unlock() }
        return Set(player.frames(at: CACurrentMediaTime()).compactMap(\.input))
    }

    // MARK: life cycle

    override func currentConfig() -> InputConfig {
        var c = super.currentConfig()
        c.multiLayout = multiLayout
        return c
    }

    override func start() {
        if rateObserver == nil {
            rateObserver = NotificationCenter.default.addObserver(forName: .hongMixRateConformChanged, object: nil,
                                                                  queue: .main) { [weak self] _ in self?.loadImages() }
        }
        loadImages()
    }

    override func stop() {
        if let o = rateObserver { NotificationCenter.default.removeObserver(o); rateObserver = nil }
    }

    /// Background (colour or picture) and foreground picture at output size (off the main thread).
    private func loadImages() {
        loadGeneration += 1
        let gen = loadGeneration, v = multiLayout, size = SlideOutput.size
        loadQueue.async { [weak self] in
            guard let self else { return }
            var error: String?
            var bg: CVPixelBuffer?
            if let pool = PixelBufferFactory.makePool(width: Int(size.width), height: Int(size.height), minimumCount: 1),
               let pb = PixelBufferFactory.makeBuffer(pool: pool) {
                let path = (v.background.path as NSString).expandingTildeInPath
                let img = v.background.kind == .image && !path.isEmpty ? SlideImage.decode(path, target: size, fill: true) : nil
                if v.background.kind == .image && !path.isEmpty && img == nil { error = L("배경 이미지를 열 수 없음") }
                let clear = v.background.kind == .color ? HexColor.cgColor(v.background.color, fallback: CGColor(gray: 0, alpha: 1))
                                                         : CGColor(gray: 0, alpha: 1)
                SlidePixels.draw(pb, clear: clear) { ctx, sz in
                    if let img { ctx.draw(img, in: SlideGeometry.fit(CGSize(width: img.width, height: img.height), in: sz, fill: true)) }
                }
                bg = pb
            }
            var fg: CVPixelBuffer?
            let fpath = (v.foregroundPath as NSString).expandingTildeInPath
            if !fpath.isEmpty {
                if let img = SlideImage.decode(fpath, target: size, fill: true),
                   let fpool = PixelBufferFactory.makePool(width: Int(size.width), height: Int(size.height), minimumCount: 1),
                   let pb = PixelBufferFactory.makeBuffer(pool: fpool) {
                    SlidePixels.draw(pb, clear: nil) { ctx, sz in
                        ctx.draw(img, in: SlideGeometry.fit(CGSize(width: img.width, height: img.height), in: sz, fill: true))
                    }
                    fg = pb
                } else {
                    error = L("전경 이미지를 열 수 없음")
                }
            }
            DispatchQueue.main.async {
                guard gen == self.loadGeneration else { return }
                self.mlLock.lock(); self.foregroundStore = fg; self.mlLock.unlock()
                if let bg { self.video.store(bg) }
                self.imageError = error
                self.updateStatus()
            }
        }
    }

    private func updateStatus() {
        if let e = imageError { postStatus(Int32(MC_STATE_ERROR), e); return }
        let s = multiLayout
        let name = s.scenes.indices.contains(s.scene) ? s.scenes[s.scene].name : L("장면 없음")
        postStatus(Int32(MC_STATE_RUNNING), "MultiLayout · \(name)")
    }

    // MARK: API (APIFunctions: MultiLayout… functions)

    /// Input = the MultiLayout (empty: the one on Program, else in Preview, else the first).
    static func api(_ fn: String, _ value: String, _ input: InputSource?, _ e: SwitcherEngine) -> String? {
        guard Thread.isMainThread else { return DispatchQueue.main.sync { api(fn, value, input, e) } }
        let target = (input as? MultiLayoutInput)
            ?? [e.programID, e.previewID].compactMap { $0.flatMap { e.input(withID: $0) } }.compactMap { $0 as? MultiLayoutInput }.first
            ?? (input == nil ? e.inputs.compactMap { $0 as? MultiLayoutInput }.first : nil)
        guard let m = target else { return input == nil ? "No MultiLayout input" : "Input is not a MultiLayout" }
        func box(_ s: String) -> Int? { Int(s.trimmingCharacters(in: .whitespaces)).flatMap { (1...MLScene.boxCount).contains($0) ? $0 - 1 : nil } }
        switch fn {
        case "multilayoutscene":          // Value = scene number (1-based) or name
            let v = value.trimmingCharacters(in: .whitespaces)
            if let n = Int(v), m.multiLayout.scenes.indices.contains(n - 1) { m.take(scene: n - 1); return nil }
            guard let k = m.multiLayout.scenes.firstIndex(where: { $0.name.caseInsensitiveCompare(v) == .orderedSame }) else {
                return "Scene not found: \(value)"
            }
            m.take(scene: k)
        case "multilayoutnext": m.next()
        case "multilayoutprevious": m.previous()
        case "multilayoutboxinput":       // Value = box,input (input empty / 0 = none)
            let parts = value.split(separator: ",", maxSplits: 1).map { String($0).trimmingCharacters(in: .whitespaces) }
            guard let k = parts.first.flatMap(box) else { return "Value=box (1…\(MLScene.boxCount)),input" }
            let arg = parts.count > 1 ? parts[1] : ""
            if arg.isEmpty || arg == "0" { m.setInput(nil, box: k); return nil }
            guard let i = APIProcessor.resolveInput(arg, e), i.id != m.id else { return "Input not found: \(arg)" }
            m.setInput(i.id, box: k)
        case "multilayoutboxon", "multilayoutboxoff":     // Value = box
            guard let k = box(value) else { return "Value=1…\(MLScene.boxCount)" }
            m.setBox(k, visible: fn == "multilayoutboxon")
        default: return "Unknown function"
        }
        return nil
    }
}
