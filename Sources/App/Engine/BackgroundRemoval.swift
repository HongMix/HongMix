import Foundation
import CoreImage
import CoreVideo
import Metal
import Vision
import QuartzCore

/// Input Properties › Key › AI background removal: keeps people, removes the rest — no green screen.
/// Uses macOS Vision person segmentation (Neural Engine) and Core Image on the GPU.
struct BGRemovalSettings: Codable, Equatable {
    var enabled = false
    /// 0 fast · 1 balanced · 2 accurate (accurate is not real-time on most Macs)
    var quality = 0          // Fast keeps up with 59.94p on M1-class Macs; Balanced ≈ 20 ms/frame
    /// edge softness 0…1
    var softness: Float = 0.4
    /// "transparent" (layers/overlays below show through), "blur" (blurred original), "image"
    var background = "transparent"
    var imagePath = ""

    init() {}
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = BGRemovalSettings()
        enabled = c.value(.enabled, d.enabled)
        quality = c.value(.quality, d.quality)
        softness = c.value(.softness, d.softness)
        background = c.value(.background, d.background)
        imagePath = c.value(.imagePath, d.imagePath)
    }
}

/// One per input. The render thread never waits for Vision: it hands over the newest source frame and
/// uses the newest finished result. Two stages run in parallel — Vision (Neural Engine) finds the person
/// in frame N while Core Image (GPU) composites frame N-1 — so throughput is the slower stage, not the sum.
final class BackgroundRemover {
    private let visionQueue = DispatchQueue(label: "hongmix.bgremoval.vision", qos: .userInteractive)
    private let compositeQueue = DispatchQueue(label: "hongmix.bgremoval.composite", qos: .userInteractive)
    private let lock = NSLock()
    private var visionBusy = false
    private var compositeBusy = false
    private var lastOut: CVPixelBuffer?
    private var lastSettings = BGRemovalSettings()
    private var lastSrc: CVPixelBuffer?
    private var pendingVision: (CVPixelBuffer, BGRemovalSettings)?
    private var pendingComposite: (CVPixelBuffer, CVPixelBuffer, BGRemovalSettings)?
    private var visionMs: Double = 0
    private var compositeMs: Double = 0
    private var visionRuns = 0          // the first runs load the model (≈100 ms) — not counted in the average
    private var compositeRuns = 0
    private var failed = false

    private let request = VNGeneratePersonSegmentationRequest()
    private let sequence = VNSequenceRequestHandler()
    private var pool: CVPixelBufferPool?          // composite queue only
    private var poolSize = (0, 0)
    private var bgImage: (path: String, image: CIImage?) = ("", nil)

    static let ciContext: CIContext = {
        let opts: [CIContextOption: Any] = [.workingColorSpace: NSNull(), .outputColorSpace: NSNull(),
                                            .cacheIntermediates: false, .name: "HongMix BG removal"]
        if let dev = MTLCreateSystemDefaultDevice() { return CIContext(mtlDevice: dev, options: opts) }
        return CIContext(options: opts)
    }()

    /// Time per frame of the slower stage (ms) = how often a new result can appear.
    var averageMs: Double { lock.lock(); defer { lock.unlock() }; return max(visionMs, compositeMs) }
    var hasFailed: Bool { lock.lock(); defer { lock.unlock() }; return failed }

    /// Render thread. Returns the latest finished frame for these settings (nil until the first one is ready).
    func frame(for src: CVPixelBuffer, settings: BGRemovalSettings) -> CVPixelBuffer? {
        lock.lock()
        let out = lastSettings == settings ? lastOut : nil
        if src !== lastSrc {
            lastSrc = src
            if visionBusy {
                pendingVision = (src, settings)        // keep only the newest frame
            } else {
                visionBusy = true
                visionQueue.async { [weak self] in self?.runVision(src, settings) }
            }
        }
        lock.unlock()
        return out
    }

    private static func avg(_ old: Double, _ new: Double) -> Double { old == 0 ? new : old * 0.9 + new * 0.1 }

