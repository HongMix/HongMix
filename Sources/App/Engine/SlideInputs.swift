import AppKit
import CoreGraphics
import CoreVideo
import Foundation
import ImageIO

// Photos (slideshow), PDF Slides and Virtual Set inputs.
//
// Frame production (Photos / PDF Slides):
//   * Every slide is rasterised once, at the program resolution, into a BGRA IOSurface-backed
//     CVPixelBuffer from a pool ("slide frame"). Slide frames are immutable once rendered and are
//     handed to the input's VideoSlot as-is, so a static slide costs nothing per program frame
//     (the mixer just re-uses the last frame, like an Image input).
//   * `SlideRenderer` owns two serial queues: `renderQueue` decodes / rasterises (ImageIO
//     downsampling or CoreGraphics PDF drawing) and `queue` (control) handles jumps, the
//     auto-advance timer and transitions. The current, next and previous slides are kept in a
//     small cache and the neighbours are prefetched after every jump, so Next / Previous only hops
//     a queue (< 1 ms) instead of decoding.
//   * Transitions run only while they are active: a timer at the program frame rate blends the
//     outgoing and incoming slide frames on the CPU (2 channels per 32-bit multiply, split into
//     row bands with concurrentPerform) into a pooled buffer. After the transition the static
//     slide frame is stored again and nothing is redrawn until the next jump.
//
// Virtual Set reuses the existing layer system (see `VirtualSetInput`).
//
// The block between BEGIN/END SLIDE-CORE has no dependency on the rest of the app except
// `PixelBufferFactory`; the standalone tests compile it on its own.

// BEGIN SLIDE-CORE

/// Transition between two slides (CPU, only while it runs). Names follow vMix transition names.
enum SlideTransitionStyle: String, Codable, CaseIterable, Identifiable {
    case cut, fade, dip, wipe, slide
    var id: String { rawValue }
    var label: String {
        switch self {
        case .cut: return "Cut"
        case .fade: return "Fade"
        case .dip: return "FadeToBlack"
        case .wipe: return "Wipe"
        case .slide: return "Slide"
        }
    }
    static func named(_ s: String) -> SlideTransitionStyle? {
        allCases.first { $0.rawValue.caseInsensitiveCompare(s) == .orderedSame || $0.label.caseInsensitiveCompare(s) == .orderedSame }
    }
}

/// Settings of a Photos (slideshow) or PDF Slides input (saved in project files).
struct SlideSettings: Codable, Equatable {
    /// Photos: folder. PDF Slides: the .pdf file.
    var path: String = ""
    /// Photos: seconds each photo stays on screen while playing.
    var seconds: Double = 5
    var transition: SlideTransitionStyle = .fade
    var transitionMs: Int = 500
    /// Photos: random order.
    var shuffle = false
    /// true = crop to fill the frame, false = fit inside (letterbox / pillarbox on black)
    var fill = false
    /// Slide shown when the project was saved (restored on load).
    var index: Int = 0

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = SlideSettings()
        func v<T: Decodable>(_ k: CodingKeys, _ f: T) -> T { ((try? c.decodeIfPresent(T.self, forKey: k)) ?? nil) ?? f }
        path = v(.path, d.path)
        seconds = v(.seconds, d.seconds)
        transition = v(.transition, d.transition)
        transitionMs = v(.transitionMs, d.transitionMs)
        shuffle = v(.shuffle, d.shuffle)
        fill = v(.fill, d.fill)
        index = v(.index, d.index)
    }
}

/// Folder scanning and ordering for the Photos input.
enum SlideFolder {
    static let extensions: Set<String> = ["jpg", "jpeg", "png", "heic", "heif", "tif", "tiff", "webp", "gif", "bmp"]

    /// Supported image files directly inside `folder` (not recursive, hidden files skipped),
    /// in Finder order ("IMG 2" before "IMG 10").
    static func scan(_ folder: String) -> [String]? {
        let url = URL(fileURLWithPath: (folder as NSString).expandingTildeInPath, isDirectory: true)
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: url.path) else { return nil }
        return names
            .filter { !$0.hasPrefix(".") && extensions.contains(($0 as NSString).pathExtension.lowercased()) }
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
            .map { url.appendingPathComponent($0).path }
    }

    /// New play order after a (re)scan. Sorted order unless shuffled; a shuffled order keeps the
    /// files it already had in place and inserts new files at random positions.
    static func order<G: RandomNumberGenerator>(previous: [String], scanned: [String], shuffle: Bool,
                                               using rng: inout G) -> [String] {
        guard shuffle else { return scanned }
        let present = Set(scanned)
        var out = previous.filter { present.contains($0) }
        let known = Set(out)
        for f in scanned where !known.contains(f) {
            out.insert(f, at: Int.random(in: 0...out.count, using: &rng))
        }
        return out
    }
}

/// Index arithmetic shared by the slide inputs.
enum SlideIndex {
    /// Next index `delta` steps away; wraps when `loop`, otherwise stops at the ends.
    static func step(_ index: Int, by delta: Int, count: Int, loop: Bool) -> Int {
        guard count > 0 else { return 0 }
        let t = index + delta
        if loop { return ((t % count) + count) % count }
        return min(max(t, 0), count - 1)
    }

    static func clamp(_ index: Int, count: Int) -> Int { count > 0 ? min(max(index, 0), count - 1) : 0 }
}

enum SlideGeometry {
    /// Centred rectangle of a `src`-sized picture in `dst`: fit inside (letterbox) or crop to fill.
    /// Symmetric, so it is the same in top-left and bottom-left coordinate systems.
    static func fit(_ src: CGSize, in dst: CGSize, fill: Bool) -> CGRect {
        guard src.width > 0, src.height > 0 else { return CGRect(origin: .zero, size: dst) }
        let s = fill ? max(dst.width / src.width, dst.height / src.height)
                     : min(dst.width / src.width, dst.height / src.height)
        let w = src.width * s, h = src.height * s
        return CGRect(x: (dst.width - w) / 2, y: (dst.height - h) / 2, width: w, height: h)
    }
}

