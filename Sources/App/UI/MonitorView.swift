import SwiftUI
import AppKit
import Metal
import QuartzCore
import CoreVideo

/// On-screen monitors (Preview, Output, input thumbnails, fullscreen) are drawn by one background
/// display thread straight into CAMetalLayers. Nothing here runs on the main thread, so the UI,
/// web pages and buttons never make the monitors stutter (and vice versa).
final class MonitorRenderer {
    private static var sharedPipeline: MTLRenderPipelineState?
    private static var tilePipeline: MTLRenderPipelineState?
    private static var drawCount = 0
    private(set) static var drawsPerSecond = 0
    static func publishDrawStats() {
        MonitorDisplayLoop.shared.lock.lock()
        drawsPerSecond = drawCount
        drawCount = 0
        MonitorDisplayLoop.shared.lock.unlock()
    }

    let layer: CAMetalLayer
    var countDraws = false
    var fps: Int
    private let lock = NSLock()
    private var _source: () -> CVPixelBuffer?
    /// Optional: place the frame like Program does (input tiles). nil = plain fit.
    private var _placement: (() -> VideoAdjust?)?
    private var lastPlacement: VideoAdjust?
    var placement: (() -> VideoAdjust?)? {
        get { lock.lock(); defer { lock.unlock() }; return _placement }
        set { lock.lock(); _placement = newValue; lock.unlock() }
    }
    private var _size: CGSize = .zero
    private var lastFrame: CVPixelBuffer?
    private var lastSize: CGSize = .zero
    private var lastDraw: CFTimeInterval = 0

    var source: () -> CVPixelBuffer? {
        get { lock.lock(); defer { lock.unlock() }; return _source }
        set { lock.lock(); _source = newValue; lock.unlock() }
    }

    /// Set from the main thread on layout.
    func setDrawableSize(_ s: CGSize) {
        lock.lock()
        _size = s
        lock.unlock()
    }

    init(layer: CAMetalLayer, fps: Int, source: @escaping () -> CVPixelBuffer?) {
        self.layer = layer
        self.fps = fps
        self._source = source
        let ctx = MetalContext.shared
        if MonitorRenderer.sharedPipeline == nil {
            let desc = MTLRenderPipelineDescriptor()
            desc.vertexFunction = ctx.library.makeFunction(name: "displayVertex")
            desc.fragmentFunction = ctx.library.makeFunction(name: "displayFragment")
            desc.colorAttachments[0].pixelFormat = .bgra8Unorm
            MonitorRenderer.sharedPipeline = try? ctx.device.makeRenderPipelineState(descriptor: desc)
        }
        if MonitorRenderer.tilePipeline == nil, let f = ctx.library.makeFunction(name: "tileFragment") {
            let desc = MTLRenderPipelineDescriptor()
            desc.vertexFunction = ctx.library.makeFunction(name: "displayVertex")
            desc.fragmentFunction = f
            desc.colorAttachments[0].pixelFormat = .bgra8Unorm
            MonitorRenderer.tilePipeline = try? ctx.device.makeRenderPipelineState(descriptor: desc)
        }
    }

    /// Display thread. Encodes into `cmd` if there is something new to show.
    func render(into cmd: MTLCommandBuffer, cache: CVMetalTextureCache, now: CFTimeInterval, keep: inout [CVMetalTexture]) -> CAMetalDrawable? {
        lock.lock()
        let size = _size
        let src = _source
        let placementSource = _placement
        lock.unlock()
        guard size.width >= 2, size.height >= 2, let pipeline = MonitorRenderer.sharedPipeline else { return nil }
        if fps < 50 && now - lastDraw < 1.0 / Double(max(1, fps)) - 0.002 { return nil }
        let frame = src()
        let placement = placementSource?().flatMap { $0.isIdentityPlacement ? nil : $0 }
        if let f = frame, f === lastFrame, size == lastSize, placement == lastPlacement { return nil }   // nothing new
        if frame == nil && lastFrame == nil && size == lastSize { return nil }
        if layer.drawableSize != size { layer.drawableSize = size }
        guard let drawable = layer.nextDrawable() else { return nil }
        let rpd = MTLRenderPassDescriptor()
        rpd.colorAttachments[0].texture = drawable.texture
        rpd.colorAttachments[0].loadAction = .clear
        rpd.colorAttachments[0].storeAction = .store
        rpd.colorAttachments[0].clearColor = MTLClearColor(red: 0.06, green: 0.06, blue: 0.07, alpha: 1)
        guard let enc = cmd.makeRenderCommandEncoder(descriptor: rpd) else { return nil }
        if let pb = frame, let tex = MetalContext.sourceTextures(for: pb, cache: cache) {
            keep.append(contentsOf: tex.keep)
            var lp: LayerParams
            if let a = placement, let tile = MonitorRenderer.tilePipeline {
                // Same placement maths as Program; colour/key stay off so the tile is quick and readable.
                var pa = a
                pa.resetColor(); pa.keyOn = false; pa.alpha = 1
                lp = pa.layerParams(premultiplied: false)
                lp.has = 1
                lp.srcW = Float(tex.width); lp.srcH = Float(tex.height)
                enc.setRenderPipelineState(tile)
            } else {
                lp = LayerParams()
                enc.setRenderPipelineState(pipeline)
            }
            enc.setFragmentTexture(tex.luma, index: 0)
            enc.setFragmentTexture(tex.chroma ?? tex.luma, index: 1)
            var fit = SIMD4<Float>(Float(tex.width), Float(tex.height), Float(size.width), Float(size.height))
            enc.setFragmentBytes(&fit, length: MemoryLayout<SIMD4<Float>>.stride, index: 0)
            lp.yuv = tex.yuv
            enc.setFragmentBytes(&lp, length: MemoryLayout<LayerParams>.stride, index: 1)
            enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        }
        enc.endEncoding()
        lastFrame = frame
        lastSize = size
        lastPlacement = placement
        lastDraw = now
        if countDraws {
            MonitorDisplayLoop.shared.lock.lock()
            MonitorRenderer.drawCount += 1
            MonitorDisplayLoop.shared.lock.unlock()
        }
        return drawable
    }
}

