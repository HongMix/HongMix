import Foundation
import Metal
import CoreVideo
import IOSurface
import CoreGraphics
import CoreText

/// Must match `LayerParams` in Mixer.metal (6 Int32, 22 Float, keyOn Int32 + 6 Float, yuv Int32 — same order).
struct LayerParams {
    var has: Int32 = 0
    var premul: Int32 = 0
    var mirror: Int32 = 0
    var deinterlace: Int32 = 0
    var sharpen: Int32 = 0
    var hasCC: Int32 = 0
    var srcW: Float = 1
    var srcH: Float = 1
    var zoom: Float = 1
    var panX: Float = 0
    var panY: Float = 0
    var cropL: Float = 0
    var cropT: Float = 0
    var cropR: Float = 0
    var cropB: Float = 0
    var alpha: Float = 1
    var mixAlpha: Float = 1
    var gainR: Float = 1
    var gainG: Float = 1
    var gainB: Float = 1
    var gammaR: Float = 1
    var gammaG: Float = 1
    var gammaB: Float = 1
    var liftR: Float = 0
    var liftG: Float = 0
    var liftB: Float = 0
    var saturation: Float = 1
    var hue: Float = 0
    var keyOn: Int32 = 0
    var keyR: Float = 0
    var keyG: Float = 0.69
    var keyB: Float = 0.25
    var keyTol: Float = 0.12
    var keySoft: Float = 0.08
    var keySpill: Float = 0.5
    var yuv: Int32 = 0      // 0 BGRA, 1 NV12 709 video, 2 NV12 601 video, 3 709 full, 4 601 full
}

/// Must match `MixParams` in Mixer.metal.
struct MixParams {
    var t: Float = 0
    var transition: Int32 = 0
    var ftb: Float = 0
    var outW: Float = 0
    var outH: Float = 0
}

/// Must match `TileParams` in Mixer.metal.
struct TileParams {
    var x: Float = 0
    var y: Float = 0
    var w: Float = 0
    var h: Float = 0
    var borderR: Float = 0
    var borderG: Float = 0
    var borderB: Float = 0
    var border: Float = 0
}

/// Must match `ComposeParams` in Mixer.metal.
struct ComposeParams {
    var w: Float = 0
    var h: Float = 0
    var border: Float = 0
    var borderR: Float = 1
    var borderG: Float = 1
    var borderB: Float = 1
}

/// One layer of an input composition (pixels, top-left origin).
struct ComposeLayer {
    var buffer: CVPixelBuffer?
    var params: LayerParams
    var rect: CGRect
    var border: Float = 0
    var borderColor: (Float, Float, Float) = (1, 1, 1)
}

/// One source for the program mixer (layer slots: 0 A, 1 B, 2-5 overlays, 6 stinger).
struct LayerInput {
    var buffer: CVPixelBuffer?
    var params: LayerParams
    static let empty = LayerInput(buffer: nil, params: LayerParams())
}

/// One rectangle of a bus / MultiView frame.
struct TileSpec {
    var buffer: CVPixelBuffer?
    var params: LayerParams
    var rect: CGRect                    // pixels, top-left origin
    var borderColor: (Float, Float, Float) = (0, 0, 0)
    var borderWidth: Float = 0
    var label: String? = nil
}

/// Shared Metal objects (device, library, texture cache).
final class MetalContext {
    static let shared = MetalContext()

    let device: MTLDevice
    let queue: MTLCommandQueue
    let library: MTLLibrary
    let textureCache: CVMetalTextureCache

    private init() {
        guard let dev = MTLCreateSystemDefaultDevice(), let q = dev.makeCommandQueue(),
              let lib = MetalContext.loadLibrary(dev) else {
            fatalError(L("Metal을 초기화할 수 없습니다"))
        }
        device = dev
        queue = q
        library = lib
        var cache: CVMetalTextureCache?
        CVMetalTextureCacheCreate(kCFAllocatorDefault, nil, dev, nil, &cache)
        guard let c = cache else { fatalError(L("CVMetalTextureCache 생성 실패")) }
        textureCache = c
    }