/// ImageIO decoding at output resolution.
enum SlideImage {
    /// Pixel size after applying the EXIF orientation.
    static func orientedSize(_ src: CGImageSource) -> CGSize? {
        guard let p = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
              let w = (p[kCGImagePropertyPixelWidth] as? NSNumber)?.doubleValue,
              let h = (p[kCGImagePropertyPixelHeight] as? NSNumber)?.doubleValue else { return nil }
        let o = (p[kCGImagePropertyOrientation] as? NSNumber)?.intValue ?? 1
        return o >= 5 && o <= 8 ? CGSize(width: h, height: w) : CGSize(width: w, height: h)
    }

    /// First frame of `path`, downsampled so it is just large enough for `target` (never upscaled),
    /// rotated upright according to its EXIF orientation.
    static func decode(_ path: String, target: CGSize, fill: Bool) -> CGImage? {
        let url = URL(fileURLWithPath: path) as CFURL
        guard let src = CGImageSourceCreateWithURL(url, [kCGImageSourceShouldCache: false] as CFDictionary),
              CGImageSourceGetCount(src) > 0 else { return nil }
        let size = orientedSize(src) ?? target
        let r = SlideGeometry.fit(size, in: target, fill: fill)
        let scale = min(1, r.width / max(1, size.width))
        let maxPx = Int((max(size.width, size.height) * scale).rounded(.up))
        let opts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: max(16, maxPx),
            kCGImageSourceShouldCacheImmediately: true,
        ]
        return CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary)
    }

    /// Small preview (embedded thumbnail when there is one).
    static func thumbnail(_ path: String, maxPixel: Int) -> CGImage? {
        let url = URL(fileURLWithPath: path) as CFURL
        guard let src = CGImageSourceCreateWithURL(url, [kCGImageSourceShouldCache: false] as CFDictionary) else { return nil }
        let opts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageIfAbsent: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: max(16, maxPixel),
        ]
        return CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary)
    }
}

/// CPU drawing / blending into BGRA (premultiplied, little-endian 32-bit) pixel buffers.
enum SlidePixels {
    static let opaqueBlack: UInt32 = 0xFF00_0000
    /// sRGB (≈ Rec.709 primaries): photos and slides keep their colours instead of being matched
    /// to whatever "device RGB" means in this process.
    static let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()

    /// Draws with CoreGraphics into `pb` (top row first in memory, CG coordinates bottom-left).
    /// `clear`: nil = transparent, else the background colour.
    @discardableResult
    static func draw(_ pb: CVPixelBuffer, clear: CGColor?, _ body: (CGContext, CGSize) -> Void) -> Bool {
        CVPixelBufferLockBaseAddress(pb, [])
        defer { CVPixelBufferUnlockBaseAddress(pb, []) }
        guard let base = CVPixelBufferGetBaseAddress(pb) else { return false }
        let w = CVPixelBufferGetWidth(pb), h = CVPixelBufferGetHeight(pb), bpr = CVPixelBufferGetBytesPerRow(pb)
        memset(base, 0, bpr * h)
        let info = CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        guard let ctx = CGContext(data: base, width: w, height: h, bitsPerComponent: 8, bytesPerRow: bpr,
                                  space: SlidePixels.colorSpace, bitmapInfo: info) else { return false }
        if let clear {
            ctx.setFillColor(clear)
            ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        }
        ctx.interpolationQuality = .high
        body(ctx, CGSize(width: w, height: h))
        ctx.flush()
        return true
    }

    /// out = a·(256−w)/256 + b·w/256 per 8-bit channel (w 0…256), two channels per multiply.
    @inline(__always)
    static func lerp(_ a: UInt32, _ b: UInt32, _ w: UInt32) -> UInt32 {
        let ia = 256 &- w
        let rb = (((a & 0x00FF_00FF) &* ia &+ (b & 0x00FF_00FF) &* w) >> 8) & 0x00FF_00FF
        let ag = (((a >> 8) & 0x00FF_00FF) &* ia &+ ((b >> 8) & 0x00FF_00FF) &* w) & 0xFF00_FF00
        return rb | ag
    }

    @inline(__always)
    static func ease(_ t: Double) -> Double { let x = min(max(t, 0), 1); return x * x * (3 - 2 * x) }

    /// One transition frame at progress `t` (0…1) from `from` to `to` into `out` (all the same size).
    @discardableResult
    static func transition(_ style: SlideTransitionStyle, t: Double, from: CVPixelBuffer, to: CVPixelBuffer,
                           into out: CVPixelBuffer) -> Bool {
        let w = CVPixelBufferGetWidth(out), h = CVPixelBufferGetHeight(out)
        guard CVPixelBufferGetWidth(from) == w, CVPixelBufferGetHeight(from) == h,
              CVPixelBufferGetWidth(to) == w, CVPixelBufferGetHeight(to) == h else { return false }
        CVPixelBufferLockBaseAddress(from, .readOnly)
        CVPixelBufferLockBaseAddress(to, .readOnly)
        CVPixelBufferLockBaseAddress(out, [])
        defer {
            CVPixelBufferUnlockBaseAddress(out, [])
            CVPixelBufferUnlockBaseAddress(to, .readOnly)
            CVPixelBufferUnlockBaseAddress(from, .readOnly)
        }
        guard let fb = CVPixelBufferGetBaseAddress(from), let tb = CVPixelBufferGetBaseAddress(to),
              let ob = CVPixelBufferGetBaseAddress(out) else { return false }
        let fs = CVPixelBufferGetBytesPerRow(from), ts = CVPixelBufferGetBytesPerRow(to), os = CVPixelBufferGetBytesPerRow(out)
        let tt = min(max(t, 0), 1)
        let e = ease(tt)
        let bands = max(1, min(8, h / 64))
        DispatchQueue.concurrentPerform(iterations: bands) { band in
            let y0 = h * band / bands, y1 = h * (band + 1) / bands
            for y in y0..<y1 {
                let a = (fb + y * fs).assumingMemoryBound(to: UInt32.self)
                let b = (tb + y * ts).assumingMemoryBound(to: UInt32.self)
                let o = (ob + y * os).assumingMemoryBound(to: UInt32.self)
                switch style {
                case .cut:
                    o.update(from: b, count: w)
                case .fade:
                    let k = UInt32((tt * 256).rounded())
                    for x in 0..<w { o[x] = lerp(a[x], b[x], k) }
                case .dip:
                    if tt < 0.5 {
                        let k = UInt32(((1 - 2 * tt) * 256).rounded())
                        for x in 0..<w { o[x] = lerp(opaqueBlack, a[x], k) }
                    } else {
                        let k = UInt32(((2 * tt - 1) * 256).rounded())
                        for x in 0..<w { o[x] = lerp(opaqueBlack, b[x], k) }
                    }
                case .wipe:
                    let edge = min(w, max(0, Int((e * Double(w)).rounded())))
                    if edge > 0 { o.update(from: b, count: edge) }
                    if edge < w { (o + edge).update(from: a + edge, count: w - edge) }
                case .slide:
                    // the new slide pushes the old one out to the left
                    let off = min(w, max(0, Int((e * Double(w)).rounded())))
                    if off < w { o.update(from: a + off, count: w - off) }
                    if off > 0 { (o + (w - off)).update(from: b, count: off) }
                }
            }
        }
        return true
    }
}

