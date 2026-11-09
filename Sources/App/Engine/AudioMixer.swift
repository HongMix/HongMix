import Foundation
import AVFoundation
import QuartzCore
import CoreAudio
import AudioToolbox
import Combine

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
final class AudioMixer: ObservableObject {
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
    private let maxLatency = 14400   // files: cap excess source latency at 300 ms; trim back to the cushion
    private let liveSkipExcess = 24000   // live: hard-skip only beyond 500 ms over target (gross error, not drift)
    private let liveRetargetStep = 2400  // live: delay changes > 50 ms re-prime / trim instead of slow resampling

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
    /// Headphone monitor requested and not given up on (it may be waiting for its device to return).
    private(set) var monitoring = false
    private var monitorDeviceUID = ""      // outputQueue
    private var monitorFirstChannel = 0    // outputQueue
    private(set) var monitorError: String?
    private let routeRings = (0..<8).map { _ in RealtimeAudioRing(seconds: 3) }
    private var routeActive = [Bool](repeating: false, count: 8)   // lock; render thread writes these rings

    // Output devices (8 bus routes + headphone monitor). AVAudioEngine stops for good on a device
    // unplug or sample-rate change, so every engine is supervised: configuration-change notifications
    // and CoreAudio device-list changes rebuild it, and outputs whose device is gone wait (with a
    // visible status) and come back by themselves. All engine work runs on `outputQueue`.
    private final class OutputSlot {
        let name: String
        let ring: RealtimeAudioRing
        var route = AudioOutputRoute()   // device + channel pair to play on
        var wanted = false               // user has this output on
        var engine: AVAudioEngine?
        var observer: NSObjectProtocol?
        var generation = 0               // bumps on every stop; stale notifications are ignored
        var debounce = 0
        var waiting = false              // wanted but not running; retried on device changes / poll
        var status: String?
        var lastError: String?           // reason of the last failed start
        init(name: String, ring: RealtimeAudioRing) { self.name = name; self.ring = ring }
    }
    private static let monitorSlot = 8
    private static let slotNames = ["Master", "Bus A", "Bus B", "Bus C", "Bus D", "Bus E", "Bus F", "Bus G", "Headphones"]
    private let outputQueue = DispatchQueue(label: "HongMix.AudioOutputs", qos: .userInitiated)
    private let slots: [OutputSlot]
    private var slotWanted = [Bool](repeating: false, count: 9)          // lock (UI snapshot)
    private var slotStatus = [String?](repeating: nil, count: 9)         // lock (UI snapshot)
    private var deviceListener: AudioObjectPropertyListenerBlock?        // outputQueue
    private var deviceDebounce = 0                                       // outputQueue
    private var retryTimer: DispatchSourceTimer?                         // outputQueue
    /// Outputs that stopped and are waiting to recover ("Bus A: …"), empty when all are fine. Main thread.
    @Published private(set) var outputStatus = ""

    /// Snapshot of the final realtime rings feeding CoreAudio devices, distinct from each
    /// input's PCM buffer and from the software mixer underflow counters. Outputs waiting for their
    /// device are listed too, with the reason after the name.
    var outputRingStats: [AudioOutputRingStats] {
        var rows: [AudioOutputRingStats] = []
        lock.lock(); let wanted = slotWanted; let status = slotStatus; lock.unlock()
        for i in [AudioMixer.monitorSlot] + Array(0..<8) where wanted[i] {
            var name = AudioMixer.slotNames[i]
            if let s = status[i] { name += " — " + s }
            rows.append(Self.outputStats(name: name, ring: slots[i].ring))
        }
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
        var outs: [OutputSlot] = []
        for i in 0..<8 { outs.append(OutputSlot(name: AudioMixer.slotNames[i], ring: routeRings[i])) }
        outs.append(OutputSlot(name: AudioMixer.slotNames[AudioMixer.monitorSlot], ring: monitorRing))
        slots = outs
    }

