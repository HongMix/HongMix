import Foundation

/// Biquad filter (RBJ audio EQ cookbook), transposed direct form II.
struct Biquad {
    var b0: Float = 1, b1: Float = 0, b2: Float = 0, a1: Float = 0, a2: Float = 0
    var z1: Float = 0, z2: Float = 0

    @inline(__always) mutating func process(_ x: Float) -> Float {
        let y = b0 * x + z1
        z1 = b1 * x - a1 * y + z2
        z2 = b2 * x - a2 * y
        return y
    }

    enum Kind { case lowShelf, peak, highShelf }

    static func make(_ kind: Kind, freq: Float, gainDB: Float, q: Float = 0.707, rate: Float = 48000) -> Biquad {
        let A = powf(10, gainDB / 40)
        let w0 = 2 * Float.pi * freq / rate
        let cw = cosf(w0), sw = sinf(w0)
        var b0: Float, b1: Float, b2: Float, a0: Float, a1: Float, a2: Float
        switch kind {
        case .peak:
            let alpha = sw / (2 * q)
            b0 = 1 + alpha * A
            b1 = -2 * cw
            b2 = 1 - alpha * A
            a0 = 1 + alpha / A
            a1 = -2 * cw
            a2 = 1 - alpha / A
        case .lowShelf:
            let alpha = sw / 2 * sqrtf(2)
            let s = 2 * sqrtf(A) * alpha
            b0 = A * ((A + 1) - (A - 1) * cw + s)
            b1 = 2 * A * ((A - 1) - (A + 1) * cw)
            b2 = A * ((A + 1) - (A - 1) * cw - s)
            a0 = (A + 1) + (A - 1) * cw + s
            a1 = -2 * ((A - 1) + (A + 1) * cw)
            a2 = (A + 1) + (A - 1) * cw - s
        case .highShelf:
            let alpha = sw / 2 * sqrtf(2)
            let s = 2 * sqrtf(A) * alpha
            b0 = A * ((A + 1) + (A - 1) * cw + s)
            b1 = -2 * A * ((A - 1) + (A + 1) * cw)
            b2 = A * ((A + 1) + (A - 1) * cw - s)
            a0 = (A + 1) - (A - 1) * cw + s
            a1 = 2 * ((A - 1) - (A + 1) * cw)
            a2 = (A + 1) - (A - 1) * cw - s
        }
        return Biquad(b0: b0 / a0, b1: b1 / a0, b2: b2 / a0, a1: a1 / a0, a2: a2 / a0)
    }
}

/// Render-thread processing state for one input (channel mode, gate, EQ, compressor).
final class InputDSPState {
    private var eqL = [Biquad](repeating: Biquad(), count: 3)
    private var eqR = [Biquad](repeating: Biquad(), count: 3)
    private var eqSettings: (Float, Float, Float) = (0, 0, 0)
    private var compEnv: Float = 0
    private var gateEnv: Float = 0
    private var gateGain: Float = 1

    private static let rate: Float = 48000
    private let compAttack = expf(-1 / (0.005 * InputDSPState.rate))
    private let compRelease = expf(-1 / (0.120 * InputDSPState.rate))
    private let gateRelease = expf(-1 / (0.050 * InputDSPState.rate))
    private let gateStep: Float = 1 / (0.010 * InputDSPState.rate)   // 10 ms gain ramp

    /// Processes interleaved stereo in place.
    func process(_ fx: AudioFX, _ buf: UnsafeMutablePointer<Float>, frames n: Int) {
        // channel selection
        switch fx.channelMode {
        case 1: for i in 0..<n { buf[i * 2 + 1] = buf[i * 2] }
        case 2: for i in 0..<n { buf[i * 2] = buf[i * 2 + 1] }
        case 3: for i in 0..<n { let l = buf[i * 2]; buf[i * 2] = buf[i * 2 + 1]; buf[i * 2 + 1] = l }
        default: break
        }
        if fx.gateOn {
            let thr = powf(10, fx.gateThreshold / 20)
            for i in 0..<n {
                let level = max(abs(buf[i * 2]), abs(buf[i * 2 + 1]))
                gateEnv = max(level, gateEnv * gateRelease)
                let target: Float = gateEnv >= thr ? 1 : 0
                if gateGain < target { gateGain = min(target, gateGain + gateStep) }
                if gateGain > target { gateGain = max(target, gateGain - gateStep * 0.2) }
                buf[i * 2] *= gateGain
                buf[i * 2 + 1] *= gateGain
            }
        }
        if fx.eqOn && (fx.eqLow != 0 || fx.eqMid != 0 || fx.eqHigh != 0) {
            if eqSettings != (fx.eqLow, fx.eqMid, fx.eqHigh) {
                eqSettings = (fx.eqLow, fx.eqMid, fx.eqHigh)
                let bands = [Biquad.make(.lowShelf, freq: 100, gainDB: fx.eqLow),
                             Biquad.make(.peak, freq: 1000, gainDB: fx.eqMid, q: 0.9),
                             Biquad.make(.highShelf, freq: 8000, gainDB: fx.eqHigh)]
                for b in 0..<3 {
                    // keep filter memory to avoid clicks when only gains change
                    var l = bands[b], r = bands[b]
                    l.z1 = eqL[b].z1; l.z2 = eqL[b].z2
                    r.z1 = eqR[b].z1; r.z2 = eqR[b].z2
                    eqL[b] = l
                    eqR[b] = r
                }
            }
            for i in 0..<n {
                var l = buf[i * 2], r = buf[i * 2 + 1]
                for b in 0..<3 {
                    l = eqL[b].process(l)
                    r = eqR[b].process(r)
                }
                buf[i * 2] = l
                buf[i * 2 + 1] = r
            }
        }
        if fx.compOn && fx.compRatio > 1 {
            let thr = fx.compThreshold
            let ratio = fx.compRatio
            for i in 0..<n {
                let level = max(abs(buf[i * 2]), abs(buf[i * 2 + 1]))
                let coeff = level > compEnv ? compAttack : compRelease
                compEnv = coeff * compEnv + (1 - coeff) * level
                let db = 20 * log10f(max(compEnv, 1e-6))
                if db > thr {
                    let g = powf(10, ((thr + (db - thr) / ratio) - db) / 20)
                    buf[i * 2] *= g
                    buf[i * 2 + 1] *= g
                }
            }
        }
    }
}