/// Something with numbered slides that can be drawn at any size. Implementations are immutable
/// (a rescan / reload makes a new one), so they can be used from several queues.
protocol SlideSource: AnyObject {
    var count: Int { get }
    /// Stable identity of slide `index` (file path, page number) — cache key.
    func key(_ index: Int) -> String
    /// Short name for the UI / status (file name, "Page 3").
    func name(_ index: Int) -> String
    /// Draws slide `index` into `ctx` (already cleared to black) of `size`.
    func draw(_ index: Int, in ctx: CGContext, size: CGSize, fill: Bool) -> Bool
    func thumbnail(_ index: Int, maxPixel: Int) -> CGImage?
}

extension SlideSource {
    func index(ofKey k: String) -> Int? { (0..<count).first { key($0) == k } }
}

/// Photos in a folder.
final class PhotoSlideSource: SlideSource {
    let files: [String]
    init(files: [String]) { self.files = files }
    var count: Int { files.count }
    func key(_ index: Int) -> String { files.indices.contains(index) ? files[index] : "" }
    func name(_ index: Int) -> String { (key(index) as NSString).lastPathComponent }
    func draw(_ index: Int, in ctx: CGContext, size: CGSize, fill: Bool) -> Bool {
        guard files.indices.contains(index), let img = SlideImage.decode(files[index], target: size, fill: fill) else { return false }
        ctx.draw(img, in: SlideGeometry.fit(CGSize(width: img.width, height: img.height), in: size, fill: fill))
        return true
    }
    func thumbnail(_ index: Int, maxPixel: Int) -> CGImage? {
        files.indices.contains(index) ? SlideImage.thumbnail(files[index], maxPixel: maxPixel) : nil
    }
}

/// Pages of a PDF (Keynote / PowerPoint / Google Slides exported as PDF).
final class PDFSlideSource: SlideSource {
    let url: URL
    private let doc: CGPDFDocument            // used on the render queue only
    private let thumbLock = NSLock()
    private var thumbDoc: CGPDFDocument?      // separate instance for the thumbnail queue
    let count: Int

    init?(path: String) {
        url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
        guard let d = CGPDFDocument(url as CFURL) else { return nil }
        if d.isEncrypted && !d.isUnlocked { _ = d.unlockWithPassword("") }
        guard d.isUnlocked, d.numberOfPages > 0 else { return nil }
        doc = d
        count = d.numberOfPages
    }

    func key(_ index: Int) -> String { "page \(index + 1)" }
    func name(_ index: Int) -> String { "\(index + 1) / \(count)" }

    /// Page size as displayed (crop box, /Rotate applied).
    static func displaySize(_ page: CGPDFPage) -> CGSize {
        let box = page.getBoxRect(.cropBox)
        let rot = ((Int(page.rotationAngle) % 360) + 360) % 360
        return rot % 180 == 0 ? box.size : CGSize(width: box.height, height: box.width)
    }

    /// Draws `page` into `rect` of `ctx` (white paper, rotation applied).
    static func draw(_ page: CGPDFPage, in ctx: CGContext, rect: CGRect, clip: CGRect) {
        let box = page.getBoxRect(.cropBox)
        let shown = displaySize(page)
        guard shown.width > 0, shown.height > 0 else { return }
        let s = rect.width / shown.width
        ctx.saveGState()
        ctx.clip(to: clip)
        ctx.setFillColor(CGColor(gray: 1, alpha: 1))
        ctx.fill(rect)
        ctx.clip(to: rect)
        ctx.translateBy(x: rect.midX, y: rect.midY)
        ctx.scaleBy(x: s, y: s)
        ctx.rotate(by: -CGFloat(page.rotationAngle) * .pi / 180)    // /Rotate is clockwise
        ctx.translateBy(x: -box.midX, y: -box.midY)
        ctx.drawPDFPage(page)
        ctx.restoreGState()
    }

    func draw(_ index: Int, in ctx: CGContext, size: CGSize, fill: Bool) -> Bool {
        guard let page = doc.page(at: index + 1) else { return false }
        let r = SlideGeometry.fit(PDFSlideSource.displaySize(page), in: size, fill: fill)
        PDFSlideSource.draw(page, in: ctx, rect: r, clip: CGRect(origin: .zero, size: size))
        return true
    }

    func thumbnail(_ index: Int, maxPixel: Int) -> CGImage? {
        thumbLock.lock(); defer { thumbLock.unlock() }
        if thumbDoc == nil { thumbDoc = CGPDFDocument(url as CFURL) }
        guard let page = thumbDoc?.page(at: index + 1) else { return nil }
        let s = PDFSlideSource.displaySize(page)
        let k = CGFloat(max(16, maxPixel)) / max(s.width, s.height)
        let w = max(1, Int((s.width * k).rounded())), h = max(1, Int((s.height * k).rounded()))
        let info = CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: SlidePixels.colorSpace, bitmapInfo: info) else { return nil }
        ctx.interpolationQuality = .high
        let r = CGRect(x: 0, y: 0, width: w, height: h)
        PDFSlideSource.draw(page, in: ctx, rect: r, clip: r)
        return ctx.makeImage()
    }
}

/// Produces the slide frames of one input (see the file header for the threading design).
final class SlideRenderer {
    /// Control queue: jumps, transitions, auto-advance. Never blocks on decoding except for a
    /// slide that is not in the cache yet.
    let queue = DispatchQueue(label: "hongmix.slides.control", qos: .userInteractive)
    /// Decoding / rasterising (on-demand slide + prefetch of the neighbours).
    private let renderQueue = DispatchQueue(label: "hongmix.slides.render", qos: .userInitiated)

