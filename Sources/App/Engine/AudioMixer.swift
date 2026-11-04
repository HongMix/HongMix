import Foundation
import AVFoundation
import QuartzCore
import CoreAudio
import AudioToolbox

struct AudioOutputDevice: Identifiable, Hashable {
    let id: AudioDeviceID
    let uid: String
    let name: String
    let channels: Int
}

struct AudioOutputRoute: Codable, Equatable {
    var enabled = false
    var deviceUID = ""       // empty = system default
    var firstChannel = 0      // zero based; stereo pair firstChannel + 1/2
}

struct AudioOutputRingStats {
    var name: String
    var shortReads: UInt64
    var shortFrames: UInt64
    var primingSilenceFrames: UInt64
    var availableFrames: Int
}

enum CoreAudioOutputs {
    static func devices() -> [AudioOutputDevice] {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size) == noErr else { return [] }
        let count = Int(size) / MemoryLayout<AudioDeviceID>.size
        var ids = [AudioDeviceID](repeating: 0, count: count)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &ids) == noErr else { return [] }
        return ids.compactMap { id in
            var streams = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreams,
                                                     mScope: kAudioDevicePropertyScopeOutput,
                                                     mElement: kAudioObjectPropertyElementMain)
            var streamSize: UInt32 = 0
            guard AudioObjectGetPropertyDataSize(id, &streams, 0, nil, &streamSize) == noErr, streamSize > 0,
                  let uid = string(id, kAudioDevicePropertyDeviceUID),
                  let name = string(id, kAudioObjectPropertyName) else { return nil }
            return AudioOutputDevice(id: id, uid: uid, name: name, channels: outputChannels(id))
        }.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    private static func string(_ id: AudioDeviceID, _ selector: AudioObjectPropertySelector) -> String? {
        var address = AudioObjectPropertyAddress(mSelector: selector,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var value: CFString? = nil
        var size = UInt32(MemoryLayout<CFString?>.size)
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &value) == noErr else { return nil }
        return value as String?
    }

    private static func outputChannels(_ id: AudioDeviceID) -> Int {
        var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreamConfiguration,
                                                 mScope: kAudioDevicePropertyScopeOutput,
                                                 mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &address, 0, nil, &size) == noErr else { return 2 }
        let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { raw.deallocate() }
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, raw) == noErr else { return 2 }
        let list = UnsafeMutableAudioBufferListPointer(raw.assumingMemoryBound(to: AudioBufferList.self))
        return max(1, list.reduce(0) { $0 + Int($1.mNumberChannels) })
    }
}

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
    /// Screen-capture, HDMI and aggregate CoreAudio devices can request 32768+ frames in one render
    /// callback. The old 8192 cap filled only the beginning and left the rest silent.
    private static let maxOutputCallbackFrames = 131072
    private let maxFrames = 48000
    private var busBufs: [UnsafeMutablePointer<Float>] = []
    private let tmpBuf: UnsafeMutablePointer<Float>
    private let soloBuf: UnsafeMutablePointer<Float>
    private var isoBufs: [UUID: UnsafeMutablePointer<Float>] = [:]   // render thread
    private let liveInputCushion = 5760 // 120 ms for capture/HDMI/aggregate clock jitter
    private let fileInputCushion = 2400 // 50 ms; file audio feeder schedules 100 ms ahead
    private let maxLatency = 14400   // cap excess source latency at 300 ms; trim back to the stable 120 ms cushion

    private let lock = NSLock()
    private var meters: [UUID: (Float, Float)] = [:]
    // Per input, last tick: bit 0 = reaching Master now, bit 1 = on air via Follow (lock).
    private var audioFlags: [UUID: UInt8] = [:]
    private var flagsScratch: [UUID: UInt8] = [:]    // render thread
    // Reuse this render-thread scratch map instead of allocating a fresh dictionary every video tick.
    private var meterScratch: [UUID: (Float, Float)] = [:]
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

    let monitorRing = RealtimeAudioRing(seconds: 3)
    // diagnostics (render thread): seconds spent in the last mix call
    var diagDSP: Double = 0, diagFrames = 0
    var diagIn: Double = 0, diagBus: Double = 0, diagLockWait: Double = 0
    private var monitorEngine: AVAudioEngine?
    private(set) var monitoring = false
    private var monitorDeviceUID = ""
    private var monitorFirstChannel = 0
    private(set) var monitorError: String?
    private let monitorScratch = UnsafeMutablePointer<Float>.allocate(capacity: AudioMixer.maxOutputCallbackFrames * 2)
    private let routeRings = (0..<8).map { _ in RealtimeAudioRing(seconds: 3) }
    private var routeEngines: [Int: AVAudioEngine] = [:]
    private var routeActive = [Bool](repeating: false, count: 8)

    /// Snapshot of the final realtime rings feeding CoreAudio devices, distinct from each
    /// input's PCM buffer and from the software mixer underflow counters.
    var outputRingStats: [AudioOutputRingStats] {
        var rows: [AudioOutputRingStats] = []
        if monitoring { rows.append(Self.outputStats(name: "Headphones", ring: monitorRing)) }
        lock.lock(); let active = routeActive; lock.unlock()
        let names = ["Master", "Bus A", "Bus B", "Bus C", "Bus D", "Bus E", "Bus F", "Bus G"]
        for i in active.indices where active[i] { rows.append(Self.outputStats(name: names[i], ring: routeRings[i])) }
        return rows
    }

    func resetOutputDiagnostics() {
        monitorRing.resetDiagnostics()
        routeRings.forEach { $0.resetDiagnostics() }
    }

    private static func outputStats(name: String, ring: RealtimeAudioRing) -> AudioOutputRingStats {
        let d = ring.diagnostics
        return AudioOutputRingStats(name: name, shortReads: d.shortReads, shortFrames: d.shortFrames,
                                    primingSilenceFrames: d.primingSilenceFrames, availableFrames: d.availableFrames)
    }

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

    func setMonitoringDevice(uid: String, firstChannel: Int = 0) {
        guard uid != monitorDeviceUID || firstChannel != monitorFirstChannel else { return }
        monitorDeviceUID = uid
        monitorFirstChannel = firstChannel
        if monitoring {
            setMonitoring(false)
            setMonitoring(true)
        }
    }

    func setOutputRoutes(_ routes: [AudioOutputRoute]) {
        for engine in routeEngines.values { engine.stop() }
        routeEngines.removeAll()
        lock.lock(); routeActive = [Bool](repeating: false, count: 8); lock.unlock()
        for bus in 0..<min(8, routes.count) where routes[bus].enabled {
            if let engine = makeOutputEngine(ring: routeRings[bus], route: routes[bus]) {
                routeEngines[bus] = engine
                lock.lock(); routeActive[bus] = true; lock.unlock()
            }
        }
    }

    /// Input reached the Master bus in the last mix tick.
    func reachesMaster(_ id: UUID) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return (audioFlags[id] ?? 0) & 1 != 0
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
        diagDSP = 0
        let tm0 = CACurrentMediaTime()
        for b in busBufs { b.initialize(repeating: 0, count: n * 2) }
        soloBuf.initialize(repeating: 0, count: n * 2)
        lock.lock()
        let busSet = buses
        let hpGain = headphonesGain
        let dk = duck
        let activeRoutes = routeActive
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
        meterScratch.removeAll(keepingCapacity: true)
        flagsScratch.removeAll(keepingCapacity: true)

        // drop ISO buffers no longer needed
        for (id, p) in isoBufs where !isoIDs.contains(id) {
            p.deallocate()
            isoBufs.removeValue(forKey: id)
        }

        for input in inputs {
            let ring = input.audio
            let params = input.audioParams
            // A file input being cued for a transition must be allowed to fill its PCM
            // ring before it becomes audible. Keep the queued samples instead of draining
            // them into zero-gain preview blocks.
            if input.audioMixHeld && params.followsVideo && (weights[input.id] ?? 0) <= 0 {
                meterScratch[input.id] = (0, 0)
                if let iso = isoBufs[input.id] { iso.initialize(repeating: 0, count: n * 2) }
                continue
            }
            if params.solo { anySolo = true }
            // When audio follows video and this source is fully off-air, consume its
            // real-time PCM ring without copying samples or running per-sample DSP.
            // Keep the first block after a live fade in the normal path so the gain
            // ramp reaches zero cleanly; ISO recording and transition pre-roll also
            // retain their existing full processing paths.
            if params.followsVideo, (weights[input.id] ?? 0) <= 0,
               input.mixLastGains[0] == 0, !isoIDs.contains(input.id), !input.audioMixHeld {
                // Off air: no DSP, but still show the input level (dimmed in the UI) so the operator
                // can see the source has sound before taking it.
                let got = ring.read(into: tmpBuf, frames: n)
                if got > 0 {
                    let pk = peaks(tmpBuf, got)
                    let g = params.gain
                    meterScratch[input.id] = (pk.0 * g, pk.1 * g)
                } else {
                    meterScratch[input.id] = (0, 0)
                }
                flagsScratch[input.id] = 0
                continue
            }
            // mc_input.c releases file audio 100 ms ahead of its media PTS. A 120 ms
            // priming requirement exceeds that lookahead and can make file inputs starve.
            // Use 50 ms for files while preserving the larger live-device safety margin.
            let cushion = input.kind == .media ? fileInputCushion : liveInputCushion
            let sourceBuffer = ring.mixSnapshot
            if input.mixBufferGeneration != sourceBuffer.generation {
                // Pause, seek, or source reset cleared the PCM ring. Discard the stale
                // primed state so playback waits for fresh audio instead of emitting
                // repeated short reads while the decoder refills the buffer.
                input.mixBufferGeneration = sourceBuffer.generation
                input.mixPrimed = false
            }
            var avail = sourceBuffer.available
            let delay = max(0, min(params.fx.delayMs, 1000)) * 48   // audio delay = extra buffering
            if !input.mixPrimed {
                if avail >= n + cushion + delay {
                    input.mixPrimed = true
                    input.recordMixPrime()
                } else {
                    meterScratch[input.id] = (0, 0)
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
                // Keep the stream primed after a brief underrun. The current block
                // conceals only the missing samples; requiring another 120 ms of
                // queued audio here turns a one-block scheduling hiccup into a much
                // longer audible dropout.
                input.recordMixUnderflow()
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
            // Meter = input level after the fader (not after Follow/Mute), so off-air sources still show.
            let inPeak = peaks(tmpBuf, n)
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
            _ = (peakL, peakR)
            meterScratch[input.id] = (inPeak.0 * params.gain, inPeak.1 * params.gain)
            var fl: UInt8 = 0
            if target > 0.0001 && params.busMask & 1 != 0 { fl |= 1 }
            if params.followsVideo && (weights[input.id] ?? 0) > 0 { fl |= 2 }
            flagsScratch[input.id] = fl
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
        diagFrames = n

        let tm2 = CACurrentMediaTime()
        lock.lock()
        let tm3 = CACurrentMediaTime()
        for (id, peak) in meterScratch {
            let old = meters[id] ?? (0, 0)
            meters[id] = (max(peak.0, old.0 * 0.85), max(peak.1, old.1 * 0.85))
        }
        if meters.count > meterScratch.count {
            for key in Array(meters.keys) where meterScratch[key] == nil { meters.removeValue(forKey: key) }
        }
        audioFlags = flagsScratch
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
        for b in 0..<8 where activeRoutes[b] { routeRings[b].write(busBufs[b], frames: n) }
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

    // MARK: Headphone monitoring (selectable CoreAudio output device)

    func setMonitoring(_ on: Bool) {
        if on == monitoring { return }
        if on {
            monitorRing.clear()
            let engine = AVAudioEngine()
            guard let fmt = AVAudioFormat(standardFormatWithSampleRate: Double(AudioMixer.rate), channels: 2) else { return }
            if !monitorDeviceUID.isEmpty {
                guard let device = CoreAudioOutputs.devices().first(where: { $0.uid == monitorDeviceUID }),
                      let unit = engine.outputNode.audioUnit else {
                    monitorError = "선택한 오디오 출력 장치를 찾을 수 없습니다."
                    return
                }
                var deviceID = device.id
                let result = AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice,
                                                  kAudioUnitScope_Global, 0, &deviceID,
                                                  UInt32(MemoryLayout<AudioDeviceID>.size))
                guard result == noErr else {
                    monitorError = "오디오 출력 장치를 열 수 없습니다 (\(result))."
                    return
                }
                let count = max(2, device.channels)
                var map = [Int32](repeating: -1, count: count)
                let first = max(0, min(count - 1, monitorFirstChannel))
                map[first] = 0
                if first + 1 < count { map[first + 1] = 1 }
                map.withUnsafeBytes { bytes in
                    _ = AudioUnitSetProperty(unit, kAudioOutputUnitProperty_ChannelMap, kAudioUnitScope_Global, 0,
                                             bytes.baseAddress, UInt32(bytes.count))
                }
            }
            let ring = monitorRing
            let scratch = monitorScratch
            engine.outputNode.auAudioUnit.maximumFramesToRender = AUAudioFrameCount(AudioMixer.maxOutputCallbackFrames)
            final class PrimedFlag { var value = false }
            let primed = PrimedFlag()
            let node = AVAudioSourceNode(format: fmt) { _, _, frameCount, ablPtr -> OSStatus in
                let abl = UnsafeMutableAudioBufferListPointer(ablPtr)
                let n = min(Int(frameCount), AudioMixer.maxOutputCallbackFrames)
                let avail = ring.available
                // CoreAudio commonly asks for 4096–8192 frames on aggregate/HDMI devices. Priming
                // with a fixed 2400 frames made every large callback drain the ring, producing the
                // repeating 0.3–0.5 s gaps seen on otherwise continuous playlist audio.
                // Keep at least ~50 ms queued, scaling up for large device callbacks. The
                // ring is 3 s (144k frames), so never require more than it can hold.
                let cushion = Self.outputCushion(for: n)
                if !primed.value && avail >= n + cushion { primed.value = true }
                if avail > n + max(9600, cushion * 3) { ring.skip(frames: avail - n - cushion) }
                let wasPrimed = primed.value
                let got = wasPrimed ? ring.read(into: scratch, frames: n) : 0
                if !wasPrimed { ring.notePrimingSilence(frames: n) }
                // 1.3.32: a short underrun used to drop the monitor back into the startup-prime
                // state, muting it for another ≥50 ms (up to 250 ms on large device callbacks)
                // until the cushion refilled — the audible "audio frame drops" on headphones/monitor.
                // Same policy as the main output: conceal only the missing samples and keep going.
                guard abl.count >= 2,
                      let l = abl[0].mData?.assumingMemoryBound(to: Float.self),
                      let r = abl[1].mData?.assumingMemoryBound(to: Float.self) else { return noErr }
                for i in 0..<Int(frameCount) {
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
                monitorError = nil
            } catch {
                monitoring = false
                monitorError = error.localizedDescription
            }
        } else {
            monitoring = false
            monitorEngine?.stop()
            monitorEngine = nil
        }
    }


    private func makeOutputEngine(ring: RealtimeAudioRing, route: AudioOutputRoute) -> AVAudioEngine? {
        ring.clear()
        let engine = AVAudioEngine()
        guard let fmt = AVAudioFormat(standardFormatWithSampleRate: Double(AudioMixer.rate), channels: 2) else { return nil }
        if !route.deviceUID.isEmpty {
            guard let device = CoreAudioOutputs.devices().first(where: { $0.uid == route.deviceUID }),
                  let unit = engine.outputNode.audioUnit else { return nil }
            var deviceID = device.id
            guard AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0,
                                       &deviceID, UInt32(MemoryLayout<AudioDeviceID>.size)) == noErr else { return nil }
            let count = max(2, device.channels)
            var map = [Int32](repeating: -1, count: count)
            let first = max(0, min(count - 1, route.firstChannel))
            map[first] = 0
            if first + 1 < count { map[first + 1] = 1 }
            map.withUnsafeBytes { bytes in
                _ = AudioUnitSetProperty(unit, kAudioOutputUnitProperty_ChannelMap, kAudioUnitScope_Global, 0,
                                         bytes.baseAddress, UInt32(bytes.count))
            }
        }
        let scratch = UnsafeMutablePointer<Float>.allocate(capacity: AudioMixer.maxOutputCallbackFrames * 2)
        engine.outputNode.auAudioUnit.maximumFramesToRender = AUAudioFrameCount(AudioMixer.maxOutputCallbackFrames)
        final class State {
            var primed = false
            let scratch: UnsafeMutablePointer<Float>
            init(_ p: UnsafeMutablePointer<Float>) { scratch = p }
            deinit { scratch.deallocate() }
        }
        let state = State(scratch)
        let node = AVAudioSourceNode(format: fmt) { _, _, frameCount, ablPtr -> OSStatus in
            let abl = UnsafeMutableAudioBufferListPointer(ablPtr)
            let n = min(Int(frameCount), AudioMixer.maxOutputCallbackFrames)
            let avail = ring.available
            let cushion = Self.outputCushion(for: n)
            if !state.primed && avail >= n + cushion { state.primed = true }
            if avail > n + max(9600, cushion * 3) { ring.skip(frames: avail - n - cushion) }
            let wasPrimed = state.primed
            let got = wasPrimed ? ring.read(into: state.scratch, frames: n) : 0
            if !wasPrimed { ring.notePrimingSilence(frames: n) }
            // Don't re-enter the long startup-prime state after a short device-side
            // underrun. Emit silence only for the missing part of this callback and
            // resume consuming as soon as the producer has written more audio.
            guard abl.count >= 2,
                  let l = abl[0].mData?.assumingMemoryBound(to: Float.self),
                  let r = abl[1].mData?.assumingMemoryBound(to: Float.self) else { return noErr }
            for i in 0..<Int(frameCount) {
                l[i] = i < got ? state.scratch[i * 2] : 0
                r[i] = i < got ? state.scratch[i * 2 + 1] : 0
            }
            return noErr
        }
        engine.attach(node)
        engine.connect(node, to: engine.mainMixerNode, format: fmt)
        do { try engine.start(); return engine } catch { scratch.deallocate(); return nil }
    }

    /// CoreAudio callback sizes vary by device and aggregate configuration. A fixed
    /// 50 ms cushion can be drained in one large callback; scale it while respecting
    /// the 3 second ring's actual capacity.
    private static func outputCushion(for frames: Int) -> Int {
        let desired = max(2400, min(12000, frames / 2))
        return max(0, min(desired, 144000 - frames))
    }
}
