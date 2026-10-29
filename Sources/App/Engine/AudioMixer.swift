import Foundation
import AVFoundation
import QuartzCore

/// Settings of one bus (index 0 = Master, 1…7 = A…G).
struct BusSettings: Codable, Equatable {
    var volume: Float = 1          // fader 0...1 (gain = volume²)
    var muted = false
    var sendToMaster = false       // aux buses only
    var solo = false               // aux buses only (headphones)
    var enabled = false            // aux buses: shown in the mixer (vMix: buses appear once enabled/used)

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        volume = c.value(.volume, Float(1))
        muted = c.value(.muted, false)
        sendToMaster = c.value(.sendToMaster, false)
        solo = c.value(.solo, false)
        enabled = c.value(.enabled, false)
    }
}

/// Auto ducking (global): while any 'trigger' input is above the threshold, 'ducked' inputs drop by `amountDB`.
struct DuckSettings: Codable, Equatable {
    var enabled = true
    var amountDB: Float = -15        // how far ducked inputs go down
    var thresholdDB: Float = -38     // trigger level (post-fader peak, dBFS)
    var attackMs: Float = 60
    var holdMs: Float = 400
    var releaseMs: Float = 900

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = DuckSettings()
        enabled = c.value(.enabled, d.enabled)
        amountDB = c.value(.amountDB, d.amountDB)
        thresholdDB = c.value(.thresholdDB, d.thresholdDB)
        attackMs = c.value(.attackMs, d.attackMs)
        holdMs = c.value(.holdMs, d.holdMs)
        releaseMs = c.value(.releaseMs, d.releaseMs)
    }
}

/// Per-tick audio mixer: pulls each input's ring buffer, applies trim / balance / fader / audio-follow-video,
/// routes to Master and buses A–G, keeps peak meters, ISO feeds for MultiCorder and the headphone mix.
final class AudioMixer {
    static let rate = 48000
    static let busCount = 8
    private let maxFrames = 48000
    private var busBufs: [UnsafeMutablePointer<Float>] = []
    private let tmpBuf: UnsafeMutablePointer<Float>
    private let soloBuf: UnsafeMutablePointer<Float>
    private var isoBufs: [UUID: UnsafeMutablePointer<Float>] = [:]   // render thread
    private let cushion = 2400       // 50 ms priming
    private let maxLatency = 9600    // 200 ms before dropping

    private let lock = NSLock()
    private var meters: [UUID: (Float, Float)] = [:]
    private var busMeters = [(Float, Float)](repeating: (0, 0), count: AudioMixer.busCount)
    private var buses = [BusSettings](repeating: BusSettings(), count: AudioMixer.busCount)
    private var lastBusGain = [Float](repeating: 1, count: AudioMixer.busCount)
    private var headphonesGain: Float = 1
    private var duck = DuckSettings()
    // ducking state (render thread)
    private var duckGain: Float = 1
    private var triggerPeakPrev: Float = 0
    private var duckHoldLeft: Float = 0
    /// Current ducking gain reduction in dB (0 = not ducking), for the UI.
    private(set) var duckReductionDB: Float = 0

    let monitorRing = AudioRing(seconds: 1)
    // diagnostics (render thread): seconds spent in the last mix call
    var diagDSP: Double = 0, diagLoud: Double = 0, diagFrames = 0
    var diagIn: Double = 0, diagBus: Double = 0, diagLockWait: Double = 0
    /// EBU R128 loudness of the master bus (post-fader, what goes to air).
    let loudness = LoudnessMeter()
    private var monitorEngine: AVAudioEngine?
    private(set) var monitoring = false
    private let monitorScratch = UnsafeMutablePointer<Float>.allocate(capacity: 8192 * 2)

    init() {
        for _ in 0..<AudioMixer.busCount {
            let p = UnsafeMutablePointer<Float>.allocate(capacity: maxFrames * 2)
            p.initialize(repeating: 0, count: maxFrames * 2)
            busBufs.append(p)
        }
        tmpBuf = UnsafeMutablePointer<Float>.allocate(capacity: maxFrames * 2)
        soloBuf = UnsafeMutablePointer<Float>.allocate(capacity: maxFrames * 2)
    }

