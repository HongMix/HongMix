import Foundation

/// ITU-R BS.1770-4 / EBU R128 loudness meter for the master bus (stereo, 48 kHz).
/// Momentary (400 ms), short-term (3 s), gated integrated loudness, loudness range (LRA) and sample peak.
/// Runs on the render/audio thread inside `AudioMixer.mix`; costs ~2 biquads per sample.
final class LoudnessMeter {
    struct Reading {
        var momentary: Double = -.infinity     // LUFS
        var shortTerm: Double = -.infinity     // LUFS
        var integrated: Double = -.infinity    // LUFS (gated)
        var range: Double = 0                  // LU (LRA)
        var peak: Double = -.infinity          // dBFS, max sample peak since reset
        var maxMomentary: Double = -.infinity
        var seconds: Double = 0                // measured time since reset
    }

    // K-weighting at 48 kHz (BS.1770): high-shelf pre-filter, then RLB high-pass
    private struct Biquad {
        let b0, b1, b2, a1, a2: Double
        var z1 = 0.0, z2 = 0.0
        mutating func run(_ x: Double) -> Double {
            let y = b0 * x + z1
            z1 = b1 * x - a1 * y + z2
            z2 = b2 * x - a2 * y
            return y
        }
    }
    private static let shelf = Biquad(b0: 1.53512485958697, b1: -2.69169618940638, b2: 1.19839281085285,
                                      a1: -1.69065929318241, a2: 0.73248077421585)
    private static let hp = Biquad(b0: 1, b1: -2, b2: 1, a1: -1.99004745483398, a2: 0.99007225036621)
    private var filters = [shelf, hp, shelf, hp]     // L: 0,1  R: 2,3

    private let blockLen = AudioMixer.rate / 10      // 100 ms sub-blocks
    private var acc = 0.0, accN = 0
    private var blocks = [Double](repeating: 0, count: 30)   // last 3 s of 100 ms mean-square energies
    private var blockIdx = 0, blockCount = 0
    private var peakLin: Float = 0

    // Histograms (0.1 LU bins from -70 to +10 LUFS): energy sums + counts → gating without storing blocks
    private static let binLo = -70.0, binStep = 0.1, binCount = 800
    private var mHistE = [Double](repeating: 0, count: binCount)
    private var mHistN = [Int](repeating: 0, count: binCount)
    private var sHistN = [Int](repeating: 0, count: binCount)    // short-term values for LRA

    private let lock = NSLock()
    private var reading = Reading()
    private var resetRequested = false

    var current: Reading {
        lock.lock(); defer { lock.unlock() }
        return reading
    }

    func reset() {
        lock.lock(); resetRequested = true; reading = Reading(); lock.unlock()
    }

    private static func lufs(_ energy: Double) -> Double {
        energy > 1e-12 ? -0.691 + 10 * log10(energy) : -.infinity
    }
    private static func bin(_ l: Double) -> Int? {
        guard l.isFinite, l >= binLo else { return nil }
        return min(binCount - 1, Int((l - binLo) / binStep))
    }

    /// `p`: interleaved stereo floats, `n` frames.
    func process(_ p: UnsafePointer<Float>, _ n: Int) {
        lock.lock()
        let doReset = resetRequested
        resetRequested = false
        lock.unlock()
        if doReset {
            filters = [Self.shelf, Self.hp, Self.shelf, Self.hp]
            acc = 0; accN = 0; blockIdx = 0; blockCount = 0; peakLin = 0
            for i in 0..<Self.binCount { mHistE[i] = 0; mHistN[i] = 0; sHistN[i] = 0 }
        }
        // filter state in locals: keeps the per-sample loop free of array/exclusivity checks
        var f0 = filters[0], f1 = filters[1], f2 = filters[2], f3 = filters[3]
        var pk = peakLin
        var i = 0
        while i < n {
            let l = p[i * 2], r = p[i * 2 + 1]
            pk = max(pk, abs(l), abs(r))
            let yl = f1.run(f0.run(Double(l)))
            let yr = f3.run(f2.run(Double(r)))
            acc += yl * yl + yr * yr          // channel weights G = 1.0 for L/R
            accN += 1
            if accN == blockLen { peakLin = pk; finishBlock() }
            i += 1
        }
        peakLin = pk
        filters[0] = f0; filters[1] = f1; filters[2] = f2; filters[3] = f3
    }

