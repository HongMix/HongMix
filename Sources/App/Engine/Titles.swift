import Foundation
import CoreGraphics
import CoreText
import CoreVideo
import AppKit
import QuartzCore

// MARK: - Title model

enum TitleFieldKind: String, Codable, CaseIterable {
    case text, image, shape
}

/// Special behaviour for text fields.
enum TitleTextMode: String, Codable, CaseIterable {
    case plain, countdown, clock, ticker
}

/// One named element of a title (e.g. "Headline.Text", "Logo.Source", "Background.Fill").
struct TitleField: Codable, Equatable, Identifiable {
    var id: String                      // element name used by SetText/SelectedName
    var kind: TitleFieldKind = .text
    var mode: TitleTextMode = .plain
    var text: String = ""
    var color: String = "#FFFFFF"       // text colour, or fill colour for shapes (#RRGGBB or #RRGGBBAA)
    var visible: Bool = true
    var x: Double = 0                   // normalised frame (0..1, top-left origin)
    var y: Double = 0
    var w: Double = 0.5
    var h: Double = 0.1
    var fontSize: Double = 0.05         // fraction of frame height
    var fontName: String = "Helvetica Neue"
    var bold: Bool = true
    var align: String = "left"          // left | center | right
    var imagePath: String = ""
    var cornerRadius: Double = 0        // fraction of frame height
    var color2: String = ""             // shapes: gradient end colour (left → right); "" = solid
    var shadow: Bool = false            // text: soft drop shadow
    var strokeColor: String = ""        // text: outline colour ("" = none)
    var strokeWidth: Double = 0         // text: outline width, % of font size

    init(id: String, kind: TitleFieldKind = .text, mode: TitleTextMode = .plain, text: String = "",
         color: String = "#FFFFFF", x: Double, y: Double, w: Double, h: Double, fontSize: Double = 0.05,
         bold: Bool = true, align: String = "left", cornerRadius: Double = 0) {
        self.id = id
        self.kind = kind
        self.mode = mode
        self.text = text
        self.color = color
        self.x = x
        self.y = y
        self.w = w
        self.h = h
        self.fontSize = fontSize
        self.bold = bold
        self.align = align
        self.cornerRadius = cornerRadius
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = TitleField(id: "Field", x: 0, y: 0, w: 0.5, h: 0.1)
        id = c.value(.id, d.id)
        kind = c.value(.kind, d.kind)
        mode = c.value(.mode, d.mode)
        text = c.value(.text, d.text)
        color = c.value(.color, d.color)
        visible = c.value(.visible, d.visible)
        x = c.value(.x, d.x)
        y = c.value(.y, d.y)
        w = c.value(.w, d.w)
        h = c.value(.h, d.h)
        fontSize = c.value(.fontSize, d.fontSize)
        fontName = c.value(.fontName, d.fontName)
        bold = c.value(.bold, d.bold)
        align = c.value(.align, d.align)
        imagePath = c.value(.imagePath, d.imagePath)
        cornerRadius = c.value(.cornerRadius, d.cornerRadius)
        color2 = c.value(.color2, d.color2)
        shadow = c.value(.shadow, d.shadow)
        strokeColor = c.value(.strokeColor, d.strokeColor)
        strokeWidth = c.value(.strokeWidth, d.strokeWidth)
    }

    // small builders used by the template definitions
    func with(_ edit: (inout TitleField) -> Void) -> TitleField { var f = self; edit(&f); return f }
}

// MARK: - Colour helpers

enum HexColor {
    static func parse(_ s: String) -> (CGFloat, CGFloat, CGFloat, CGFloat)? {
        var h = s.trimmingCharacters(in: .whitespaces)
        if h.hasPrefix("#") { h.removeFirst() }
        guard h.count == 6 || h.count == 8, let v = UInt64(h, radix: 16) else { return nil }
        if h.count == 6 {
            return (CGFloat((v >> 16) & 0xFF) / 255, CGFloat((v >> 8) & 0xFF) / 255, CGFloat(v & 0xFF) / 255, 1)
        }
        return (CGFloat((v >> 24) & 0xFF) / 255, CGFloat((v >> 16) & 0xFF) / 255, CGFloat((v >> 8) & 0xFF) / 255,
                CGFloat(v & 0xFF) / 255)
    }