    deinit {
        busBufs.forEach { $0.deallocate() }
        isoBufs.values.forEach { $0.deallocate() }
        tmpBuf.deallocate()
        soloBuf.deallocate()
        monitorScratch.deallocate()
    }

    // MARK: Settings (any thread)

    func setBus(_ index: Int, _ s: BusSettings) {
        guard (0..<AudioMixer.busCount).contains(index) else { return }
        lock.lock()
        buses[index] = s
        lock.unlock()
    }

    func setMaster(volume: Float, muted: Bool) {
        lock.lock()
        buses[0].volume = volume
        buses[0].muted = muted
        lock.unlock()
    }

    func setDucking(_ d: DuckSettings) {
        lock.lock()
        duck = d
        lock.unlock()
    }

    func setHeadphones(volume: Float) {
        lock.lock()
        headphonesGain = volume * volume
        lock.unlock()
    }

    func meter(for id: UUID) -> (Float, Float) {
        lock.lock()
        defer { lock.unlock() }
        return meters[id] ?? (0, 0)
    }

    func busMeter(_ index: Int) -> (Float, Float) {
        lock.lock()
        defer { lock.unlock() }
        return (0..<AudioMixer.busCount).contains(index) ? busMeters[index] : (0, 0)
    }

    var master: (Float, Float) { busMeter(0) }

    // MARK: Mix (render thread)