    private func runVision(_ first: CVPixelBuffer, _ firstSettings: BGRemovalSettings) {
        var job: (CVPixelBuffer, BGRemovalSettings)? = (first, firstSettings)
        while let (src, s) = job {
            let t0 = CACurrentMediaTime()
            let mask: CVPixelBuffer? = autoreleasepool {
                request.qualityLevel = s.quality <= 0 ? .fast : (s.quality >= 2 ? .accurate : .balanced)
                request.outputPixelFormat = kCVPixelFormatType_OneComponent8
                do { try sequence.perform([request], on: src) } catch { return nil }
                return request.results?.first?.pixelBuffer
            }
            let ms = (CACurrentMediaTime() - t0) * 1000
            lock.lock()
            visionRuns += 1
            if visionRuns > 2 { visionMs = Self.avg(visionMs, ms) }
            if let mask {
                if compositeBusy {
                    pendingComposite = (src, mask, s)
                } else {
                    compositeBusy = true
                    compositeQueue.async { [weak self] in self?.runComposite(src, mask, s) }
                }
            } else {
                failed = true
            }
            job = pendingVision
            pendingVision = nil
            if job == nil { visionBusy = false }
            lock.unlock()
        }
    }

    private func runComposite(_ src0: CVPixelBuffer, _ mask0: CVPixelBuffer, _ s0: BGRemovalSettings) {
        var job: (CVPixelBuffer, CVPixelBuffer, BGRemovalSettings)? = (src0, mask0, s0)
        while let (src, mask, s) = job {
            let t0 = CACurrentMediaTime()
            let out = autoreleasepool { composite(src, mask, s) }
            let ms = (CACurrentMediaTime() - t0) * 1000
            lock.lock()
            compositeRuns += 1
            if compositeRuns > 2 { compositeMs = Self.avg(compositeMs, ms) }
            if let out { lastOut = out; lastSettings = s; failed = false } else { failed = true }
            job = pendingComposite
            pendingComposite = nil
            if job == nil { compositeBusy = false }
            lock.unlock()
        }
    }

    private func composite(_ src: CVPixelBuffer, _ maskPB: CVPixelBuffer, _ s: BGRemovalSettings) -> CVPixelBuffer? {
        let fg = CIImage(cvPixelBuffer: src)
        let ext = fg.extent
        guard ext.width > 0, ext.height > 0 else { return nil }
        let k = ext.height / 1080
        var mask = CIImage(cvPixelBuffer: maskPB)
        mask = mask.transformed(by: CGAffineTransform(scaleX: ext.width / mask.extent.width, y: ext.height / mask.extent.height))
        if s.softness > 0.001 {
            mask = mask.clampedToExtent().applyingGaussianBlur(sigma: Double(s.softness) * 6 * k).cropped(to: ext)
        }
        let bg: CIImage
        switch s.background {
        case "blur":
            bg = fg.clampedToExtent().applyingGaussianBlur(sigma: 28 * k).cropped(to: ext)
        case "image":
            bg = backgroundImage(s.imagePath, fill: ext) ?? CIImage(color: .clear).cropped(to: ext)
        default:
            bg = CIImage(color: .clear).cropped(to: ext)
        }
        let out = fg.applyingFilter("CIBlendWithMask", parameters: [kCIInputBackgroundImageKey: bg, kCIInputMaskImageKey: mask])

        let w = CVPixelBufferGetWidth(src), h = CVPixelBufferGetHeight(src)
        if pool == nil || poolSize != (w, h) {
            pool = PixelBufferFactory.makePool(width: w, height: h, minimumCount: 4)
            poolSize = (w, h)
        }
        guard let pool, let dst = PixelBufferFactory.makeBuffer(pool: pool) else { return nil }
        Self.ciContext.render(out, to: dst, bounds: ext, colorSpace: nil)
        return dst
    }

    /// Background picture scaled to fill the frame (aspect fill, centred); cached per path.
    private func backgroundImage(_ path: String, fill ext: CGRect) -> CIImage? {
        if bgImage.path != path {
            bgImage = (path, path.isEmpty ? nil : CIImage(contentsOf: URL(fileURLWithPath: path)))
        }
        guard let img = bgImage.image, img.extent.width > 0, img.extent.height > 0 else { return nil }
        let sc = max(ext.width / img.extent.width, ext.height / img.extent.height)
        let scaled = img.transformed(by: CGAffineTransform(scaleX: sc, y: sc))
        let dx = ext.midX - scaled.extent.midX, dy = ext.midY - scaled.extent.midY
        return scaled.transformed(by: CGAffineTransform(translationX: dx, y: dy)).cropped(to: ext)
    }
}