    static func cgColor(_ s: String, fallback: CGColor = CGColor(gray: 1, alpha: 1)) -> CGColor {
        guard let c = parse(s) else { return fallback }
        return CGColor(srgbRed: c.0, green: c.1, blue: c.2, alpha: c.3)
    }
}

// MARK: - Title input (GT-style graphics rendered with CoreText)

final class TitleInput: InputSource {
    @Published var document: TitleDocument {
        didSet {
            stateLock.lock()
            docSnapshot = document
            stateLock.unlock()
            invalidate()
        }
    }
    @Published private(set) var countdownRunning = false
    @Published private(set) var countdownPaused = false
    @Published var renderPaused = false {
        didSet { if !renderPaused { invalidate() } }
    }

    private let renderQueue = DispatchQueue(label: "title.render", qos: .userInitiated)
    private var timer: DispatchSourceTimer?
    private var pool: CVPixelBufferPool?
    private let width = 1920, height = 1080
    private let stateLock = NSLock()
    private var dirty = true
    // countdown state (stateLock)
    private var cdRemaining: Double = 300
    private var cdEndTime: CFTimeInterval = 0
    private var cdRunning = false
    private var cdPaused = false
    private var cdCompletedFired = false
    // animation (stateLock): 0 = hidden ... 1 = fully in
    private var animFrom: Double = 1
    private var animTo: Double = 1
    private var animStart: CFTimeInterval = 0
    private var tickerOrigin: CFTimeInterval = CACurrentMediaTime()
    private var imageCache: [String: CGImage] = [:]
    private var docSnapshot: TitleDocument          // render-thread copy (stateLock)

    override var alphaPremultiplied: Bool { true }

    override init(config: InputConfig) {
        let doc = config.title ?? TitleDocument(template: .lowerThird)
        self.document = doc
        self.docSnapshot = doc
        super.init(config: config)
        cdRemaining = doc.countdownSeconds
        audioFollowsVideo = false
    }

    override func currentConfig() -> InputConfig {
        var c = super.currentConfig()
        c.title = document
        return c
    }

    override func start() {
        guard timer == nil else { return }
        pool = PixelBufferFactory.makePool(width: width, height: height, minimumCount: 3)
        let t = DispatchSource.makeTimerSource(queue: renderQueue)
        t.schedule(deadline: .now(), repeating: .milliseconds(33))
        t.setEventHandler { [weak self] in self?.tick() }
        t.resume()
        timer = t
        postStatus(Int32(MC_STATE_RUNNING), document.template.label)
    }

    override func stop() {
        timer?.cancel()
        timer = nil
    }

    private func invalidate() {
        stateLock.lock()
        dirty = true
        stateLock.unlock()
    }

    /// Re-render when something changed, or continuously while animating / ticking / counting.
    private func tick() {
        let now = CACurrentMediaTime()
        stateLock.lock()
        let doc = docSnapshot
        let animating = animStart > 0 && now - animStart < max(0.05, doc.animateSeconds) + 0.05
        let needs = dirty || animating
        dirty = false
        stateLock.unlock()
        if renderPaused { return }
        // Tickers move every frame; clocks/countdowns only when the shown text changes (once a second) —
        // a full-frame CoreGraphics redraw 30×/s for a clock cost ~1 CPU core per title.
        let ticker = doc.fields.contains { $0.visible && $0.mode == .ticker }
        var key = ""
        if doc.fields.contains(where: { $0.visible && $0.mode == .clock }) { key += TitleInput.clockString() }
        if doc.fields.contains(where: { $0.visible && $0.mode == .countdown }) {
            stateLock.lock()
            key += TitleInput.formatCountdown(remaining(at: now))
            let done = cdRunning && !cdPaused && cdEndTime <= now && !cdCompletedFired
            if done { cdCompletedFired = true }
            stateLock.unlock()
            if done { emit(.countdownCompleted) }
        }
        let changed = key != lastLiveKey
        lastLiveKey = key
        if needs || ticker || changed { render(doc, now: now) }
    }
    private var lastLiveKey = ""

    // MARK: Countdown (Title API: SetCountdown/StartCountdown/StopCountdown/PauseCountdown/AdjustCountdown/ChangeCountdown)