    /// Mixes `frames` samples into all buses. `weights` = program contribution per input for audio-follow-video.
    /// Returns the number of frames produced; read buses with `bus(_:)` and ISO feeds with `iso(_:)`.
    @discardableResult
    func mix(inputs: [InputSource], weights: [UUID: Float], frames requested: Int, isoIDs: Set<UUID>) -> Int {
        let n = min(requested, maxFrames)
        diagDSP = 0; diagLoud = 0
        let tm0 = CACurrentMediaTime()
        for b in busBufs { b.initialize(repeating: 0, count: n * 2) }
        soloBuf.initialize(repeating: 0, count: n * 2)
        lock.lock()
        let busSet = buses
        let hpGain = headphonesGain
        let dk = duck
        lock.unlock()
        // auto ducking: decide from the trigger inputs' level of the previous tick (≈10–20 ms behind)
        let dt = Float(n) / Float(AudioMixer.rate) * 1000
        if dk.enabled {
            let thr = powf(10, dk.thresholdDB / 20)
            if triggerPeakPrev > thr { duckHoldLeft = dk.holdMs }
            else { duckHoldLeft = max(0, duckHoldLeft - dt) }
            let floor = powf(10, min(0, dk.amountDB) / 20)
            let want: Float = duckHoldLeft > 0 ? floor : 1
            let tc = want < duckGain ? max(1, dk.attackMs) : max(1, dk.releaseMs)
            duckGain += (want - duckGain) * min(1, dt / tc * 2.5)
        } else {
            duckGain = 1
        }
        duckReductionDB = duckGain < 0.999 ? 20 * log10f(max(duckGain, 1e-4)) : 0
        var triggerPeak: Float = 0
        var anySolo = busSet.dropFirst().contains { $0.solo }
        var newMeters: [UUID: (Float, Float)] = [:]

        // drop ISO buffers no longer needed
        for (id, p) in isoBufs where !isoIDs.contains(id) {
            p.deallocate()
            isoBufs.removeValue(forKey: id)
        }

        for input in inputs {
            let ring = input.audio
            let params = input.audioParams
            if params.solo { anySolo = true }
            var avail = ring.available
            let delay = max(0, min(params.fx.delayMs, 1000)) * 48   // audio delay = extra buffering
            if !input.mixPrimed {
                if avail >= n + cushion + delay {
                    input.mixPrimed = true
                } else {
                    newMeters[input.id] = (0, 0)
                    if let iso = isoBufs[input.id] { iso.initialize(repeating: 0, count: n * 2) }
                    continue
                }
            }
            if avail > n + maxLatency + delay {
                ring.skip(frames: avail - n - cushion - delay)
                avail = ring.available
            }
            let got = ring.read(into: tmpBuf, frames: n)
            if got < n {
                (tmpBuf + got * 2).initialize(repeating: 0, count: (n - got) * 2)
                input.mixPrimed = false
            }
            // channel mode, noise gate, EQ, compressor (before gain, as in the Audio Settings order)
            let td = CACurrentMediaTime()
            input.dsp.process(params.fx, tmpBuf, frames: n)
            diagDSP += CACurrentMediaTime() - td
            // trim + balance / channel volume (pre-fader)
            let tl = params.trim * params.leftGain, tr = params.trim * params.rightGain
            if tl != 1 || tr != 1 {
                for i in 0..<n {
                    tmpBuf[i * 2] *= tl
                    tmpBuf[i * 2 + 1] *= tr
                }
            }
            if isoIDs.contains(input.id) {
                let iso: UnsafeMutablePointer<Float>
                if let p = isoBufs[input.id] {
                    iso = p
                } else {
                    iso = UnsafeMutablePointer<Float>.allocate(capacity: maxFrames * 2)
                    isoBufs[input.id] = iso
                }
                iso.update(from: tmpBuf, count: n * 2)
            }
            var target = params.muted ? 0 : params.gain
            if params.followsVideo { target *= weights[input.id] ?? 0 }
            if params.fx.ducked && !params.fx.duckTrigger { target *= duckGain }
            let g0 = input.mixLastGains[0]
            let step = (target - g0) / Float(n)
            var peakL: Float = 0, peakR: Float = 0
            let mask = params.busMask
            for i in 0..<n {
                let g = g0 + step * Float(i)
                let l = tmpBuf[i * 2] * g
                let r = tmpBuf[i * 2 + 1] * g
                tmpBuf[i * 2] = l
                tmpBuf[i * 2 + 1] = r
                peakL = max(peakL, abs(l))
                peakR = max(peakR, abs(r))
            }
            input.mixLastGains[0] = target
            for b in 0..<AudioMixer.busCount where mask & UInt8(1 << b) != 0 {
                let dst = busBufs[b]
                for i in 0..<(n * 2) { dst[i] += tmpBuf[i] }
            }
            if params.solo {
                for i in 0..<(n * 2) { soloBuf[i] += tmpBuf[i] }
            }
            newMeters[input.id] = (peakL, peakR)
            if params.fx.duckTrigger && !params.muted { triggerPeak = max(triggerPeak, peakL, peakR) }
        }
        triggerPeakPrev = triggerPeak

        let tm1 = CACurrentMediaTime()
        // aux buses: fader, mute, optional send to master, solo to headphones
        var busPeaks = [(Float, Float)](repeating: (0, 0), count: AudioMixer.busCount)
        for b in 1..<AudioMixer.busCount {
            let s = busSet[b]
            let target: Float = s.muted ? 0 : s.volume * s.volume
            applyGain(busBufs[b], n, from: lastBusGain[b], to: target)
            lastBusGain[b] = target
            busPeaks[b] = peaks(busBufs[b], n)
            if s.sendToMaster {
                let src = busBufs[b], dst = busBufs[0]
                for i in 0..<(n * 2) { dst[i] += src[i] }
            }
            if s.solo {
                let src = busBufs[b]
                for i in 0..<(n * 2) { soloBuf[i] += src[i] }
            }
        }
        let ms = busSet[0]
        let mTarget: Float = ms.muted ? 0 : ms.volume * ms.volume
        applyGain(busBufs[0], n, from: lastBusGain[0], to: mTarget)
        lastBusGain[0] = mTarget
        for b in 0..<AudioMixer.busCount {
            let p = busBufs[b]
            for i in 0..<(n * 2) { p[i] = max(-1, min(1, p[i])) }
        }
        busPeaks[0] = peaks(busBufs[0], n)
        let tl0 = CACurrentMediaTime()
        loudness.process(busBufs[0], n)
        diagLoud += CACurrentMediaTime() - tl0
        diagFrames = n

        let tm2 = CACurrentMediaTime()
        lock.lock()
        let tm3 = CACurrentMediaTime()
        for (id, peak) in newMeters {
            let old = meters[id] ?? (0, 0)
            meters[id] = (max(peak.0, old.0 * 0.85), max(peak.1, old.1 * 0.85))
        }
        if meters.count > newMeters.count {
            for key in meters.keys where newMeters[key] == nil { meters.removeValue(forKey: key) }
        }
        for b in 0..<AudioMixer.busCount {
            busMeters[b] = (max(busPeaks[b].0, busMeters[b].0 * 0.85), max(busPeaks[b].1, busMeters[b].1 * 0.85))
        }
        lock.unlock()

        let tm4 = CACurrentMediaTime()
        diagIn = tm1 - tm0; diagBus = tm2 - tm1; diagLockWait = tm3 - tm2; _ = tm4
        if monitoring {
            let src = anySolo ? soloBuf : busBufs[0]
            for i in 0..<(n * 2) { tmpBuf[i] = max(-1, min(1, src[i] * hpGain)) }
            monitorRing.write(tmpBuf, frames: n)
        }
        return n
    }