    /// New frame for the input's VideoSlot (control queue).
    var onFrame: ((CVPixelBuffer) -> Void)?
    /// Current slide changed: (index, count) (control queue).
    var onIndex: ((Int, Int) -> Void)?
    /// Auto-advance reached the last slide with looping off (control queue).
    var onEnd: (() -> Void)?

    private final class Spec {
        let size: CGSize, fill: Bool, pool: CVPixelBufferPool?, id: Int
        init(size: CGSize, fill: Bool, id: Int) {
            self.size = size; self.fill = fill; self.id = id
            pool = PixelBufferFactory.makePool(width: Int(size.width), height: Int(size.height), minimumCount: 4)
        }
    }

    // shared state (lock)
    private let lock = NSLock()
    private var source: SlideSource?
    private var spec: Spec
    private var cache: [String: CVPixelBuffer] = [:]
    private var pendingJumps = 0
    private var indexStore = 0
    private var countStore = 0
    private var slideStart: CFTimeInterval = 0
    private var renderCount = 0
    private var specCounter = 0

    // control-queue state
    private var style: SlideTransitionStyle = .fade
    private var duration: Double = 0.5
    private var fps: Double = 29.97
    private var shown: CVPixelBuffer?
    private var transitionTimer: DispatchSourceTimer?
    private var advanceTimer: DispatchSourceTimer?
    private var advanceSeconds: Double?
    private var loop = true

    init(size: CGSize = CGSize(width: 1920, height: 1080)) {
        spec = Spec(size: size, fill: false, id: 0)
    }

    private static func now() -> CFTimeInterval { ProcessInfo.processInfo.systemUptime }

    // MARK: snapshots (any thread)

    var index: Int { lock.lock(); defer { lock.unlock() }; return indexStore }
    var count: Int { lock.lock(); defer { lock.unlock() }; return countStore }
    /// Seconds the current slide has been on screen.
    var elapsed: Double { lock.lock(); defer { lock.unlock() }; return slideStart > 0 ? SlideRenderer.now() - slideStart : 0 }
    /// Slides rasterised so far (tests / statistics).
    var renders: Int { lock.lock(); defer { lock.unlock() }; return renderCount }
    var cachedKeys: [String] { lock.lock(); defer { lock.unlock() }; return Array(cache.keys) }
    var isTransitioning: Bool { queue.sync { transitionTimer != nil } }

    // MARK: control

    /// Output size / fit, transition and program rate. Changing size or fit re-renders the current slide.
    func configure(size: CGSize, fill: Bool, style: SlideTransitionStyle, durationMs: Int, fps: Double) {
        queue.async { [self] in
            self.style = style
            duration = max(0, Double(durationMs) / 1000)
            self.fps = fps > 1 ? fps : 29.97
            lock.lock()
            let changed = spec.size != size || spec.fill != fill
            if changed {
                specCounter += 1
                spec = Spec(size: size, fill: fill, id: specCounter)
                cache.removeAll()
            }
            let has = source != nil
            let i = indexStore
            lock.unlock()
            if changed && has { goNow(i, animated: false) }
        }
    }

    /// New slides (rescan / reload). `keepCache`: slide keys still mean the same picture (photo paths).
    func setSource(_ s: SlideSource?, index: Int, keepCache: Bool) {
        queue.async { [self] in
            lock.lock()
            source = s
            if !keepCache { cache.removeAll() }
            lock.unlock()
            guard let s, s.count > 0 else {
                cancelTransition()
                setIndex(0, 0)
                if let f = blackFrame() { deliver(f) }
                restartAdvanceTimer()
                return
            }
            goNow(SlideIndex.clamp(index, count: s.count), animated: false)
        }
    }

    /// Jump to slide `index` (with the transition unless `animated` is false).
    func go(to index: Int, animated: Bool = true) {
        bumpPending(1)
        queue.async { [self] in
            bumpPending(-1)
            goNow(index, animated: animated)
        }
    }

    /// Next (+1) / previous (−1) relative to the slide shown when the call is processed.
    func step(_ delta: Int, loop: Bool, animated: Bool = true) {
        bumpPending(1)
        queue.async { [self] in
            bumpPending(-1)
            let n = count
            guard n > 0 else { return }
            goNow(SlideIndex.step(index, by: delta, count: n, loop: loop), animated: animated)
        }
    }

    /// Auto-advance every `seconds` (nil = paused). Resuming starts a full interval.
    func setAutoAdvance(seconds: Double?, loop: Bool) {
        queue.async { [self] in
            advanceSeconds = seconds
            self.loop = loop
            restartAdvanceTimer()
        }
    }

    func shutdown() {
        queue.async { [self] in
            cancelTransition()
            advanceTimer?.cancel(); advanceTimer = nil
            advanceSeconds = nil
        }
    }

    /// Waits until queued jumps and prefetches are done (tests).
    func waitIdle() {
        queue.sync {}
        renderQueue.sync {}
        queue.sync {}
    }

    // MARK: internals (control queue)

    private func bumpPending(_ d: Int) { lock.lock(); pendingJumps += d; lock.unlock() }

    private func setIndex(_ i: Int, _ n: Int) {
        lock.lock(); indexStore = i; countStore = n; slideStart = SlideRenderer.now(); lock.unlock()
        onIndex?(i, n)
    }

    private func deliver(_ pb: CVPixelBuffer) {
        shown = pb
        onFrame?(pb)
    }

    private func goNow(_ target: Int, animated: Bool) {
        lock.lock()
        let src = source, sp = spec
        lock.unlock()
        guard let src, src.count > 0 else { return }
        let t = SlideIndex.clamp(target, count: src.count)
        guard let frame = renderQueue.sync(execute: { renderFrame(t, src, sp) }) else { return }
        setIndex(t, src.count)
        evict(keeping: neighbours(t, src).map { cacheKey(src.key($0), sp) })
        let sameSize = shown.map { CVPixelBufferGetWidth($0) == Int(sp.size.width) && CVPixelBufferGetHeight($0) == Int(sp.size.height) } ?? false
        if animated, style != .cut, duration > 0, let from = shown, from !== frame, sameSize {
            startTransition(from: from, to: frame, spec: sp)
        } else {
            cancelTransition()
            deliver(frame)
        }
        restartAdvanceTimer()
        prefetch(around: t, src, sp)
    }

