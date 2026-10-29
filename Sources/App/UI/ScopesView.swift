import SwiftUI
import AppKit
import CoreVideo

/// Video scopes computed from a downscaled copy of a frame (~10×/s): waveform (luma), RGB parade,
/// vectorscope and histogram. All CPU, on a background queue — ~60k samples per update.
final class ScopeAnalyzer: ObservableObject {
    enum Source: Hashable { case output, preview, input(UUID) }

    @Published private(set) var waveform: CGImage?
    @Published private(set) var parade: CGImage?
    @Published private(set) var vector: CGImage?
    @Published private(set) var histogram: CGImage?
    @Published private(set) var clipHigh: Double = 0     // % of samples ≥ 100 IRE
    @Published private(set) var clipLow: Double = 0      // % of samples ≤ 0 IRE
    @Published var source: Source = .output
    @Published var gain: Double = 1.5

    private var timer: Timer?
    private let queue = DispatchQueue(label: "scopes", qos: .utility)
    private var busy = false
    weak var engine: SwitcherEngine?

    func start(_ e: SwitcherEngine) {
        engine = e
        guard timer == nil else { return }
        let t = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in self?.update() }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    func stop() { timer?.invalidate(); timer = nil }

    private func frame() -> CVPixelBuffer? {
        guard let e = engine else { return nil }
        switch source {
        case .output: return e.programSlot.latest()
        case .preview: return e.input(withID: e.previewID)?.currentFrame()
        case .input(let id): return e.input(withID: id)?.currentFrame()
        }
    }