/// One thread drives every monitor at the display refresh rate.
final class MonitorDisplayLoop {
    static let shared = MonitorDisplayLoop()
    let lock = NSLock()
    private var renderers: [ObjectIdentifier: () -> MonitorRenderer?] = [:]
    private let queue: MTLCommandQueue
    private let cache: CVMetalTextureCache
    private var displayLink: CVDisplayLink?
    /// Last time the display link drew (CACurrentMediaTime; lock). A link whose display went to sleep,
    /// was unplugged or is on another Space stops calling back — the watchdog then draws instead.
    private var lastTick: CFTimeInterval = 0
    private var watchdog: DispatchSourceTimer?
    private var currentDisplay: CGDirectDisplayID = 0
    private var screenObservers: [NSObjectProtocol] = []

    private init() {
        let dev = MetalContext.shared.device
        queue = dev.makeCommandQueue()!
        queue.label = "HongMix.monitors"
        var c: CVMetalTextureCache?
        CVMetalTextureCacheCreate(kCFAllocatorDefault, nil, dev, nil, &c)
        cache = c!
    }

    func add(_ r: MonitorRenderer) {
        lock.lock()
        renderers[ObjectIdentifier(r)] = { [weak r] in r }
        lock.unlock()
        startIfNeeded()
    }

    func remove(_ r: MonitorRenderer) {
        lock.lock()
        renderers.removeValue(forKey: ObjectIdentifier(r))
        lock.unlock()
    }

    private func startIfNeeded() {
        guard displayLink == nil else { return }
        var link: CVDisplayLink?
        guard CVDisplayLinkCreateWithActiveCGDisplays(&link) == kCVReturnSuccess, let link else { return }
        let context = Unmanaged.passUnretained(self).toOpaque()
        CVDisplayLinkSetOutputCallback(link, { _, _, _, _, _, context in
            guard let context else { return kCVReturnError }
            Unmanaged<MonitorDisplayLoop>.fromOpaque(context).takeUnretainedValue().drawFrame()
            return kCVReturnSuccess
        }, context)
        displayLink = link
        CVDisplayLinkStart(link)
        followMainWindowScreen()
        // Re-target when a window changes screen or displays are added/removed/woken.
        let nc = NotificationCenter.default
        for name in [NSWindow.didChangeScreenNotification, NSWindow.didBecomeMainNotification,
                     NSApplication.didChangeScreenParametersNotification, NSWorkspace.screensDidWakeNotification] {
            let center = name == NSWorkspace.screensDidWakeNotification ? NSWorkspace.shared.notificationCenter : nc
            screenObservers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                self?.followMainWindowScreen()
            })
        }
        // Watchdog: if the link stops (display asleep / gone), keep drawing at ~60 Hz from a timer.
        let t = DispatchSource.makeTimerSource(queue: DispatchQueue(label: "HongMix.monitors.watchdog", qos: .userInteractive))
        t.schedule(deadline: .now() + 0.1, repeating: .milliseconds(16), leeway: .milliseconds(2))
        t.setEventHandler { [weak self] in
            guard let self else { return }
            self.lock.lock()
            let stalled = CACurrentMediaTime() - self.lastTick > 0.1
            self.lock.unlock()
            if stalled { self.drawFrame(fromWatchdog: true) }
        }
        t.resume()
        watchdog = t
    }

    /// Main thread: drive the monitors from the refresh clock of the screen the main window is on.
    private func followMainWindowScreen() {
        guard let link = displayLink else { return }
        let win = NSApp.mainWindow ?? NSApp.keyWindow ?? NSApp.windows.first { $0.isVisible && $0.screen != nil }
        guard let n = win?.screen?.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else { return }
        let id = CGDirectDisplayID(n.uint32Value)
        guard id != currentDisplay else { return }
        currentDisplay = id
        CVDisplayLinkSetCurrentCGDisplay(link, id)
        if !CVDisplayLinkIsRunning(link) { CVDisplayLinkStart(link) }
    }

    /// Called by CoreVideo on the display's real vertical-refresh clock. A free-running 60 Hz sleep
    /// loop beats against 59.94 media and produces a visible hitch even when decode/render drop 0.
    private let drawLock = NSLock()     // link and watchdog never draw at the same time
    private func drawFrame(fromWatchdog: Bool = false) {
        let start = CACurrentMediaTime()
        if !fromWatchdog {
            lock.lock(); lastTick = start; lock.unlock()
        }
        guard drawLock.try() else { return }
        defer { drawLock.unlock() }
        autoreleasepool {
            lock.lock()
            let list = renderers.values.compactMap { $0() }
            lock.unlock()
            guard !list.isEmpty, let cmd = queue.makeCommandBuffer() else { return }
            var keep: [CVMetalTexture] = []
            var drawables: [CAMetalDrawable] = []
            for r in list {
                if let d = r.render(into: cmd, cache: cache, now: start, keep: &keep) { drawables.append(d) }
            }
            if drawables.isEmpty { return }
            for d in drawables { cmd.present(d) }
            cmd.addCompletedHandler { _ in _ = keep }
            cmd.commit()
        }
    }
}