    private func finishBlock() {
        blocks[blockIdx] = acc / Double(blockLen)
        blockIdx = (blockIdx + 1) % blocks.count
        blockCount += 1
        acc = 0; accN = 0

        func mean(last k: Int) -> Double? {
            guard blockCount >= k else { return nil }
            var s = 0.0
            for j in 1...k { s += blocks[(blockIdx - j + blocks.count) % blocks.count] }
            return s / Double(k)
        }
        let mE = mean(last: 4)
        let sE = mean(last: 30)
        let m = mE.map(Self.lufs) ?? -.infinity
        let s = sE.map(Self.lufs) ?? -.infinity
        // gating blocks: 400 ms windows every 100 ms (75 % overlap)
        if let mE, let b = Self.bin(m) { mHistE[b] += mE; mHistN[b] += 1 }
        // LRA uses 3 s short-term values every 100 ms (EBU Tech 3342 suggests ≥ 10 Hz)
        if let b = Self.bin(s) { sHistN[b] += 1 }

        // integrated: absolute gate −70, relative gate −10 LU
        var e = 0.0, c = 0
        for k in 0..<Self.binCount where mHistN[k] > 0 { e += mHistE[k]; c += mHistN[k] }
        var integrated = -Double.infinity
        if c > 0 {
            let rel = Self.lufs(e / Double(c)) - 10
            let start = max(0, Int(((rel - Self.binLo) / Self.binStep).rounded(.up)))
            var e2 = 0.0, c2 = 0
            if start < Self.binCount {
                for k in start..<Self.binCount where mHistN[k] > 0 { e2 += mHistE[k]; c2 += mHistN[k] }
            }
            if c2 > 0 { integrated = Self.lufs(e2 / Double(c2)) }
        }
        // LRA: short-term values above −70 and above (their power mean − 20 LU); 10th…95th percentile
        var range = 0.0
        var sPow = 0.0, sN = 0
        for k in 0..<Self.binCount where sHistN[k] > 0 {
            let lv = Self.binLo + (Double(k) + 0.5) * Self.binStep
            sPow += Double(sHistN[k]) * pow(10, lv / 10); sN += sHistN[k]
        }
        if sN > 0 {
            let gate = 10 * log10(sPow / Double(sN)) - 20
            let start = max(0, Int(((gate - Self.binLo) / Self.binStep).rounded(.up)))
            var total = 0
            if start < Self.binCount { for k in start..<Self.binCount { total += sHistN[k] } }
            if total > 10 {
                var run = 0, lo = Double.nan, hi = Double.nan
                for k in start..<Self.binCount {
                    run += sHistN[k]
                    let lv = Self.binLo + (Double(k) + 0.5) * Self.binStep
                    if lo.isNaN && Double(run) >= 0.10 * Double(total) { lo = lv }
                    if hi.isNaN && Double(run) >= 0.95 * Double(total) { hi = lv; break }
                }
                if !lo.isNaN && !hi.isNaN { range = hi - lo }
            }
        }
        let peakDB = peakLin > 0 ? 20 * log10(Double(peakLin)) : -Double.infinity
        lock.lock()
        if !resetRequested {
            reading.momentary = m
            reading.shortTerm = s
            reading.integrated = integrated
            reading.range = range
            reading.peak = peakDB
            if m > reading.maxMomentary { reading.maxMomentary = m }
            reading.seconds = Double(blockCount) / 10
        }
        lock.unlock()
    }
}

/// Loudness targets offered in the UI.
enum LoudnessTarget: Double, CaseIterable, Identifiable {
    case ebu = -23, atsc = -24, streaming = -14, podcast = -16
    var id: Double { rawValue }
    var label: String {
        switch self {
        case .ebu: return "EBU R128 (−23)"
        case .atsc: return "ATSC A/85 (−24)"
        case .streaming: return L("스트리밍 (−14)")
        case .podcast: return L("팟캐스트/모바일 (−16)")
        }
    }
    static var saved: LoudnessTarget {
        get { LoudnessTarget(rawValue: UserDefaults.standard.double(forKey: "loudnessTarget")) ?? .streaming }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: "loudnessTarget") }
    }
}
