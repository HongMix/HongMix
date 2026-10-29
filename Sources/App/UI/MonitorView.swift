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
    }

    /// Display thread. Encodes into `cmd` if there is something new to show.
    func render(into cmd: MTLCommandBuffer, cache: CVMetalTextureCache, now: CFTimeInterval, keep: inout [CVMetalTexture]) -> CAMetalDrawable? {
        lock.lock()
        let size = _size
        let src = _source
        lock.unlock()
        guard size.width >= 2, size.height >= 2, let pipeline = MonitorRenderer.sharedPipeline else { return nil }
        if fps < 50 && now - lastDraw < 1.0 / Double(max(1, fps)) - 0.002 { return nil }
        let frame = src()
        if let f = frame, f === lastFrame, size == lastSize { return nil }   // nothing new
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
            enc.setRenderPipelineState(pipeline)
            enc.setFragmentTexture(tex.luma, index: 0)
            enc.setFragmentTexture(tex.chroma ?? tex.luma, index: 1)
            var fit = SIMD4<Float>(Float(tex.width), Float(tex.height), Float(size.width), Float(size.height))
            enc.setFragmentBytes(&fit, length: MemoryLayout<SIMD4<Float>>.stride, index: 0)
            var lp = LayerParams()
            lp.yuv = tex.yuv
            enc.setFragmentBytes(&lp, length: MemoryLayout<LayerParams>.stride, index: 1)
            enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        }
        enc.endEncoding()
        lastFrame = frame
        lastSize = size
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
    private var thread: Thread?

    private init() {
        let dev = MetalContext.shared.device
        queue = dev.makeCommandQueue()!
        queue.label = "BraceletMix.monitors"
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
        guard thread == nil else { return }
        let t = Thread { [weak self] in self?.run() }
        t.name = "BraceletMix.monitors"
        t.qualityOfService = .userInteractive
        thread = t
        t.start()
    }

    private func run() {
        var tick: Int = 0
        while true {
            let start = CACurrentMediaTime()
            let hz = Double(NSScreen.main?.maximumFramesPerSecond ?? 60)
            let period = 1.0 / max(30, min(120, hz))
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
            tick += 1
            if tick % 600 == 0 { CVMetalTextureCacheFlush(cache, 0) }
            let left = period - (CACurrentMediaTime() - start)
            if left > 0 { Thread.sleep(forTimeInterval: left) }
        }
    }
}

/// NSView hosting a CAMetalLayer that the display thread draws into.
final class MonitorLayerView: NSView {
    let metalLayer = CAMetalLayer()
    var renderer: MonitorRenderer?

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
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        updateSize()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let r = renderer {
            if window != nil { MonitorDisplayLoop.shared.add(r) } else { MonitorDisplayLoop.shared.remove(r) }
        }
        updateSize()
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
    let source: () -> CVPixelBuffer?

    func makeNSView(context: Context) -> MonitorLayerView {
        let v = MonitorLayerView(frame: .zero)
        let r = MonitorRenderer(layer: v.metalLayer, fps: fps, source: source)
        r.countDraws = countDraws
        v.renderer = r
        return v
    }

    func updateNSView(_ v: MonitorLayerView, context: Context) {
        v.renderer?.source = source
        v.renderer?.fps = fps
    }

    static func dismantleNSView(_ v: MonitorLayerView, coordinator: ()) {
        if let r = v.renderer { MonitorDisplayLoop.shared.remove(r) }
    }
}