    private func neighbours(_ t: Int, _ src: SlideSource) -> [Int] {
        let n = src.count
        return Array(Set([t, SlideIndex.step(t, by: 1, count: n, loop: true), SlideIndex.step(t, by: -1, count: n, loop: true)]))
    }

    private func cacheKey(_ k: String, _ sp: Spec) -> String { "\(sp.id)|\(k)" }

    private func evict(keeping keys: [String]) {
        let keep = Set(keys)
        lock.lock()
        for k in cache.keys where !keep.contains(k) { cache[k] = nil }
        lock.unlock()
    }

    private func prefetch(around t: Int, _ src: SlideSource, _ sp: Spec) {
        guard src.count > 1 else { return }
        for d in [1, -1] {
            let j = SlideIndex.step(t, by: d, count: src.count, loop: true)
            renderQueue.async { [weak self] in
                guard let self else { return }
                self.lock.lock()
                let stale = self.pendingJumps > 0 || self.source !== src || self.spec !== sp
                self.lock.unlock()
                if stale { return }          // a newer jump will prefetch around its own slide
                _ = self.renderFrame(j, src, sp)
            }
        }
    }

    /// Render queue: the slide frame from the cache, or rasterised now.
    private func renderFrame(_ i: Int, _ src: SlideSource, _ sp: Spec) -> CVPixelBuffer? {
        let k = cacheKey(src.key(i), sp)
        lock.lock()
        if let c = cache[k] { lock.unlock(); return c }
        lock.unlock()
        guard let pool = sp.pool, let pb = PixelBufferFactory.makeBuffer(pool: pool) else { return nil }
        SlidePixels.draw(pb, clear: CGColor(gray: 0, alpha: 1)) { ctx, size in
            _ = src.draw(i, in: ctx, size: size, fill: sp.fill)   // unreadable file → black slide
        }
        lock.lock()
        renderCount += 1
        if source === src && spec === sp { cache[k] = pb }
        lock.unlock()
        return pb
    }

    private func blackFrame() -> CVPixelBuffer? {
        lock.lock(); let sp = spec; lock.unlock()
        guard let pool = sp.pool, let pb = PixelBufferFactory.makeBuffer(pool: pool) else { return nil }
        SlidePixels.draw(pb, clear: CGColor(gray: 0, alpha: 1)) { _, _ in }
        return pb
    }

    private func startTransition(from: CVPixelBuffer, to: CVPixelBuffer, spec sp: Spec) {
        cancelTransition()
        let start = SlideRenderer.now(), dur = duration, style = self.style
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now(), repeating: 1.0 / fps, leeway: .milliseconds(1))
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            let t = (SlideRenderer.now() - start) / dur
            if t >= 1 {
                self.cancelTransition()
                self.deliver(to)                      // static slide frame again — no more redraws
                return
            }
            guard let pool = sp.pool, let out = PixelBufferFactory.makeBuffer(pool: pool),
                  SlidePixels.transition(style, t: t, from: from, to: to, into: out) else { return }
            self.deliver(out)
        }
        transitionTimer = timer
        timer.resume()
    }

    private func cancelTransition() {
        transitionTimer?.cancel()
        transitionTimer = nil
    }

    private func restartAdvanceTimer() {
        advanceTimer?.cancel()
        advanceTimer = nil
        guard let s = advanceSeconds, s > 0, count > 1 else { return }
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + s)
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            let n = self.count, i = self.index
            if i + 1 >= n && !self.loop {
                self.advanceTimer = nil
                self.onEnd?()
                return
            }
            self.goNow(SlideIndex.step(i, by: 1, count: n, loop: true), animated: true)
        }
        advanceTimer = timer
        timer.resume()
    }
}

/// Small CGImages for the editor's thumbnail strip (async, cached).
final class SlideThumbnailCache {
    private let queue = DispatchQueue(label: "hongmix.slides.thumbs", qos: .utility)
    private let cache = NSCache<NSString, CGImage>()
    private let lock = NSLock()
    private var source: SlideSource?
    private var generation = 0

    init() { cache.countLimit = 400 }

    /// `clear`: false keeps thumbnails whose keys survive (photo paths after a rescan).
    func setSource(_ s: SlideSource?, clear: Bool) {
        lock.lock(); source = s; generation += 1; lock.unlock()
        if clear { cache.removeAllObjects() }
    }

    func cached(_ index: Int, maxPixel: Int = 256) -> CGImage? {
        lock.lock(); let s = source; lock.unlock()
        guard let s, index >= 0, index < s.count else { return nil }
        return cache.object(forKey: "\(s.key(index))@\(maxPixel)" as NSString)
    }

    /// Calls `completion` on `callbackQueue` with the thumbnail of slide `index` (nil if unavailable
    /// or the slides were reloaded meanwhile).
    func thumbnail(_ index: Int, maxPixel: Int = 256, callbackQueue: DispatchQueue = .main,
                   completion: @escaping (CGImage?) -> Void) {
        lock.lock(); let s = source, gen = generation; lock.unlock()
        guard let s, index >= 0, index < s.count else { callbackQueue.async { completion(nil) }; return }
        let key = "\(s.key(index))@\(maxPixel)" as NSString
        if let c = cache.object(forKey: key) { callbackQueue.async { completion(c) }; return }
        queue.async { [weak self] in
            guard let self else { return }
            self.lock.lock(); let current = self.generation == gen; self.lock.unlock()
            let img = current ? s.thumbnail(index, maxPixel: maxPixel) : nil
            if let img { self.cache.setObject(img, forKey: key) }
            callbackQueue.async { completion(img) }
        }
    }
}

/// Watches a file or folder; calls `handler` (debounced) on `queue` when it changes. Survives
/// atomic saves (the file is replaced) and a folder / file that is missing for a while.
final class SlideFileWatcher {
    private let path: String
    private let queue: DispatchQueue
    private let debounce: Double
    private let handler: () -> Void
    private var source: DispatchSourceFileSystemObject?
    private var pending: DispatchWorkItem?
    private var stopped = false