    /// Xcode builds ship a precompiled default.metallib; command-line builds ship Mixer.metal and compile it at launch.
    private static func loadLibrary(_ dev: MTLDevice) -> MTLLibrary? {
        if let lib = dev.makeDefaultLibrary(), lib.functionNames.contains("mixKernel") { return lib }
        guard let url = Bundle.main.url(forResource: "Mixer", withExtension: "metal"),
              let src = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        do {
            return try dev.makeLibrary(source: src, options: nil)
        } catch {
            NSLog("Mixer.metal compile error: \(error)")
            return nil
        }
    }

    /// Read-only texture view of a BGRA pixel buffer. Keep the returned CVMetalTexture alive until the GPU is done.
    func texture(for pb: CVPixelBuffer) -> (MTLTexture, CVMetalTexture)? {
        let w = CVPixelBufferGetWidth(pb), h = CVPixelBufferGetHeight(pb)
        guard CVPixelBufferGetPixelFormatType(pb) == kCVPixelFormatType_32BGRA else { return nil }
        var cvTex: CVMetalTexture?
        let r = CVMetalTextureCacheCreateTextureFromImage(kCFAllocatorDefault, textureCache, pb, nil,
                                                          .bgra8Unorm, w, h, 0, &cvTex)
        guard r == kCVReturnSuccess, let cv = cvTex, let tex = CVMetalTextureGetTexture(cv) else { return nil }
        return (tex, cv)
    }

    /// Textures for one source frame: BGRA → one texture; NV12 (decoder output) → luma + CbCr planes
    /// sampled and converted in the shader. `keep` must stay alive until the GPU is done.
    struct SourceTextures {
        let luma: MTLTexture
        let chroma: MTLTexture?
        let yuv: Int32
        let keep: [CVMetalTexture]
        var width: Int { luma.width }
        var height: Int { luma.height }
    }

    static func sourceTextures(for pb: CVPixelBuffer, cache: CVMetalTextureCache) -> SourceTextures? {
        let fmt = CVPixelBufferGetPixelFormatType(pb)
        let w = CVPixelBufferGetWidth(pb), h = CVPixelBufferGetHeight(pb)
        func tex(_ plane: Int, _ pf: MTLPixelFormat, _ pw: Int, _ ph: Int) -> (MTLTexture, CVMetalTexture)? {
            var cv: CVMetalTexture?
            let r = CVMetalTextureCacheCreateTextureFromImage(kCFAllocatorDefault, cache, pb, nil, pf, pw, ph, plane, &cv)
            guard r == kCVReturnSuccess, let c = cv, let t = CVMetalTextureGetTexture(c) else { return nil }
            return (t, c)
        }
        switch fmt {
        case kCVPixelFormatType_32BGRA:
            guard let t = tex(0, .bgra8Unorm, w, h) else { return nil }
            return SourceTextures(luma: t.0, chroma: nil, yuv: 0, keep: [t.1])
        case kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, kCVPixelFormatType_420YpCbCr8BiPlanarFullRange:
            guard let y = tex(0, .r8Unorm, w, h),
                  let c = tex(1, .rg8Unorm, CVPixelBufferGetWidthOfPlane(pb, 1), CVPixelBufferGetHeightOfPlane(pb, 1)) else {
                return nil
            }
            let full = fmt == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
            var is601 = h < 720
            if let m = CVBufferCopyAttachment(pb, kCVImageBufferYCbCrMatrixKey, nil) as? String {
                is601 = m == (kCVImageBufferYCbCrMatrix_ITU_R_601_4 as String) ||
                    m == (kCVImageBufferYCbCrMatrix_SMPTE_240M_1995 as String)
            }
            let code: Int32 = full ? (is601 ? 4 : 3) : (is601 ? 2 : 1)
            return SourceTextures(luma: y.0, chroma: c.0, yuv: code, keep: [y.1, c.1])
        default:
            return nil
        }
    }