    private func update() {
        guard !busy, let pb = frame() else { return }
        busy = true
        let g = gain
        queue.async { [weak self] in
            let r = ScopeAnalyzer.analyze(pb, gain: g)
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.busy = false
                if let r = r {
                    self.waveform = r.wave; self.parade = r.parade; self.vector = r.vector; self.histogram = r.hist
                    self.clipHigh = r.hi; self.clipLow = r.lo
                }
            }
        }
    }

    struct Result { let wave, parade, vector, hist: CGImage?; let hi, lo: Double }

    static let cols = 256, rows = 144

    static func analyze(_ pb: CVPixelBuffer, gain: Double) -> Result? {
        let fmt = CVPixelBufferGetPixelFormatType(pb)
        guard CVPixelBufferLockBaseAddress(pb, .readOnly) == kCVReturnSuccess else { return nil }
        defer { CVPixelBufferUnlockBaseAddress(pb, .readOnly) }
        let w = CVPixelBufferGetWidth(pb), h = CVPixelBufferGetHeight(pb)
        let C = cols, R = rows
        var wave = [UInt32](repeating: 0, count: C * 256)          // column × level
        var par = [UInt32](repeating: 0, count: C * 3 * 256)       // 3 × column × level
        var vec = [UInt32](repeating: 0, count: 256 * 256)
        var hist = [UInt32](repeating: 0, count: 3 * 256)
        var hi = 0, lo = 0, total = 0

        @inline(__always) func add(_ x: Int, _ r: Float, _ gg: Float, _ b: Float) {
            let y = 0.2126 * r + 0.7152 * gg + 0.0722 * b
            let yi = max(0, min(255, Int(y * 255)))
            wave[x * 256 + yi] += 1
            let ri = max(0, min(255, Int(r * 255))), gi = max(0, min(255, Int(gg * 255))), bi = max(0, min(255, Int(b * 255)))
            par[(0 * C + x) * 256 + ri] += 1
            par[(1 * C + x) * 256 + gi] += 1
            par[(2 * C + x) * 256 + bi] += 1
            hist[ri] += 1; hist[256 + gi] += 1; hist[512 + bi] += 1
            let cb = (b - y) / 1.8556, cr = (r - y) / 1.5748     // −0.5…0.5
            let vx = max(0, min(255, Int((cb + 0.5) * 255))), vy = max(0, min(255, Int((0.5 - cr) * 255)))
            vec[vy * 256 + vx] += 1
            if yi >= 254 { hi += 1 }
            if yi <= 1 { lo += 1 }
            total += 1
        }

        switch fmt {
        case kCVPixelFormatType_32BGRA:
            guard let base = CVPixelBufferGetBaseAddress(pb) else { return nil }
            let stride = CVPixelBufferGetBytesPerRow(pb)
            let p = base.assumingMemoryBound(to: UInt8.self)
            for ry in 0..<R {
                let sy = min(h - 1, ry * h / R)
                let row = p + sy * stride
                for x in 0..<C {
                    let sx = min(w - 1, x * w / C)
                    let px = row + sx * 4
                    add(x, Float(px[2]) / 255, Float(px[1]) / 255, Float(px[0]) / 255)
                }
            }
        case kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, kCVPixelFormatType_420YpCbCr8BiPlanarFullRange:
            guard let yb = CVPixelBufferGetBaseAddressOfPlane(pb, 0), let cb = CVPixelBufferGetBaseAddressOfPlane(pb, 1) else { return nil }
            let ys = CVPixelBufferGetBytesPerRowOfPlane(pb, 0), cs = CVPixelBufferGetBytesPerRowOfPlane(pb, 1)
            let full = fmt == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
            let yp = yb.assumingMemoryBound(to: UInt8.self), cp = cb.assumingMemoryBound(to: UInt8.self)
            for ry in 0..<R {
                let sy = min(h - 1, ry * h / R)
                for x in 0..<C {
                    let sx = min(w - 1, x * w / C)
                    var Y = Float(yp[sy * ys + sx]) / 255
                    let ci = (sy / 2) * cs + (sx / 2) * 2
                    var U = Float(cp[ci]) / 255, V = Float(cp[ci + 1]) / 255
                    if full { U -= 0.5; V -= 0.5 } else {
                        Y = (Y - 16 / 255) * (255 / 219); U = (U - 128 / 255) * (255 / 224); V = (V - 128 / 255) * (255 / 224)
                    }
                    let r = Y + 1.5748 * V, g = Y - 0.1873 * U - 0.4681 * V, b = Y + 1.8556 * U
                    add(x, max(0, min(1, r)), max(0, min(1, g)), max(0, min(1, b)))
                }
            }
        default:
            return nil
        }
        let k = Float(gain)
        let wave8 = trace(wave, width: C, height: 256, scale: k * 40 / Float(R), tint: (0.45, 1, 0.55), transpose: true)
        let par8 = paradeImage(par, cols: C, scale: k * 40 / Float(R))
        let vec8 = trace(vec, width: 256, height: 256, scale: k * 400 / Float(total), tint: (0.5, 1, 0.6), transpose: false, graticule: true)
        let hist8 = histImage(hist)
        let t = Double(max(1, total))
        return Result(wave: wave8, parade: par8, vector: vec8, hist: hist8, hi: Double(hi) / t * 100, lo: Double(lo) / t * 100)
    }

    /// counts → RGBA image. `transpose`: counts are [x][level] and level 255 is drawn at the top.
    private static func trace(_ counts: [UInt32], width: Int, height: Int, scale: Float, tint: (Float, Float, Float),
                              transpose: Bool, graticule: Bool = false) -> CGImage? {
        var px = [UInt8](repeating: 0, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let c = transpose ? counts[x * height + (height - 1 - y)] : counts[y * width + x]
                let o = (y * width + x) * 4
                if c > 0 {
                    let v = min(1, sqrtf(Float(c) * scale))
                    px[o] = UInt8(255 * min(1, v * tint.0)); px[o + 1] = UInt8(255 * min(1, v * tint.1))
                    px[o + 2] = UInt8(255 * min(1, v * tint.2))
                }
                px[o + 3] = 255
            }
        }
        if transpose {      // IRE lines at 0 / 25 / 50 / 75 / 100 %
            for q in 0...4 {
                let y = min(height - 1, Int(Float(height - 1) * (1 - Float(q) / 4)))
                for x in stride(from: 0, to: width, by: 2) { let o = (y * width + x) * 4; px[o] = max(px[o], 70); px[o + 1] = max(px[o + 1], 70); px[o + 2] = max(px[o + 2], 40) }
            }
        }
        if graticule { drawVectorGraticule(&px, size: width) }
        return image(px, width, height)
    }

    private static func drawVectorGraticule(_ px: inout [UInt8], size: Int) {
        func dot(_ x: Int, _ y: Int, _ c: (UInt8, UInt8, UInt8)) {
            guard x >= 0, y >= 0, x < size, y < size else { return }
            let o = (y * size + x) * 4
            px[o] = max(px[o], c.0); px[o + 1] = max(px[o + 1], c.1); px[o + 2] = max(px[o + 2], c.2)
        }
        let c = Double(size - 1) / 2
        for a in stride(from: 0.0, to: 2 * Double.pi, by: 0.01) {      // 100 % saturation circle
            dot(Int(c + cos(a) * c), Int(c + sin(a) * c), (60, 60, 60))
        }
        for i in 0..<size { dot(i, Int(c), (45, 45, 45)); dot(Int(c), i, (45, 45, 45)) }
        // 75 % colour bar targets (R, Mg, B, Cy, G, Yl) + skin-tone line
        let targets: [(Double, Double, Double)] = [(0.75, 0, 0), (0.75, 0, 0.75), (0, 0, 0.75), (0, 0.75, 0.75), (0, 0.75, 0), (0.75, 0.75, 0)]
        for (r, g, b) in targets {
            let y = 0.2126 * r + 0.7152 * g + 0.0722 * b
            let cb = (b - y) / 1.8556, cr = (r - y) / 1.5748
            let x = Int((cb + 0.5) * Double(size - 1)), yy = Int((0.5 - cr) * Double(size - 1))
            for dx in -4...4 { dot(x + dx, yy - 4, (200, 80, 80)); dot(x + dx, yy + 4, (200, 80, 80)) }
            for dy in -4...4 { dot(x - 4, yy + dy, (200, 80, 80)); dot(x + 4, yy + dy, (200, 80, 80)) }
        }
        let skin = 123.0 * Double.pi / 180      // I-line (skin tones)
        for t in stride(from: 0.0, to: c, by: 1) { dot(Int(c - cos(skin) * t), Int(c - sin(skin) * t), (120, 90, 50)) }
    }

    private static func paradeImage(_ counts: [UInt32], cols: Int, scale: Float) -> CGImage? {
        let gap = 4, W = cols * 3 + gap * 2, H = 256
        var px = [UInt8](repeating: 0, count: W * H * 4)
        for i in 0..<(W * H) { px[i * 4 + 3] = 255 }
        let tints: [(Float, Float, Float)] = [(1, 0.25, 0.25), (0.3, 1, 0.3), (0.35, 0.5, 1)]
        for ch in 0..<3 {
            for x in 0..<cols {
                for lvl in 0..<256 {
                    let c = counts[(ch * cols + x) * 256 + lvl]
                    guard c > 0 else { continue }
                    let v = min(1, sqrtf(Float(c) * scale))
                    let o = ((H - 1 - lvl) * W + ch * (cols + gap) + x) * 4
                    px[o] = UInt8(255 * min(1, v * tints[ch].0)); px[o + 1] = UInt8(255 * min(1, v * tints[ch].1))
                    px[o + 2] = UInt8(255 * min(1, v * tints[ch].2))
                }
            }
        }
        return image(px, W, H)
    }

    private static func histImage(_ h: [UInt32]) -> CGImage? {
        let W = 256, H = 128
        var px = [UInt8](repeating: 0, count: W * H * 4)
        for i in 0..<(W * H) { px[i * 4 + 3] = 255 }
        let m = Float(max(1, (h.max() ?? 1)))
        for ch in 0..<3 {
            for x in 0..<256 {
                let v = Int(sqrtf(Float(h[ch * 256 + x]) / m) * Float(H - 1))
                for y in 0..<v {
                    let o = ((H - 1 - y) * W + x) * 4
                    px[o + ch] = 210          // RGBA: R/G/B add up where channels overlap
                }
            }
        }
        return image(px, W, H)
    }

    private static func image(_ px: [UInt8], _ w: Int, _ h: Int) -> CGImage? {
        let data = Data(px) as CFData
        guard let prov = CGDataProvider(data: data) else { return nil }
        return CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: w * 4,
                       space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                       provider: prov, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    }
}