    init(path: String, queue: DispatchQueue = .main, debounce: Double = 0.5, handler: @escaping () -> Void) {
        self.path = (path as NSString).expandingTildeInPath
        self.queue = queue
        self.debounce = debounce
        self.handler = handler
        queue.async { self.arm(notify: false) }
    }

    func stop() {
        queue.async {
            self.stopped = true
            self.pending?.cancel()
            self.source?.cancel()
            self.source = nil
        }
    }

    private func arm(notify: Bool) {
        guard !stopped else { return }
        let fd = open(path, O_EVTONLY)
        guard fd >= 0 else {
            // missing (being replaced, unmounted …): try again shortly
            queue.asyncAfter(deadline: .now() + 1) { [weak self] in self?.arm(notify: true) }
            return
        }
        let src = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd,
                                                            eventMask: [.write, .delete, .rename, .extend, .attrib, .link],
                                                            queue: queue)
        src.setEventHandler { [weak self, weak src] in
            guard let self, let src else { return }
            let ev = src.data
            self.fire()
            if ev.contains(.delete) || ev.contains(.rename) {
                src.cancel()
                self.source = nil
                self.queue.asyncAfter(deadline: .now() + 0.3) { [weak self] in self?.arm(notify: true) }
            }
        }
        src.setCancelHandler { close(fd) }
        source = src
        src.resume()
        if notify { fire() }
    }

    private func fire() {
        pending?.cancel()
        let w = DispatchWorkItem { [weak self] in
            guard let self, !self.stopped else { return }
            self.handler()
        }
        pending = w
        queue.asyncAfter(deadline: .now() + debounce, execute: w)
    }
}

/// Where the presenter stands in a Virtual Set.
enum VirtualSetPreset: String, Codable, CaseIterable, Identifiable {
    case centre, leftThird, rightThird, full
    var id: String { rawValue }
    /// (centre x, bottom edge, height) of the presenter box as fractions of the frame
    var placement: (x: Double, bottom: Double, scale: Double) {
        switch self {
        case .centre: return (0.5, 1.0, 0.8)
        case .leftThird: return (1.0 / 3, 1.0, 0.8)
        case .rightThird: return (2.0 / 3, 1.0, 0.8)
        case .full: return (0.5, 1.0, 1.0)
        }
    }
}

/// Settings of a Virtual Set input (saved in project files).
struct VirtualSetSettings: Codable, Equatable {
    /// Background picture (drawn as the input's own frame, cropped to fill).
    var backgroundPath: String = ""
    /// Or another input as the background (full-frame layer below the presenter).
    var backgroundInputID: UUID? = nil
    /// Chroma-keyed presenter (the key is that input's own Colour Key settings).
    var presenterInputID: UUID? = nil
    /// Presenter box: centre x, bottom edge and height (fractions of the frame; the box has the
    /// frame's aspect ratio and the presenter is fitted inside it).
    var presenterX: Double = 0.5
    var presenterBottom: Double = 1.0
    var presenterScale: Double = 0.8
    /// Preset the placement came from ("custom" after manual changes).
    var preset: String = VirtualSetPreset.centre.rawValue
    /// Foreground picture with alpha in front of the presenter (desk), full frame.
    var foregroundPath: String = ""
    /// Or another input in front of the presenter (full-frame layer).
    var foregroundInputID: UUID? = nil

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = VirtualSetSettings()
        func v<T: Decodable>(_ k: CodingKeys, _ f: T) -> T { ((try? c.decodeIfPresent(T.self, forKey: k)) ?? nil) ?? f }
        backgroundPath = v(.backgroundPath, d.backgroundPath)
        backgroundInputID = v(.backgroundInputID, d.backgroundInputID)
        presenterInputID = v(.presenterInputID, d.presenterInputID)
        presenterX = v(.presenterX, d.presenterX)
        presenterBottom = v(.presenterBottom, d.presenterBottom)
        presenterScale = v(.presenterScale, d.presenterScale)
        preset = v(.preset, d.preset)
        foregroundPath = v(.foregroundPath, d.foregroundPath)
        foregroundInputID = v(.foregroundInputID, d.foregroundInputID)
    }

    mutating func apply(_ p: VirtualSetPreset) {
        let pl = p.placement
        presenterX = pl.x; presenterBottom = pl.bottom; presenterScale = pl.scale
        preset = p.rawValue
    }

    /// Presenter box (normalised, top-left origin).
    var presenterRect: CGRect {
        let s = min(max(presenterScale, 0.05), 3)
        return CGRect(x: presenterX - s / 2, y: presenterBottom - s, width: s, height: s)
    }
}

// END SLIDE-CORE

// MARK: - App integration

/// Program resolution for inputs that render at output size (set by the engine when the render loop starts).
enum SlideOutput {
    private static let lock = NSLock()
    private static var store = CGSize(width: 1920, height: 1080)
    static var size: CGSize {
        get { lock.lock(); defer { lock.unlock() }; return store }
        set { lock.lock(); store = newValue; lock.unlock() }
    }
}

/// Shared base of the Photos and PDF Slides inputs.
/// UI binding: `settings` (live, no restart needed), `currentIndex`, `count`, `currentName`,
/// `contentGeneration` (bumps after a reload → re-request thumbnails), `next()`, `previous()`,
/// `select(_:)`, `thumbnail(_:maxPixel:completion:)`.
class SlideDeckInput: InputSource {
    @Published var settings: SlideSettings {
        didSet { if settings != oldValue { settingsChanged(from: oldValue) } }
    }
    @Published private(set) var currentIndex = 0
    @Published private(set) var count = 0
    @Published private(set) var currentName = ""
    @Published private(set) var contentGeneration = 0

    let renderer = SlideRenderer(size: SlideOutput.size)
    let thumbnails = SlideThumbnailCache()
    private var watcher: SlideFileWatcher?
    private var rateObserver: NSObjectProtocol?
    private let loadQueue = DispatchQueue(label: "hongmix.slides.load", qos: .userInitiated)
    private var started = false
    private var loadedOnce = false
    private(set) var source: SlideSource?

    override var alphaPremultiplied: Bool { true }

    override init(config: InputConfig) {
        settings = config.slides
        super.init(config: config)
        renderer.onFrame = { [weak self] pb in self?.video.store(pb) }
        renderer.onIndex = { [weak self] i, n in
            DispatchQueue.main.async { self?.indexChanged(i, n) }
        }
    }