    /// Writable texture aliasing an IOSurface-backed pixel buffer.
    func writableTexture(for pb: CVPixelBuffer) -> MTLTexture? {
        guard let surfRef = CVPixelBufferGetIOSurface(pb) else { return nil }
        let surface = surfRef.takeUnretainedValue()
        let desc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm,
                                                            width: CVPixelBufferGetWidth(pb),
                                                            height: CVPixelBufferGetHeight(pb),
                                                            mipmapped: false)
        desc.usage = [.shaderRead, .shaderWrite, .renderTarget]
        desc.storageMode = .shared
        return device.makeTexture(descriptor: desc, iosurface: surface, plane: 0)
    }
}

/// GPU compositor: program mix (A/B transition, 4 overlays, FTB, stinger) and tile renders for
/// auxiliary buses and MultiView.
final class MetalMixer {
    static let layerCount = 7

    let format: VideoFormat
    private let ctx = MetalContext.shared
    private let mixPipeline: MTLComputePipelineState
    private let tilePipeline: MTLComputePipelineState
    private var composePipeline: MTLRenderPipelineState?
    private let pool: CVPixelBufferPool
    private let dummy: MTLTexture
    /// Own command queue: the mix never waits behind the UI monitors' draw calls.
    private let queue: MTLCommandQueue
    private let readCache: CVMetalTextureCache
    /// Writable textures for the pool's IOSurfaces (the pool recycles a handful of surfaces,
    /// so we build each MTLTexture once instead of every frame).
    private var outTextures: [IOSurfaceID: MTLTexture] = [:]