/// NSView hosting a CAMetalLayer that the display thread draws into.
final class MonitorLayerView: NSView {
    let metalLayer = CAMetalLayer()
    var renderer: MonitorRenderer?
    var visibilityChange: ((Bool) -> Void)?
    private var isMonitorVisible = false
    private var isRendererRegistered = false

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        metalLayer.device = MetalContext.shared.device
        metalLayer.pixelFormat = .bgra8Unorm
        metalLayer.framebufferOnly = true
        metalLayer.maximumDrawableCount = 3
        metalLayer.allowsNextDrawableTimeout = true
        metalLayer.backgroundColor = NSColor.black.cgColor
        metalLayer.needsDisplayOnBoundsChange = false
    }

    required init?(coder: NSCoder) { fatalError() }

    override func makeBackingLayer() -> CALayer { metalLayer }

    override func layout() {
        super.layout()
        updateSize()
        updateMonitorVisibility()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        updateSize()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        updateSize()
        updateMonitorVisibility()
    }

    private func updateMonitorVisibility() {
        let visible = window != nil && !visibleRect.isEmpty && visibleRect.width >= 2 && visibleRect.height >= 2
        if visible != isMonitorVisible {
            isMonitorVisible = visible
            visibilityChange?(visible)
        }
        guard let renderer, visible != isRendererRegistered else { return }
        isRendererRegistered = visible
        if visible { MonitorDisplayLoop.shared.add(renderer) }
        else { MonitorDisplayLoop.shared.remove(renderer) }
    }

    func stopMonitoring() {
        if isMonitorVisible { isMonitorVisible = false; visibilityChange?(false) }
        if isRendererRegistered, let renderer { MonitorDisplayLoop.shared.remove(renderer) }
        isRendererRegistered = false
    }

    private func updateSize() {
        let scale = window?.backingScaleFactor ?? 2
        metalLayer.contentsScale = scale
        renderer?.setDrawableSize(CGSize(width: bounds.width * scale, height: bounds.height * scale))
    }
}

struct MonitorView: NSViewRepresentable {
    let fps: Int
    var countDraws = false
    var onActiveChange: ((Bool) -> Void)? = nil
    /// Input tiles: show the input placed as in Program (fill/stretch, zoom, crop).
    var placement: (() -> VideoAdjust?)? = nil
    let source: () -> CVPixelBuffer?

    func makeNSView(context: Context) -> MonitorLayerView {
        let v = MonitorLayerView(frame: .zero)
        let r = MonitorRenderer(layer: v.metalLayer, fps: fps, source: source)
        r.countDraws = countDraws
        r.placement = placement
        v.renderer = r
        v.visibilityChange = onActiveChange
        return v
    }

    func updateNSView(_ v: MonitorLayerView, context: Context) {
        v.renderer?.source = source
        v.renderer?.placement = placement
        v.renderer?.fps = fps
        v.visibilityChange = onActiveChange
    }

    static func dismantleNSView(_ v: MonitorLayerView, coordinator: ()) {
        v.stopMonitoring()
    }
}