    // Subclass hooks
    /// Off the main thread: builds the slides for `path` (nil + error text when it can't).
    func loadSource(path: String, settings: SlideSettings, previous: SlideSource?) -> (SlideSource?, String?) { (nil, nil) }
    /// Slide keys keep meaning the same picture across reloads (photos: file paths).
    var keepsCacheOnReload: Bool { false }
    /// Manual Next / Previous wrap around at the ends.
    var wrapsManually: Bool { false }
    func statusText(index: Int, count: Int) -> String { "\(index + 1) / \(count)" }
    var emptyStatus: String { "" }

    // MARK: public control (main thread)

    func next() { renderer.step(1, loop: wrapsManually) }
    func previous() { renderer.step(-1, loop: wrapsManually) }
    /// 0-based
    func select(_ index: Int, animated: Bool = true) { renderer.go(to: index, animated: animated) }

    /// Thumbnail of slide `index` (0-based) for the editor; completion on the main thread.
    func thumbnail(_ index: Int, maxPixel: Int = 256, completion: @escaping (CGImage?) -> Void) {
        thumbnails.thumbnail(index, maxPixel: maxPixel, completion: completion)
    }

    var expandedPath: String { (settings.path as NSString).expandingTildeInPath }

    // MARK: lifecycle

    override func start() {
        started = true
        applyRendererConfig()
        if rateObserver == nil {
            rateObserver = NotificationCenter.default.addObserver(forName: .hongMixRateConformChanged, object: nil,
                                                                  queue: .main) { [weak self] _ in
                self?.applyRendererConfig()
            }
        }
        reload(preferredIndex: settings.index, fromWatcher: false)
        startWatching()
    }

    override func stop() {
        // may be called off the main thread (replace/remove input)
        started = false
        watcher?.stop()
        watcher = nil
        if let o = rateObserver { NotificationCenter.default.removeObserver(o); rateObserver = nil }
        renderer.shutdown()
    }

    override func currentConfig() -> InputConfig {
        var c = super.currentConfig()
        c.slides = settings
        c.slides.index = currentIndex
        return c
    }

    func applyRendererConfig() {
        renderer.configure(size: SlideOutput.size, fill: settings.fill, style: settings.transition,
                           durationMs: settings.transitionMs, fps: VideoSlot.programFPS)
    }

    func settingsChanged(from old: SlideSettings) {
        guard started else { return }
        if settings.fill != old.fill || settings.transition != old.transition || settings.transitionMs != old.transitionMs {
            applyRendererConfig()
        }
        if settings.path != old.path {
            reload(preferredIndex: 0, fromWatcher: false, sameContent: false)
            startWatching()
        } else if settings.shuffle != old.shuffle {
            reload(preferredIndex: nil, fromWatcher: false)
        }
    }

    private func startWatching() {
        watcher?.stop()
        watcher = nil
        guard !settings.path.isEmpty else { return }
        watcher = SlideFileWatcher(path: expandedPath) { [weak self] in
            self?.reload(preferredIndex: nil, fromWatcher: true)
        }
    }

    /// Rescans / reopens. `preferredIndex` nil = stay on the current slide (same file / page number).
    func reload(preferredIndex: Int?, fromWatcher: Bool, sameContent: Bool = true) {
        let path = expandedPath, s = settings, prev = source
        let currentKey = prev.map { $0.key(currentIndex) }
        let currentIdx = currentIndex
        if path.isEmpty {
            source = nil
            renderer.setSource(nil, index: 0, keepCache: false)
            thumbnails.setSource(nil, clear: true)
            postStatus(Int32(MC_STATE_IDLE), emptyStatus)
            return
        }
        loadQueue.async { [weak self] in
            guard let self else { return }
            let (src, err) = self.loadSource(path: path, settings: s, previous: sameContent ? prev : nil)
            DispatchQueue.main.async {
                guard self.started else { return }
                if src == nil, fromWatcher, self.source != nil { return }   // half-written file: keep the old slides
                self.source = src
                let keep = sameContent && self.keepsCacheOnReload
                var target = preferredIndex ?? currentIdx
                if preferredIndex == nil, let k = currentKey, let src, let i = src.index(ofKey: k) { target = i }
                self.thumbnails.setSource(src, clear: !keep)
                self.renderer.setSource(src, index: target, keepCache: keep)
                self.contentGeneration += 1
                self.loadedOnce = true
                if let err {
                    self.postStatus(Int32(MC_STATE_ERROR), err)
                } else if (src?.count ?? 0) == 0 {
                    self.postStatus(Int32(MC_STATE_IDLE), self.emptyStatus)
                }
            }
        }
    }

    private func indexChanged(_ i: Int, _ n: Int) {
        if currentIndex != i { currentIndex = i }
        if count != n { count = n }
        let name = n > 0 ? (source?.name(i) ?? "") : ""
        if currentName != name { currentName = name }
        if n > 0 { postStatus(Int32(MC_STATE_RUNNING), statusText(index: i, count: n)) }
    }
}

/// vMix "Photos": a folder of pictures as a slideshow. Plays while `playing` (transport Play/Pause,
/// Auto Play / Auto Pause), loops when `looping`.
final class PhotosInput: SlideDeckInput {
    override var supportsTransport: Bool { true }
    override var keepsCacheOnReload: Bool { true }
    override var wrapsManually: Bool { true }
    override var emptyStatus: String { L("폴더에 사진이 없음") }

    override init(config: InputConfig) {
        super.init(config: config)
        renderer.onEnd = { [weak self] in DispatchQueue.main.async { self?.playing = false } }
    }

    override func statusText(index: Int, count: Int) -> String {
        Lf("사진 %@ / %@", "\(index + 1)", "\(count)")
    }

    override func loadSource(path: String, settings: SlideSettings, previous: SlideSource?) -> (SlideSource?, String?) {
        guard let files = SlideFolder.scan(path) else { return (nil, L("폴더를 열 수 없음")) }
        var rng = SystemRandomNumberGenerator()
        let prev = (previous as? PhotoSlideSource)?.files ?? []
        let ordered = SlideFolder.order(previous: settings.shuffle ? (prev.isEmpty ? files.shuffled() : prev) : [],
                                        scanned: files, shuffle: settings.shuffle, using: &rng)
        return (PhotoSlideSource(files: ordered), nil)
    }