    /// Bus output for the last mix (0 = Master, 1…7 = A…G).
    func bus(_ index: Int) -> UnsafeMutablePointer<Float> {
        busBufs[max(0, min(AudioMixer.busCount - 1, index))]
    }

    /// Pre-fader feed of one input for the last mix (MultiCorder), if requested.
    func iso(_ id: UUID) -> UnsafePointer<Float>? {
        isoBufs[id].map { UnsafePointer($0) }
    }

    private func applyGain(_ p: UnsafeMutablePointer<Float>, _ n: Int, from g0: Float, to g1: Float) {
        if g0 == 1 && g1 == 1 { return }
        let step = (g1 - g0) / Float(n)
        for i in 0..<n {
            let g = g0 + step * Float(i)
            p[i * 2] *= g
            p[i * 2 + 1] *= g
        }
    }

    private func peaks(_ p: UnsafeMutablePointer<Float>, _ n: Int) -> (Float, Float) {
        var l: Float = 0, r: Float = 0
        for i in 0..<n {
            l = max(l, abs(p[i * 2]))
            r = max(r, abs(p[i * 2 + 1]))
        }
        return (l, r)
    }

    // MARK: Headphone monitoring (default output device)

    func setMonitoring(_ on: Bool) {
        if on == monitoring { return }
        if on {
            monitorRing.clear()
            let engine = AVAudioEngine()
            guard let fmt = AVAudioFormat(standardFormatWithSampleRate: Double(AudioMixer.rate), channels: 2) else { return }
            let ring = monitorRing
            let scratch = monitorScratch
            final class PrimedFlag { var value = false }
            let primed = PrimedFlag()
            let node = AVAudioSourceNode(format: fmt) { _, _, frameCount, ablPtr -> OSStatus in
                let abl = UnsafeMutableAudioBufferListPointer(ablPtr)
                let n = min(Int(frameCount), 8192)
                let avail = ring.available
                if !primed.value && avail >= 2400 { primed.value = true }
                if avail > 9600 { ring.skip(frames: avail - 2400) }
                let got = primed.value ? ring.read(into: scratch, frames: n) : 0
                if got < n { primed.value = false }
                guard abl.count >= 2,
                      let l = abl[0].mData?.assumingMemoryBound(to: Float.self),
                      let r = abl[1].mData?.assumingMemoryBound(to: Float.self) else { return noErr }
                for i in 0..<n {
                    if i < got {
                        l[i] = scratch[i * 2]
                        r[i] = scratch[i * 2 + 1]
                    } else {
                        l[i] = 0
                        r[i] = 0
                    }
                }
                return noErr
            }
            engine.attach(node)
            engine.connect(node, to: engine.mainMixerNode, format: fmt)
            do {
                try engine.start()
                monitorEngine = engine
                monitoring = true
            } catch {
                monitoring = false
            }
        } else {
            monitoring = false
            monitorEngine?.stop()
            monitorEngine = nil
        }
    }
}