    static func parseTime(_ s: String) -> Double? {
        let parts = s.split(separator: ":").map { Double($0.trimmingCharacters(in: .whitespaces)) }
        if parts.contains(where: { $0 == nil }) || parts.isEmpty { return nil }
        let v = parts.compactMap { $0 }
        switch v.count {
        case 1: return v[0]
        case 2: return v[0] * 60 + v[1]
        default: return v[v.count - 3] * 3600 + v[v.count - 2] * 60 + v[v.count - 1]
        }
    }

    private func remaining(at now: CFTimeInterval) -> Double {
        if cdRunning && !cdPaused { return max(0, cdEndTime - now) }
        return cdRemaining
    }

    func setCountdown(_ seconds: Double) {
        stateLock.lock()
        cdRemaining = max(0, seconds)
        cdRunning = false
        cdPaused = false
        dirty = true
        stateLock.unlock()
        document.countdownSeconds = max(0, seconds)
        publishCountdown()
    }

    func startCountdown() {
        let now = CACurrentMediaTime()
        stateLock.lock()
        if !cdRunning || cdPaused {
            cdEndTime = now + cdRemaining
            cdRunning = true
            cdPaused = false
            cdCompletedFired = cdRemaining <= 0
        }
        stateLock.unlock()
        publishCountdown()
    }

    func stopCountdown() {
        stateLock.lock()
        cdRunning = false
        cdPaused = false
        cdRemaining = document.countdownSeconds
        dirty = true
        stateLock.unlock()
        publishCountdown()
    }

    func pauseCountdown() {
        let now = CACurrentMediaTime()
        stateLock.lock()
        if cdRunning {
            if cdPaused {
                cdEndTime = now + cdRemaining
                cdPaused = false
            } else {
                cdRemaining = max(0, cdEndTime - now)
                cdPaused = true
            }
        }
        stateLock.unlock()
        publishCountdown()
    }

    /// Pause without toggling (SuspendCountdown).
    func suspendCountdown() {
        let now = CACurrentMediaTime()
        stateLock.lock()
        if cdRunning && !cdPaused {
            cdRemaining = max(0, cdEndTime - now)
            cdPaused = true
        }
        stateLock.unlock()
        publishCountdown()
    }

    func adjustCountdown(by seconds: Double) {
        stateLock.lock()
        if cdRunning && !cdPaused { cdEndTime += seconds } else { cdRemaining = max(0, cdRemaining + seconds) }
        dirty = true
        stateLock.unlock()
    }

    /// Change the remaining time without stopping (ChangeCountdown).
    func changeCountdown(to seconds: Double) {
        let now = CACurrentMediaTime()
        stateLock.lock()
        if cdRunning && !cdPaused { cdEndTime = now + seconds } else { cdRemaining = max(0, seconds) }
        dirty = true
        stateLock.unlock()
    }

    private func publishCountdown() {
        stateLock.lock()
        let r = cdRunning, p = cdPaused
        stateLock.unlock()
        DispatchQueue.main.async {
            self.countdownRunning = r
            self.countdownPaused = p
        }
    }

    // MARK: Animation (TitleBeginAnimation)

    func beginAnimation(out: Bool = false) {
        stateLock.lock()
        animFrom = out ? 1 : 0
        animTo = out ? 0 : 1
        animStart = CACurrentMediaTime()
        stateLock.unlock()
    }

    override func didGoLive() {
        beginAnimation(out: false)
        // countdown title: start counting as soon as it is on air (vMix-style); a finished one starts over
        if document.autoStartCountdown, document.fields.contains(where: { $0.visible && $0.mode == .countdown }) {
            let now = CACurrentMediaTime()
            stateLock.lock()
            let finished = cdRunning && !cdPaused && cdEndTime <= now
            let idle = !cdRunning || cdPaused
            stateLock.unlock()
            if finished { stopCountdown() }
            if finished || idle { startCountdown() }
        }
    }

    // MARK: Field API (SetText, SetTextColour, SetTextVisible, SetImage, SetImageVisible, SetColor)

    func fieldIndex(name: String?, index: Int?) -> Int? {
        if let n = name, !n.isEmpty {
            if let i = document.fields.firstIndex(where: { $0.id.caseInsensitiveCompare(n) == .orderedSame }) { return i }
            // allow "Headline" for "Headline.Text"
            if let i = document.fields.firstIndex(where: {
                $0.id.split(separator: ".").first.map(String.init)?.caseInsensitiveCompare(n) == .orderedSame
            }) { return i }
            return nil
        }
        if let i = index {
            let texts = document.fields.indices.filter { document.fields[$0].kind == .text }
            return texts.indices.contains(i) ? texts[i] : nil
        }
        return document.fields.firstIndex { $0.kind == .text }
    }