    override func start() {
        super.start()
        applyTransport()
    }

    override func settingsChanged(from old: SlideSettings) {
        super.settingsChanged(from: old)
        if settings.seconds != old.seconds { applyTransport() }
    }

    override func applyTransport() {
        renderer.setAutoAdvance(seconds: playing ? max(0.5, settings.seconds) : nil, loop: looping)
    }

    override func pollPosition() {
        let n = renderer.count, sec = max(0.5, settings.seconds)
        let d = Double(n) * sec
        if duration != d { duration = d }
        let p = min(d, Double(renderer.index) * sec + (playing ? min(sec, renderer.elapsed) : 0))
        if abs(position - p) > 0.05 { position = p }
    }

    override func seek(seconds: Double) {
        select(Int(seconds / max(0.5, settings.seconds)))
    }

    override func restart() { select(0) }
}

/// PDF Slides (vMix "PowerPoint"): pages of a PDF exported from Keynote / PowerPoint / Google Slides.
final class PDFSlidesInput: SlideDeckInput {
    override var emptyStatus: String { L("PDF 파일을 선택하세요") }

    override func statusText(index: Int, count: Int) -> String {
        Lf("슬라이드 %@ / %@", "\(index + 1)", "\(count)")
    }

    override func loadSource(path: String, settings: SlideSettings, previous: SlideSource?) -> (SlideSource?, String?) {
        guard let s = PDFSlideSource(path: path) else { return (nil, L("PDF를 열 수 없음")) }
        return (s, nil)
    }
}

/// Virtual Set: background + chroma-keyed presenter + optional foreground, built with the existing
/// layer system instead of new Metal code:
///   * the input's own frame is the background picture (rendered once at output size, crop-to-fill);
///   * `layersSnapshot` adds generated layers in front of the user's layers: an optional background
///     input (full frame), the presenter input in its box (fit), an optional foreground input;
///     the engine's composeLayers draws them with each source's own picture settings — so the
///     presenter is keyed by its own Colour Key (Input Properties › Colour Key);
///   * a foreground picture (desk) is drawn last, full frame, through `topOverlayFrame`.
final class VirtualSetInput: InputSource {
    @Published var virtualSet: VirtualSetSettings {
        didSet {
            guard virtualSet != oldValue else { return }
            syncGenerated()
            if virtualSet.backgroundPath != oldValue.backgroundPath || virtualSet.foregroundPath != oldValue.foregroundPath {
                loadImages()
            } else {
                updateStatus()
            }
        }
    }
    private let vsLock = NSLock()
    private var generatedStore: [InputLayer] = []
    private var foregroundStore: CVPixelBuffer?
    private let backgroundLayerID = UUID(), presenterLayerID = UUID(), foregroundLayerID = UUID()
    private var rateObserver: NSObjectProtocol?
    private let loadQueue = DispatchQueue(label: "hongmix.virtualset.load", qos: .userInitiated)
    private var loadGeneration = 0
    private var imageError: String?

    override var alphaPremultiplied: Bool { true }

    override init(config: InputConfig) {
        virtualSet = config.virtualSet
        super.init(config: config)
        syncGenerated()
    }

    override var layersSnapshot: [InputLayer] {
        vsLock.lock(); let g = generatedStore; vsLock.unlock()
        return g + super.layersSnapshot
    }

    override var topOverlayFrame: CVPixelBuffer? {
        vsLock.lock(); defer { vsLock.unlock() }
        return foregroundStore
    }

    func applyPreset(_ p: VirtualSetPreset) { virtualSet.apply(p) }

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

    override func currentConfig() -> InputConfig {
        var c = super.currentConfig()
        c.virtualSet = virtualSet
        return c
    }

    /// The generated layers (main thread; read by the render thread through `layersSnapshot`).
    private func syncGenerated() {
        let v = virtualSet
        var g: [InputLayer] = []
        if let b = v.backgroundInputID, b != id {
            var l = InputLayer(inputID: b, x: 0, y: 0, w: 1, h: 1, fill: true)
            l.id = backgroundLayerID
            g.append(l)
        }
        if let p = v.presenterInputID, p != id {
            let r = v.presenterRect
            var l = InputLayer(inputID: p, x: r.minX, y: r.minY, w: r.width, h: r.height, fill: false)
            l.id = presenterLayerID
            g.append(l)
        }
        if let f = v.foregroundInputID, f != id {
            var l = InputLayer(inputID: f, x: 0, y: 0, w: 1, h: 1, fill: false)
            l.id = foregroundLayerID
            g.append(l)
        }
        vsLock.lock(); generatedStore = g; vsLock.unlock()
    }

    /// Background and foreground pictures at output size (off the main thread).
    private func loadImages() {
        loadGeneration += 1
        let gen = loadGeneration, v = virtualSet, size = SlideOutput.size
        loadQueue.async { [weak self] in
            guard let self else { return }
            var error: String?
            let pool = PixelBufferFactory.makePool(width: Int(size.width), height: Int(size.height), minimumCount: 1)
            var bg: CVPixelBuffer?
            if let pool, let pb = PixelBufferFactory.makeBuffer(pool: pool) {
                let path = (v.backgroundPath as NSString).expandingTildeInPath
                let img = path.isEmpty ? nil : SlideImage.decode(path, target: size, fill: true)
                if !path.isEmpty && img == nil { error = L("배경 이미지를 열 수 없음") }
                SlidePixels.draw(pb, clear: CGColor(gray: 0, alpha: 1)) { ctx, sz in
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
                self.vsLock.lock(); self.foregroundStore = fg; self.vsLock.unlock()
                if let bg { self.video.store(bg) }
                self.imageError = error
                self.updateStatus()
            }
        }
    }

    private func updateStatus() {
        if let e = imageError { postStatus(Int32(MC_STATE_ERROR), e); return }
        if virtualSet.presenterInputID == nil {
            postStatus(Int32(MC_STATE_RUNNING), L("발표자 입력을 선택하세요"))
        } else {
            let s = SlideOutput.size
            postStatus(Int32(MC_STATE_RUNNING), L("가상 세트") + " · \(Int(s.width))×\(Int(s.height))")
        }
    }
}