    deinit {
        // No outputQueue.sync here: the last reference may be dropped on that queue.
        retryTimer?.cancel()
        if let block = deviceListener {
            var address = Self.devicesAddress
            AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, outputQueue, block)
        }
        for slot in slots {
            if let o = slot.observer { NotificationCenter.default.removeObserver(o) }
            slot.engine?.stop()
        }
        busBufs.forEach { $0.deallocate() }
        isoBufs.values.forEach { $0.deallocate() }
        tmpBuf.deallocate()
        soloBuf.deallocate()
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
        outputQueue.sync {
            guard uid != monitorDeviceUID || firstChannel != monitorFirstChannel else { return }
            monitorDeviceUID = uid
            monitorFirstChannel = firstChannel
            let slot = slots[Self.monitorSlot]
            slot.route = AudioOutputRoute(enabled: true, deviceUID: uid, firstChannel: firstChannel)
            if slot.wanted { startSlot(Self.monitorSlot) }
            publishOutputStatus()
        }
    }

    func setOutputRoutes(_ routes: [AudioOutputRoute]) {
        outputQueue.sync {
            for bus in 0..<8 {
                let slot = slots[bus]
                if bus < routes.count && routes[bus].enabled {
                    // This runs for every route edit (including the headphone row); leave an
                    // unchanged, running route alone — a restart is an audible gap.
                    if slot.wanted && slot.route == routes[bus] && slot.engine?.isRunning == true { continue }
                    slot.wanted = true
                    slot.route = routes[bus]
                    startSlot(bus)
                } else if slot.wanted || slot.engine != nil {
                    slot.wanted = false
                    stopSlot(bus)
                    slot.waiting = false
                    slot.status = nil
                }
            }
            publishOutputStatus()
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
            // Live sources run on their own clock and are read through the drift-compensating
            // resampler; transport-driven inputs (files, replay) keep the plain read.
            let live = Self.isLiveClocked(input.kind)
            // When audio follows video and this source is fully off-air, skip the
            // per-sample DSP. Keep the first block after a live fade in the normal path so the
            // gain ramp reaches zero cleanly; ISO recording and transition pre-roll also
            // retain their existing full processing paths.
            let offAir = params.followsVideo && (weights[input.id] ?? 0) <= 0
                && input.mixLastGains[0] == 0 && !isoIDs.contains(input.id) && !input.audioMixHeld
            if offAir && !live {
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
                // A reset source may come back on a different clock: relearn the rate.
                if live { ring.resetDrift(keepRate: false) }
            }
            var avail = sourceBuffer.available
            let delay = max(0, min(params.fx.delayMs, 1000)) * 48   // audio delay = extra buffering
            let fillTarget = cushion + delay
            if live {
                // The resampler corrects only ±0.5 %, far too slow for a delay-knob change:
                // re-prime to build up extra delay, drop the excess when it shrinks.
                let previous = ring.driftTarget
                ring.driftTarget = fillTarget
                if input.mixPrimed && abs(fillTarget - previous) > liveRetargetStep {
                    if fillTarget > previous {
                        input.mixPrimed = false
                    } else if avail > n + fillTarget {
                        ring.skip(frames: avail - n - fillTarget)
                        ring.resetDrift(keepRate: true)
                        avail = ring.available
                    }
                }
            }
            if !input.mixPrimed {
                if avail >= n + fillTarget {
                    input.mixPrimed = true
                    input.recordMixPrime()
                    if live { ring.resetDrift(keepRate: true) }
                } else {
                    meterScratch[input.id] = (0, 0)
                    if let iso = isoBufs[input.id] { iso.initialize(repeating: 0, count: n * 2) }
                    if offAir { flagsScratch[input.id] = 0 }
                    continue
                }
            }
            let got: Int
            if live {
                // Last-resort safety net only (source burst / stall recovery): normal drift never
                // gets here because the resampler holds the fill at `fillTarget`.
                if avail > n + fillTarget + liveSkipExcess {
                    ring.skip(frames: avail - n - fillTarget)
                    ring.resetDrift(keepRate: true)
                }
                got = ring.readAdaptive(into: tmpBuf, frames: n, target: fillTarget)
            } else {
                if avail > n + maxLatency + delay {
                    ring.skip(frames: avail - n - cushion - delay)
                    avail = ring.available
                }
                got = ring.read(into: tmpBuf, frames: n)
            }
            if got < n {
                (tmpBuf + got * 2).initialize(repeating: 0, count: (n - got) * 2)
                input.recordMixUnderflow()
                // Files: keep the stream primed after a brief underrun; requiring another
                // cushion turns a one-block decoder hiccup into a longer dropout.
                // Live: the drift-controlled cushion was fully drained, so the source really
                // stalled — re-prime to the cushion instead of streaming zeros (the resampler
                // faded the tail out and fades the restart in).
                if live { input.mixPrimed = false }
            }
            if offAir {
                // Live source off air: consumed at the controlled rate (not drained to zero) so the
                // cushion and lip-sync are intact when it is cut back to air. Meter only, no DSP.
                if got > 0 {
                    let pk = peaks(tmpBuf, got)
                    meterScratch[input.id] = (pk.0 * params.gain, pk.1 * params.gain)
                } else {
                    meterScratch[input.id] = (0, 0)
                }
                flagsScratch[input.id] = 0
                continue
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
            meters[id] = smoothMeter(old, toward: peak, frames: n)
        }
        if meters.count > meterScratch.count {
            for key in Array(meters.keys) where meterScratch[key] == nil { meters.removeValue(forKey: key) }
        }
        audioFlags = flagsScratch
        for b in 0..<AudioMixer.busCount {
            busMeters[b] = smoothMeter(busMeters[b], toward: busPeaks[b], frames: n)
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

    /// Sources clocked by their own hardware/network sender (drift against the mixer's 48 kHz).
    /// Files and replay are paced by the engine itself and keep the plain read path.
    private static func isLiveClocked(_ kind: InputKind) -> Bool {
        switch kind {
        case .camera, .stream, .ndi, .decklink, .screen, .browser, .audio: return true
        case .media, .replay, .color, .image, .title, .photos, .pdfSlides, .virtualSet: return false
        }
    }

    /// Broadcast-style meter ballistics. The old fixed `peak or old * 0.85` rule decayed by roughly
    /// 85 dB per second at 60 fps, making speech meters chatter even though the audio itself was fine.
    /// These coefficients are derived from the actual audio block duration, so the visual response is
    /// stable at every project frame rate: quick enough to catch consonants, slow enough to read.
    private func smoothMeter(_ old: (Float, Float), toward target: (Float, Float), frames: Int) -> (Float, Float) {
        let dt = Float(max(1, frames)) / Float(AudioMixer.rate)
        let attack = expf(-dt / 0.025)    // ~25 ms rise
        let release = expf(-dt / 0.450)   // ~450 ms fall
        func channel(_ previous: Float, _ next: Float) -> Float {
            let coefficient = next > previous ? attack : release
            let value = next + (previous - next) * coefficient
            return value < 0.00001 ? 0 : value
        }
        return (channel(old.0, target.0), channel(old.1, target.1))
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
        outputQueue.sync {
            let slot = slots[Self.monitorSlot]
            if on == slot.wanted { return }
            if on {
                slot.route = AudioOutputRoute(enabled: true, deviceUID: monitorDeviceUID, firstChannel: monitorFirstChannel)
                slot.wanted = true
                if !startSlot(Self.monitorSlot) {
                    // Switching the monitor on fails right away (the UI turns it back off) rather than
                    // waiting; only a monitor that was already playing waits for its device.
                    slot.wanted = false
                    slot.waiting = false
                    slot.status = slot.lastError
                }
            } else {
                slot.wanted = false
                stopSlot(Self.monitorSlot)
                slot.waiting = false
                slot.status = nil
            }
            publishOutputStatus()
        }
    }

    // MARK: Output supervision (outputQueue)

    private static var devicesAddress: AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices,
                                   mScope: kAudioObjectPropertyScopeGlobal,
                                   mElement: kAudioObjectPropertyElementMain)
    }

    private func setRouteActive(_ i: Int, _ active: Bool) {
        guard i < 8 else { return }
        lock.lock(); routeActive[i] = active; lock.unlock()
    }

    /// (Re)builds the engine of one output. On failure the slot waits and is retried on device
    /// changes and every 2 s. Returns whether the output is playing.
    @discardableResult
    private func startSlot(_ i: Int) -> Bool {
        let slot = slots[i]
        stopSlot(i)
        installDeviceListener()
        switch makeOutputEngine(ring: slot.ring, route: slot.route) {
        case .success(let engine):
            slot.engine = engine
            let generation = slot.generation
            slot.observer = NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange,
                                                                   object: engine, queue: nil) { [weak self] _ in
                self?.outputQueue.async { self?.outputConfigurationChanged(i, generation: generation) }
            }
            slot.waiting = false
            slot.status = nil
            setRouteActive(i, true)
            return true
        case .failure(let failure):
            slot.lastError = failure.message
            slot.waiting = true
            slot.status = Lf("%@ 장치가 돌아오면 자동으로 다시 연결합니다.", failure.message)
            startRetryTimer()
            return false
        }
    }

    private func stopSlot(_ i: Int) {
        let slot = slots[i]
        slot.generation &+= 1
        if let o = slot.observer { NotificationCenter.default.removeObserver(o) }
        slot.observer = nil
        setRouteActive(i, false)   // the mixer stops feeding this ring first
        slot.engine?.stop()
        slot.engine = nil
    }

    /// AVAudioEngineConfigurationChange: device unplugged, sample rate / channel layout changed.
    /// Debounced 0.5 s because a replug or rate change posts a burst of notifications.
    private func outputConfigurationChanged(_ i: Int, generation: Int) {
        let slot = slots[i]
        guard slot.wanted, slot.generation == generation else { return }
        slot.debounce &+= 1
        let token = slot.debounce
        outputQueue.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            guard let self, slot.debounce == token, slot.wanted, slot.generation == generation else { return }
            // Spurious notification (e.g. posted while the device was being assigned): leave a running
            // engine on a present device alone, otherwise rebuild it on the new configuration.
            if slot.engine?.isRunning == true, self.deviceIsPresent(slot.route.deviceUID) { return }
            self.startSlot(i)
            self.publishOutputStatus()
        }
    }

    private func deviceIsPresent(_ uid: String) -> Bool {
        uid.isEmpty || CoreAudioOutputs.devices().contains { $0.uid == uid }
    }

    /// CoreAudio device list changes (plug/unplug): notices a vanished device even when the engine
    /// posts no configuration change, and brings waiting outputs back as soon as their device returns.
    private func installDeviceListener() {
        guard deviceListener == nil else { return }
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            guard let self else { return }
            self.deviceDebounce &+= 1
            let token = self.deviceDebounce
            self.outputQueue.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                guard let self, self.deviceDebounce == token else { return }
                self.checkOutputs()
            }
        }
        var address = Self.devicesAddress
        if AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, outputQueue, block) == noErr {
            deviceListener = block
        }
    }

    /// Poll every 2 s while any output waits (covers devices that come back busy or late).
    private func startRetryTimer() {
        guard retryTimer == nil else { return }
        let timer = DispatchSource.makeTimerSource(queue: outputQueue)
        timer.schedule(deadline: .now() + 2, repeating: 2)
        timer.setEventHandler { [weak self] in self?.checkOutputs() }
        timer.resume()
        retryTimer = timer
    }

    /// Restarts outputs whose device vanished or whose engine stopped; retries waiting ones whose
    /// device is present again.
    private func checkOutputs() {
        let present = Set(CoreAudioOutputs.devices().map(\.uid))
        for i in slots.indices where slots[i].wanted {
            let slot = slots[i]
            let deviceHere = slot.route.deviceUID.isEmpty || present.contains(slot.route.deviceUID)
            if slot.waiting {
                if deviceHere { startSlot(i) }
            } else if !deviceHere || slot.engine?.isRunning != true {
                startSlot(i)   // marks it waiting, with a status, if the device is gone
            }
        }
        if !slots.contains(where: { $0.wanted && $0.waiting }) {
            retryTimer?.cancel()
            retryTimer = nil
        }
        publishOutputStatus()
    }

    private func publishOutputStatus() {
        let monitor = slots[Self.monitorSlot]
        monitoring = monitor.wanted
        monitorError = monitor.status
        lock.lock()
        for i in slots.indices {
            slotWanted[i] = slots[i].wanted
            slotStatus[i] = slots[i].wanted ? slots[i].status : nil
        }
        lock.unlock()
        var lines: [String] = []
        for i in slots.indices where slots[i].wanted {
            if let s = slots[i].status { lines.append("\(Self.slotNames[i]): \(s)") }
        }
        let summary = lines.joined(separator: " · ")
        DispatchQueue.main.async { [weak self] in
            guard let self, self.outputStatus != summary else { return }
            self.outputStatus = summary
        }
    }

    private enum OutputStartError: Error {
        case deviceMissing
        case openFailed(OSStatus)
        case startFailed(String)

        var message: String {
            switch self {
            case .deviceMissing: return L("선택한 오디오 출력 장치를 찾을 수 없습니다.")
            case .openFailed(let code): return Lf("오디오 출력 장치를 열 수 없습니다 (%@).", "\(code)")
            case .startFailed(let reason): return Lf("오디오 출력을 시작할 수 없습니다: %@", reason)
            }
        }
    }

    private func makeOutputEngine(ring: RealtimeAudioRing, route: AudioOutputRoute) -> Result<AVAudioEngine, OutputStartError> {
        ring.clear()
        let engine = AVAudioEngine()
        guard let fmt = AVAudioFormat(standardFormatWithSampleRate: Double(AudioMixer.rate), channels: 2) else {
            return .failure(.startFailed("format"))
        }
        if !route.deviceUID.isEmpty {
            guard let device = CoreAudioOutputs.devices().first(where: { $0.uid == route.deviceUID }),
                  let unit = engine.outputNode.audioUnit else { return .failure(.deviceMissing) }
            var deviceID = device.id
            let result = AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0,
                                              &deviceID, UInt32(MemoryLayout<AudioDeviceID>.size))
            guard result == noErr else { return .failure(.openFailed(result)) }
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
            // CoreAudio commonly asks for 4096–8192 frames on aggregate/HDMI devices: keep at least
            // ~50 ms queued, scaling up for large device callbacks (see outputCushion).
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
        // `scratch` is owned by `state` (freed in its deinit when the engine/node go away) — freeing it here
        // as well was a double free → crash when an output route's device was busy or missing.
        do {
            try engine.start()
            return .success(engine)
        } catch {
            return .failure(.startFailed(error.localizedDescription))
        }
    }

    /// CoreAudio callback sizes vary by device and aggregate configuration. A fixed
    /// 50 ms cushion can be drained in one large callback; scale it while respecting
    /// the 3 second ring's actual capacity.
    private static func outputCushion(for frames: Int) -> Int {
        let desired = max(2400, min(12000, frames / 2))
        return max(0, min(desired, 144000 - frames))
    }
}