    func imageFieldIndex(name: String?, index: Int?) -> Int? {
        if let n = name, !n.isEmpty { return fieldIndex(name: n, index: nil) }
        let images = document.fields.indices.filter { document.fields[$0].kind == .image }
        let i = index ?? 0
        return images.indices.contains(i) ? images[i] : nil
    }

    func applyPreset(_ index: Int) {
        guard document.presets.indices.contains(index) else { return }
        var doc = document
        for (k, v) in doc.presets[index] {
            if let i = doc.fields.firstIndex(where: { $0.id == k }) { doc.fields[i].text = v }
        }
        doc.selectedPreset = index
        document = doc
    }

    func savePreset() {
        var set: [String: String] = [:]
        for f in document.fields where f.kind == .text && f.mode == .plain { set[f.id] = f.text }
        document.presets.append(set)
        document.selectedPreset = document.presets.count - 1
    }

    /// Text currently displayed for a field (for XML state).
    func displayText(_ f: TitleField) -> String {
        switch f.mode {
        case .plain, .ticker: return f.text
        case .clock: return TitleInput.clockString()
        case .countdown:
            stateLock.lock()
            let r = remaining(at: CACurrentMediaTime())
            stateLock.unlock()
            return TitleInput.formatCountdown(r)
        }
    }

    static func formatCountdown(_ s: Double) -> String {
        let total = Int(ceil(s))
        let h = total / 3600, m = (total % 3600) / 60, sec = total % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, sec) : String(format: "%02d:%02d", m, sec)
    }

    private static let clockFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f
    }()

    static func clockString() -> String {
        clockFormatter.string(from: Date())
    }

    // MARK: Rendering

    private func render(_ doc: TitleDocument, now: CFTimeInterval) {
        guard let pool = pool, let pb = PixelBufferFactory.makeBuffer(pool: pool) else { return }
        stateLock.lock()
        let cdText = TitleInput.formatCountdown(remaining(at: now))
        var anim = animTo
        if animStart > 0 {
            let p = min(1, (now - animStart) / max(0.05, doc.animateSeconds))
            anim = animFrom + (animTo - animFrom) * p
            if p >= 1 { animStart = 0 }
        }
        stateLock.unlock()
        CVPixelBufferLockBaseAddress(pb, [])
        defer { CVPixelBufferUnlockBaseAddress(pb, []) }
        guard let base = CVPixelBufferGetBaseAddress(pb) else { return }
        memset(base, 0, CVPixelBufferGetBytesPerRow(pb) * height)
        let info = CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        guard let cg = CGContext(data: base, width: width, height: height, bitsPerComponent: 8,
                                 bytesPerRow: CVPixelBufferGetBytesPerRow(pb),
                                 space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: info) else { return }
        TitleRenderer.draw(doc, in: cg, width: CGFloat(width), height: CGFloat(height), anim: anim,
                           countdown: cdText, tickerTime: now - tickerOrigin, images: images)
        video.store(pb)
    }

    private let images = TitleImageCache()
}

/// Loads (and caches) title images from files or URLs.
final class TitleImageCache {
    private var cache: [String: CGImage] = [:]
    private let lock = NSLock()

    func image(_ path: String) -> CGImage? {
        if path.isEmpty { return nil }
        lock.lock()
        if let c = cache[path] { lock.unlock(); return c }
        lock.unlock()
        let expanded = (path as NSString).expandingTildeInPath
        var image: NSImage?
        if path.hasPrefix("http://") || path.hasPrefix("https://"), let url = URL(string: path) {
            image = NSImage(contentsOf: url)
        } else {
            image = NSImage(contentsOfFile: expanded)
        }
        guard let cg = image?.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        lock.lock(); cache[path] = cg; lock.unlock()
        return cg
    }
}