    init?(format: VideoFormat) {
        self.format = format
        guard let fn = ctx.library.makeFunction(name: "mixKernel"),
              let tfn = ctx.library.makeFunction(name: "tileKernel"),
              let pso = try? ctx.device.makeComputePipelineState(function: fn),
              let tpso = try? ctx.device.makeComputePipelineState(function: tfn),
              let pool = PixelBufferFactory.makePool(width: format.width, height: format.height, minimumCount: 12) else {
            return nil
        }
        guard let q = ctx.device.makeCommandQueue() else { return nil }
        q.label = "BraceletMix.mixer"
        queue = q
        var cache: CVMetalTextureCache?
        CVMetalTextureCacheCreate(kCFAllocatorDefault, nil, ctx.device, nil, &cache)
        guard let rc = cache else { return nil }
        readCache = rc
        mixPipeline = pso
        tilePipeline = tpso
        self.pool = pool
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: 2, height: 2, mipmapped: false)
        d.usage = [.shaderRead]
        guard let tex = ctx.device.makeTexture(descriptor: d) else { return nil }
        let zeros = [UInt8](repeating: 0, count: 16)
        zeros.withUnsafeBytes { raw in
            tex.replace(region: MTLRegionMake2D(0, 0, 2, 2), mipmapLevel: 0, withBytes: raw.baseAddress!, bytesPerRow: 8)
        }
        dummy = tex
        let rd = MTLRenderPipelineDescriptor()
        rd.vertexFunction = ctx.library.makeFunction(name: "displayVertex")
        rd.fragmentFunction = ctx.library.makeFunction(name: "composeFragment")
        let ca = rd.colorAttachments[0]!
        ca.pixelFormat = .bgra8Unorm
        ca.isBlendingEnabled = true
        ca.rgbBlendOperation = .add; ca.alphaBlendOperation = .add
        ca.sourceRGBBlendFactor = .one; ca.sourceAlphaBlendFactor = .one
        ca.destinationRGBBlendFactor = .oneMinusSourceAlpha; ca.destinationAlphaBlendFactor = .oneMinusSourceAlpha
        composePipeline = try? ctx.device.makeRenderPipelineState(descriptor: rd)
    }

    /// Input with layers → one premultiplied BGRA frame (transparent where nothing is drawn).
    func compose(_ layers: [ComposeLayer]) -> CVPixelBuffer? {
        guard let pso = composePipeline, let out = PixelBufferFactory.makeBuffer(pool: pool),
              let outTex = outputTexture(out), let cmd = queue.makeCommandBuffer() else { return nil }
        let rp = MTLRenderPassDescriptor()
        rp.colorAttachments[0].texture = outTex
        rp.colorAttachments[0].loadAction = .clear
        rp.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        rp.colorAttachments[0].storeAction = .store
        guard let enc = cmd.makeRenderCommandEncoder(descriptor: rp) else { return nil }
        enc.setRenderPipelineState(pso)
        var keep: [CVMetalTexture] = []
        let W = Double(format.width), H = Double(format.height)
        for l in layers {
            guard let pb = l.buffer, let src = inputTexture(pb) else { continue }
            let r = l.rect.integral
            let x0 = max(0, r.minX), y0 = max(0, r.minY), x1 = min(W, r.maxX), y1 = min(H, r.maxY)
            guard x1 > x0, y1 > y0, r.width >= 1, r.height >= 1 else { continue }
            keep.append(contentsOf: src.keep)
            var lp = l.params
            lp.has = 1; lp.yuv = src.yuv
            lp.srcW = Float(src.width); lp.srcH = Float(src.height)
            var cp = ComposeParams(w: Float(r.width), h: Float(r.height), border: l.border,
                                   borderR: l.borderColor.0, borderG: l.borderColor.1, borderB: l.borderColor.2)
            enc.setViewport(MTLViewport(originX: r.minX, originY: r.minY, width: r.width, height: r.height, znear: 0, zfar: 1))
            enc.setScissorRect(MTLScissorRect(x: Int(x0), y: Int(y0), width: Int(x1 - x0), height: Int(y1 - y0)))
            enc.setFragmentTexture(src.luma, index: 0)
            enc.setFragmentTexture(src.chroma ?? dummy, index: 1)
            enc.setFragmentBytes(&lp, length: MemoryLayout<LayerParams>.stride, index: 0)
            enc.setFragmentBytes(&cp, length: MemoryLayout<ComposeParams>.stride, index: 1)
            enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        }
        enc.endEncoding()
        cmd.commit()
        cmd.waitUntilCompleted()
        keep.removeAll()
        return out
    }

    // MARK: 3D LUT pre-pass (inputs with a .cube LUT)

    private lazy var lutPipeline: MTLComputePipelineState? = {
        guard let fn = ctx.library.makeFunction(name: "lutKernel") else { return nil }
        return try? ctx.device.makeComputePipelineState(function: fn)
    }()
    private var lutPools: [Int: CVPixelBufferPool] = [:]

    /// Source frame through a LUT → premultiplied BGRA frame of the same size.
    func applyLUT(_ pb: CVPixelBuffer, lut: CubeLUT, strength: Float, premultiplied: Bool) -> CVPixelBuffer? {
        guard let pso = lutPipeline, let src = inputTexture(pb) else { return nil }
        let w = src.width, h = src.height
        let key = w << 16 | h
        if lutPools[key] == nil {
            if lutPools.count > 8 { lutPools.removeAll() }
            lutPools[key] = PixelBufferFactory.makePool(width: w, height: h, minimumCount: 4)
        }
        guard let pool = lutPools[key], let out = PixelBufferFactory.makeBuffer(pool: pool),
              let outTex = outputTexture(out), let cmd = queue.makeCommandBuffer(),
              let enc = cmd.makeComputeCommandEncoder() else { return nil }
        var lp = LayerParams()
        lp.has = 1; lp.yuv = src.yuv
        lp.srcW = Float(w); lp.srcH = Float(h)
        var up = LutParams(strength: strength, size: Float(lut.size), premul: premultiplied ? 1 : 0,
                           dminR: lut.domainMin.x, dminG: lut.domainMin.y, dminB: lut.domainMin.z,
                           dmaxR: lut.domainMax.x, dmaxG: lut.domainMax.y, dmaxB: lut.domainMax.z)
        enc.setComputePipelineState(pso)
        enc.setTexture(src.luma, index: 0)
        enc.setTexture(outTex, index: 1)
        enc.setTexture(src.chroma ?? dummy, index: 2)
        enc.setTexture(lut.texture, index: 3)
        enc.setBytes(&lp, length: MemoryLayout<LayerParams>.stride, index: 0)
        enc.setBytes(&up, length: MemoryLayout<LutParams>.stride, index: 1)
        let tg = threadgroup(pso)
        enc.dispatchThreadgroups(MTLSize(width: (w + tg.width - 1) / tg.width, height: (h + tg.height - 1) / tg.height, depth: 1),
                                 threadsPerThreadgroup: tg)
        enc.endEncoding()
        cmd.commit()
        cmd.waitUntilCompleted()
        _ = src.keep
        return out
    }

    private func outputTexture(_ pb: CVPixelBuffer) -> MTLTexture? {
        guard let surf = CVPixelBufferGetIOSurface(pb)?.takeUnretainedValue() else { return nil }
        let id = IOSurfaceGetID(surf)
        if let t = outTextures[id], t.iosurface === surf { return t }
        guard let t = ctx.writableTexture(for: pb) else { return nil }
        if outTextures.count > 64 { outTextures.removeAll() }
        outTextures[id] = t
        return t
    }

    private func inputTexture(_ pb: CVPixelBuffer) -> MetalContext.SourceTextures? {
        MetalContext.sourceTextures(for: pb, cache: readCache)
    }

    private func threadgroup(_ pso: MTLComputePipelineState) -> MTLSize {
        let tw = pso.threadExecutionWidth
        return MTLSize(width: tw, height: max(1, pso.maxTotalThreadsPerThreadgroup / tw), depth: 1)
    }

    /// Program mix. `layers` must have `layerCount` entries. Blocks until the GPU is done.
    func render(layers: [LayerInput], t: Float, transition: Int32, ftb: Float) -> CVPixelBuffer? {
        guard let out = PixelBufferFactory.makeBuffer(pool: pool), let outTex = outputTexture(out),
              let cmd = queue.makeCommandBuffer(), let enc = cmd.makeComputeCommandEncoder() else {
            return nil
        }
        var keep: [CVMetalTexture] = []
        var params = [LayerParams](repeating: LayerParams(), count: MetalMixer.layerCount)
        enc.setComputePipelineState(mixPipeline)
        for i in 0..<MetalMixer.layerCount {
            var lp = i < layers.count ? layers[i].params : LayerParams()
            if i < layers.count, let pb = layers[i].buffer, let src = inputTexture(pb) {
                keep.append(contentsOf: src.keep)
                enc.setTexture(src.luma, index: i)
                enc.setTexture(src.chroma ?? dummy, index: 8 + i)
                lp.has = 1
                lp.yuv = src.yuv
                lp.srcW = Float(src.width)
                lp.srcH = Float(src.height)
            } else {
                enc.setTexture(dummy, index: i)
                enc.setTexture(dummy, index: 8 + i)
                lp.has = 0
            }
            params[i] = lp
        }
        enc.setTexture(outTex, index: MetalMixer.layerCount)
        var mp = MixParams(t: t, transition: transition, ftb: ftb,
                           outW: Float(format.width), outH: Float(format.height))
        enc.setBytes(&mp, length: MemoryLayout<MixParams>.stride, index: 0)
        params.withUnsafeBytes { raw in
            enc.setBytes(raw.baseAddress!, length: raw.count, index: 1)
        }
        enc.dispatchThreads(MTLSize(width: format.width, height: format.height, depth: 1),
                            threadsPerThreadgroup: threadgroup(mixPipeline))
        enc.endEncoding()
        cmd.commit()
        cmd.waitUntilCompleted()
        keep.removeAll()
        return out
    }

    /// Renders tiles into a new frame (black background). Labels are drawn on the CPU afterwards.
    func renderTiles(_ tiles: [TileSpec]) -> CVPixelBuffer? {
        guard let out = PixelBufferFactory.makeBuffer(pool: pool), let outTex = outputTexture(out),
              let cmd = queue.makeCommandBuffer(), let enc = cmd.makeComputeCommandEncoder() else {
            return nil
        }
        var keep: [CVMetalTexture] = []
        enc.setComputePipelineState(tilePipeline)
        // full-frame black first
        var all = [TileSpec(buffer: nil, params: LayerParams(),
                            rect: CGRect(x: 0, y: 0, width: format.width, height: format.height))]
        all.append(contentsOf: tiles)
        for tile in all {
            var lp = tile.params
            if let pb = tile.buffer, let src = inputTexture(pb) {
                keep.append(contentsOf: src.keep)
                enc.setTexture(src.luma, index: 0)
                enc.setTexture(src.chroma ?? dummy, index: 2)
                lp.has = 1
                lp.yuv = src.yuv
                lp.srcW = Float(src.width)
                lp.srcH = Float(src.height)
            } else {
                enc.setTexture(dummy, index: 0)
                enc.setTexture(dummy, index: 2)
                lp.has = 0
            }
            enc.setTexture(outTex, index: 1)
            let r = tile.rect.integral
            var tp = TileParams(x: Float(r.minX), y: Float(r.minY), w: Float(r.width), h: Float(r.height),
                                borderR: tile.borderColor.0, borderG: tile.borderColor.1, borderB: tile.borderColor.2,
                                border: tile.borderWidth)
            enc.setBytes(&tp, length: MemoryLayout<TileParams>.stride, index: 0)
            enc.setBytes(&lp, length: MemoryLayout<LayerParams>.stride, index: 1)
            enc.dispatchThreads(MTLSize(width: max(1, Int(r.width)), height: max(1, Int(r.height)), depth: 1),
                                threadsPerThreadgroup: threadgroup(tilePipeline))
        }
        enc.endEncoding()
        cmd.commit()
        cmd.waitUntilCompleted()
        keep.removeAll()
        let labeled = tiles.filter { $0.label != nil }
        if !labeled.isEmpty { drawLabels(labeled, into: out) }
        return out
    }

    private func drawLabels(_ tiles: [TileSpec], into pb: CVPixelBuffer) {
        CVPixelBufferLockBaseAddress(pb, [])
        defer { CVPixelBufferUnlockBaseAddress(pb, []) }
        guard let base = CVPixelBufferGetBaseAddress(pb) else { return }
        let w = CVPixelBufferGetWidth(pb), h = CVPixelBufferGetHeight(pb)
        let info = CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        guard let cg = CGContext(data: base, width: w, height: h, bitsPerComponent: 8,
                                 bytesPerRow: CVPixelBufferGetBytesPerRow(pb),
                                 space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: info) else { return }
        let fontSize = CGFloat(h) / 45
        let font = CTFontCreateWithName("Helvetica-Bold" as CFString, fontSize, nil)
        for tile in tiles {
            guard let text = tile.label else { continue }
            let attrs: [NSAttributedString.Key: Any] = [
                NSAttributedString.Key(kCTFontAttributeName as String): font,
                NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(gray: 1, alpha: 1),
            ]
            let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attrs))
            let bounds = CTLineGetBoundsWithOptions(line, [])
            let r = tile.rect
            // CG origin is bottom-left
            let barH = fontSize * 1.5
            let barRect = CGRect(x: r.minX, y: CGFloat(h) - r.maxY, width: min(r.width, bounds.width + fontSize), height: barH)
            cg.setFillColor(CGColor(gray: 0, alpha: 0.65))
            cg.fill(barRect)
            cg.textPosition = CGPoint(x: barRect.minX + fontSize * 0.5, y: barRect.minY + fontSize * 0.4)
            CTLineDraw(line, cg)
        }
    }

    func flushCache() {
        CVMetalTextureCacheFlush(readCache, 0)
    }
}

/// Simple layout for MultiView: preview + output on top, up to 8 inputs below.
enum MultiViewLayout {
    static func rects(width: Int, height: Int) -> (preview: CGRect, program: CGRect, small: [CGRect]) {
        let W = CGFloat(width), H = CGFloat(height)
        let topH = H * 0.5
        let preview = CGRect(x: 0, y: 0, width: W / 2, height: topH)
        let program = CGRect(x: W / 2, y: 0, width: W / 2, height: topH)
        var small: [CGRect] = []
        let cols = 4, rows = 2
        let cw = W / CGFloat(cols), ch = (H - topH) / CGFloat(rows)
        for r in 0..<rows {
            for c in 0..<cols {
                small.append(CGRect(x: CGFloat(c) * cw, y: topH + CGFloat(r) * ch, width: cw, height: ch))
            }
        }
        return (preview, program, small)
    }
}