/// Scopes window (Window id "scopes").
struct ScopesView: View {
    @EnvironmentObject var engine: SwitcherEngine
    @StateObject private var scopes = ScopeAnalyzer()

    var body: some View {
        VStack(spacing: 8) {
            HStack {
                Picker(L("소스"), selection: $scopes.source) {
                    Text("Output").tag(ScopeAnalyzer.Source.output)
                    Text("Preview").tag(ScopeAnalyzer.Source.preview)
                    ForEach(engine.inputs) { i in
                        Text("\(engine.number(of: i)). \(i.name)").tag(ScopeAnalyzer.Source.input(i.id))
                    }
                }
                .frame(width: 260)
                Text(L("밝기")).foregroundColor(.secondary)
                Slider(value: $scopes.gain, in: 0.3...6).frame(width: 120)
                Spacer()
                Text(String(format: L("클리핑 %.1f%% · 블랙 %.1f%%"), scopes.clipHigh, scopes.clipLow))
                    .font(.system(size: 11).monospacedDigit())
                    .foregroundColor(scopes.clipHigh > 1 ? .orange : .secondary)
            }
            GeometryReader { geo in
                let w = (geo.size.width - 8) / 2, h = (geo.size.height - 8) / 2
                VStack(spacing: 8) {
                    HStack(spacing: 8) {
                        panel(L("웨이브폼 (휘도)"), scopes.waveform).frame(width: w, height: h)
                        panel(L("RGB 퍼레이드"), scopes.parade).frame(width: w, height: h)
                    }
                    HStack(spacing: 8) {
                        panel(L("벡터스코프"), scopes.vector, square: true).frame(width: w, height: h)
                        panel(L("히스토그램"), scopes.histogram).frame(width: w, height: h)
                    }
                }
            }
        }
        .padding(10)
        .background(Color(white: 0.08))
        .onAppear { scopes.start(engine) }
        .onDisappear { scopes.stop() }
    }

    private func panel(_ title: String, _ img: CGImage?, square: Bool = false) -> some View {
        ZStack(alignment: .topLeading) {
            Color.black
            if let img = img {
                Image(decorative: img, scale: 1)
                    .resizable()
                    .interpolation(.medium)
                    .aspectRatio(square ? 1 : nil, contentMode: square ? .fit : .fill)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            Text(title).font(.system(size: 10, weight: .semibold)).foregroundColor(.white.opacity(0.7)).padding(5)
        }
        .clipShape(RoundedRectangle(cornerRadius: 4))
    }
}

/// Bottom-bar button that opens the scopes window.
struct ScopesButton: View {
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button { openWindow(id: "scopes") } label: {
            Image(systemName: "waveform")
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(.white)
                .frame(width: 34, height: 30)
                .background(Theme.button)
                .clipShape(RoundedRectangle(cornerRadius: 3))
        }
        .buttonStyle(.plain)
        .help(L("스코프 — 웨이브폼 · RGB 퍼레이드 · 벡터스코프 · 히스토그램"))
    }
}