/// Draws a title document (shared by the live input, the template gallery thumbnails and the editor).
enum TitleRenderer {
    /// `anim`: 0 = fully out … 1 = fully in (linear progress; eased here).
    static func draw(_ doc: TitleDocument, in cg: CGContext, width W: CGFloat, height H: CGFloat, anim: Double,
                     countdown: String, tickerTime: Double, images: TitleImageCache) {
        let clock = TitleInput.clockString()
        let a = max(0, min(1, anim))
        let e = CGFloat(a * a * (3 - 2 * a))
        // top-left origin for layout, text drawn with a local flip
        cg.saveGState()
        cg.translateBy(x: 0, y: H)
        cg.scaleBy(x: 1, y: -1)
        let visible = doc.fields.filter { $0.visible }
        let box = visible.reduce(CGRect.null) { $0.union(CGRect(x: $1.x * W, y: $1.y * H, width: $1.w * W, height: $1.h * H)) }
        switch doc.inOutEffect {
        case .fade:
            cg.setAlpha(e)
            cg.translateBy(x: 0, y: (1 - e) * H * 0.03)
        case .slideLeft:
            cg.setAlpha(min(1, e * 2.5))
            let dist = box.isNull ? W * 0.5 : box.maxX + W * 0.02
            cg.translateBy(x: -(1 - e) * dist, y: 0)
        case .slideUp:
            cg.setAlpha(min(1, e * 2.5))
            let dist = box.isNull ? H * 0.3 : H - box.minY + H * 0.02
            cg.translateBy(x: 0, y: (1 - e) * dist)
        case .wipe:
            if !box.isNull {
                cg.clip(to: CGRect(x: box.minX, y: box.minY - H, width: box.width * e, height: box.height + 2 * H))
            }
        case .pop:
            let s = 0.6 + 0.4 * e + 0.06 * sin(e * .pi)     // slight overshoot
            cg.setAlpha(min(1, e * 1.8))
            if !box.isNull {
                cg.translateBy(x: box.midX, y: box.midY)
                cg.scaleBy(x: s, y: s)
                cg.translateBy(x: -box.midX, y: -box.midY)
            }
        }
        if a <= 0.001 { cg.restoreGState(); return }

        for f in visible {
            let rect = CGRect(x: f.x * W, y: f.y * H, width: f.w * W, height: f.h * H)
            switch f.kind {
            case .shape:
                cg.saveGState()
                let path: CGPath = f.cornerRadius > 0
                    ? CGPath(roundedRect: rect, cornerWidth: min(rect.width / 2, CGFloat(f.cornerRadius) * H),
                             cornerHeight: min(rect.height / 2, CGFloat(f.cornerRadius) * H), transform: nil)
                    : CGPath(rect: rect, transform: nil)
                if !f.color2.isEmpty, HexColor.parse(f.color2) != nil,
                   let grad = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                                         colors: [HexColor.cgColor(f.color), HexColor.cgColor(f.color2)] as CFArray,
                                         locations: [0, 1]) {
                    cg.addPath(path)
                    cg.clip()
                    let full = rect.width >= W * 0.99 && rect.height >= H * 0.99
                    cg.drawLinearGradient(grad, start: CGPoint(x: rect.minX, y: rect.minY),
                                          end: full ? CGPoint(x: rect.maxX, y: rect.maxY) : CGPoint(x: rect.maxX, y: rect.minY),
                                          options: [])
                } else {
                    cg.setFillColor(HexColor.cgColor(f.color))
                    cg.addPath(path)
                    cg.fillPath()
                }
                cg.restoreGState()
            case .image:
                if let img = images.image(f.imagePath) {
                    let ia = CGFloat(img.width) / CGFloat(max(1, img.height))
                    var r = rect
                    if rect.width / max(1, rect.height) > ia {
                        r.size.width = rect.height * ia
                        r.origin.x = rect.midX - r.width / 2
                    } else {
                        r.size.height = rect.width / ia
                        r.origin.y = rect.midY - r.height / 2
                    }
                    cg.saveGState()
                    cg.translateBy(x: 0, y: r.maxY + r.minY)
                    cg.scaleBy(x: 1, y: -1)
                    cg.draw(img, in: r)
                    cg.restoreGState()
                }
            case .text:
                let text: String
                switch f.mode {
                case .plain, .ticker: text = f.text
                case .countdown: text = countdown
                case .clock: text = clock
                }
                drawText(text, field: f, rect: rect, frameH: H, in: cg,
                         ticker: f.mode == .ticker ? doc.tickerSpeed : nil, tickerTime: tickerTime)
            }
        }
        cg.restoreGState()
    }

    static func font(_ f: TitleField, size: CGFloat) -> CTFont {
        if f.bold {
            let bold = CTFontCreateWithName((f.fontName + " Bold") as CFString, size, nil)
            // fall back to a traits-bold variant when "<name> Bold" doesn't exist
            if (CTFontCopyFamilyName(bold) as String) == f.fontName { return bold }
            let base = CTFontCreateWithName(f.fontName as CFString, size, nil)
            return CTFontCreateCopyWithSymbolicTraits(base, size, nil, .boldTrait, .boldTrait) ?? base
        }
        return CTFontCreateWithName(f.fontName as CFString, size, nil)
    }

    static func drawText(_ text: String, field f: TitleField, rect: CGRect, frameH: CGFloat, in cg: CGContext,
                         ticker: Double?, tickerTime: Double) {
        guard !text.isEmpty else { return }
        var size = CGFloat(f.fontSize) * frameH
        func makeLine(_ s: CGFloat, stroke: Bool) -> CTLine {
            var attrs: [NSAttributedString.Key: Any] = [
                NSAttributedString.Key(kCTFontAttributeName as String): font(f, size: s),
                NSAttributedString.Key(kCTForegroundColorAttributeName as String): HexColor.cgColor(f.color),
            ]
            if stroke {
                attrs[NSAttributedString.Key(kCTStrokeColorAttributeName as String)] = HexColor.cgColor(f.strokeColor)
                attrs[NSAttributedString.Key(kCTStrokeWidthAttributeName as String)] = max(1, f.strokeWidth) * 2
            }
            return CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attrs))
        }
        var line = makeLine(size, stroke: false)
        var bounds = CTLineGetBoundsWithOptions(line, .useOpticalBounds)
        if ticker == nil {
            while bounds.width > rect.width && size > 8 {      // shrink to fit
                size *= 0.92
                line = makeLine(size, stroke: false)
                bounds = CTLineGetBoundsWithOptions(line, .useOpticalBounds)
            }
        }
        var x = rect.minX
        if let speed = ticker {
            let travel = rect.width + bounds.width
            let offset = CGFloat(tickerTime * speed) * rect.width
            x = rect.maxX - offset.truncatingRemainder(dividingBy: max(1, travel))
        } else if f.align == "center" {
            x = rect.midX - bounds.width / 2
        } else if f.align == "right" {
            x = rect.maxX - bounds.width
        }
        let ascent = CTFontGetAscent(font(f, size: size))
        let baseline = rect.midY + ascent * 0.35
        cg.saveGState()
        cg.clip(to: rect.insetBy(dx: ticker == nil ? -size : 0, dy: -size * 0.3))
        cg.translateBy(x: x, y: baseline)
        cg.scaleBy(x: 1, y: -1)
        if f.shadow {
            cg.setShadow(offset: CGSize(width: size * 0.04, height: -size * 0.06), blur: size * 0.18,
                         color: CGColor(gray: 0, alpha: 0.75))
        }
        cg.textPosition = .zero
        if !f.strokeColor.isEmpty && f.strokeWidth > 0 && HexColor.parse(f.strokeColor) != nil {
            CTLineDraw(makeLine(size, stroke: true), cg)        // outline under the fill
            cg.setShadow(offset: .zero, blur: 0, color: nil)
            cg.textPosition = .zero
        }
        CTLineDraw(line, cg)
        cg.restoreGState()
    }

    /// Small preview image for the template gallery / editor (transparent areas on a dark checker).
    static func thumbnail(_ doc: TitleDocument, width: Int = 384, height: Int = 216, images: TitleImageCache) -> CGImage? {
        let info = CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        guard let cg = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                 space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: info) else { return nil }
        let cell = CGFloat(height) / 12
        for yy in 0..<13 {
            for xx in 0..<Int(CGFloat(width) / cell) + 1 {
                cg.setFillColor(CGColor(gray: (xx + yy) % 2 == 0 ? 0.22 : 0.27, alpha: 1))
                cg.fill(CGRect(x: CGFloat(xx) * cell, y: CGFloat(yy) * cell, width: cell, height: cell))
            }
        }
        draw(doc, in: cg, width: CGFloat(width), height: CGFloat(height), anim: 1,
             countdown: TitleInput.formatCountdown(doc.countdownSeconds), tickerTime: 2.5, images: images)
        return cg.makeImage()
    }
}
