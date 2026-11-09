import Foundation
import CoreMIDI
#if !MIDI_STANDALONE_TEST
import Combine
#endif

// MIDI controller engine (vMix-style "Settings › MIDI").
//
// Layout of this file
//   1. Pure model + logic (no app dependencies; compiled by tests/midi/run.sh with -D MIDI_STANDALONE_TEST):
//      MIDIInMessage / MIDIByteParser (parsing), MIDIMapping / MIDIMapper (match → action, learn,
//      soft takeover, T-bar flip), MIDILEDProfile (LED tally bytes), MIDITemplate (device presets).
//   2. MIDITransport — thin CoreMIDI layer (client, input/output port, hot-plug, UMP decode/encode).
//   3. MIDIRouter — glues transport + mapper + LED diffing with injected closures (dispatcher, current
//      values, tally). Also testable without the app.
//   4. MIDIControl — the app-facing ObservableObject (UserDefaults "midiSettings", engine bindings,
//      APIProcessor dispatch). Excluded from the standalone test build.
//
// Threading: CoreMIDI delivers input on its own high-priority thread. That thread only decodes UMP
// words into MIDIInMessage values and appends them to a lock-protected queue (bounded, no allocation
// beyond the array append, never waits on the main thread). One main-queue drain per burst then
// coalesces fader moves, matches mappings and dispatches through APIProcessor on the main thread.

// MARK: - 1. Pure model

enum MIDIMessageKind: String, Codable, CaseIterable {
    case note            // note on/off (note off = value 0)
    case controlChange
    case programChange
    case pitchBend

    var shortName: String {
        switch self {
        case .note: return "Note"
        case .controlChange: return "CC"
        case .programChange: return "PC"
        case .pitchBend: return "Pitch Bend"
        }
    }
}

/// One parsed MIDI 1.0 channel-voice message.
struct MIDIInMessage: Equatable {
    var kind: MIDIMessageKind
    var channel: Int     // 0…15
    var number: Int      // note / controller / program number; 0 for pitch bend
    var value: Int       // velocity (0 = note off) / CC value / 0 for PC / 14-bit bend (8192 = centre)

    var isNoteOff: Bool { kind == .note && value == 0 }
    /// 0…1 for continuous use.
    var normalized: Double {
        switch kind {
        case .pitchBend: return Double(value) / 16383
        case .programChange: return Double(number) / 127
        default: return Double(value) / 127
        }
    }

    /// Builds a message from a status byte and its data bytes (nil for non channel-voice messages).
    static func make(status: UInt8, _ d1: UInt8, _ d2: UInt8) -> MIDIInMessage? {
        let ch = Int(status & 0x0F)
        let a = Int(d1 & 0x7F), b = Int(d2 & 0x7F)
        switch status & 0xF0 {
        case 0x80: return MIDIInMessage(kind: .note, channel: ch, number: a, value: 0)
        case 0x90: return MIDIInMessage(kind: .note, channel: ch, number: a, value: b)   // vel 0 = note off
        case 0xB0: return MIDIInMessage(kind: .controlChange, channel: ch, number: a, value: b)
        case 0xC0: return MIDIInMessage(kind: .programChange, channel: ch, number: a, value: 0)
        case 0xE0: return MIDIInMessage(kind: .pitchBend, channel: ch, number: 0, value: a | (b << 7))
        default: return nil   // poly/channel pressure and system messages are not mappable
        }
    }

    /// Raw MIDI 1.0 bytes (used by tests and the virtual-port loopback).
    var bytes: [UInt8] {
        let c = UInt8(channel & 0x0F)
        switch kind {
        case .note: return value == 0 ? [0x80 | c, UInt8(number), 0] : [0x90 | c, UInt8(number), UInt8(value)]
        case .controlChange: return [0xB0 | c, UInt8(number), UInt8(value)]
        case .programChange: return [0xC0 | c, UInt8(number)]
        case .pitchBend: return [0xE0 | c, UInt8(value & 0x7F), UInt8((value >> 7) & 0x7F)]
        }
    }

    /// Human-readable, e.g. "nanoKONTROL2 · CC 0 = 64" (channel shown when not 1).
    func describe(device: String) -> String {
        var s: String
        switch kind {
        case .note: s = value == 0 ? "Note \(number) off" : "Note \(number) = \(value)"
        case .controlChange: s = "CC \(number) = \(value)"
        case .programChange: s = "PC \(number)"
        case .pitchBend: s = "Pitch Bend = \(value)"
        }
        if channel != 0 { s += " (ch \(channel + 1))" }
        return device.isEmpty ? s : "\(device) · \(s)"
    }
}

/// MIDI 1.0 byte-stream parser with running status; skips SysEx and real-time bytes.
struct MIDIByteParser {
    private var status: UInt8 = 0
    private var data: [UInt8] = []
    private var inSysEx = false

    mutating func feed(_ bytes: [UInt8]) -> [MIDIInMessage] {
        var out: [MIDIInMessage] = []
        for b in bytes {
            if b >= 0xF8 { continue }                       // real-time: clock, start, active sensing …
            if b == 0xF0 { inSysEx = true; status = 0; data.removeAll(); continue }
            if b == 0xF7 { inSysEx = false; continue }
            if inSysEx { if b & 0x80 == 0 { continue } else { inSysEx = false } }
            if b & 0x80 != 0 {
                if b >= 0xF0 { status = 0; data.removeAll(); continue }   // system common clears running status
                status = b; data.removeAll(); continue
            }
            guard status != 0 else { continue }              // stray data byte
            data.append(b)
            let need = (status & 0xF0 == 0xC0 || status & 0xF0 == 0xD0) ? 1 : 2
            if data.count == need {
                if let m = MIDIInMessage.make(status: status, data[0], need == 2 ? data[1] : 0) { out.append(m) }
                data.removeAll()                             // keep status (running status)
            }
        }
        return out
    }
}

/// Which controller a mapping listens to. Matching: by uniqueID while a source with that ID is
/// online, otherwise by (case-insensitive) name — so a re-enumerated device with a new ID still works.
struct MIDISourceInfo: Hashable {
    var name: String
    var uniqueID: Int32
}

/// One controller mapping. `function`/`input`/`value` are the same strings as the HTTP API
/// (/api/?Function=…&Input=…&Value=…). For continuous mappings `value` is computed from the control.
struct MIDIMapping: Codable, Identifiable, Equatable {
    var id = UUID()
    var deviceName = ""          // "" = any device
    var deviceUniqueID: Int32 = 0
    var kind: MIDIMessageKind = .note
    var channel = 0              // 0…15, -1 = any channel
    var number = 0               // note / CC / program number (ignored for pitch bend)
    var function = ""
    var input = ""
    var value = ""
    var continuous = false       // faders/knobs: Value follows the control
    var pickup = true            // soft takeover for continuous mappings
    var label = ""               // optional name shown in the UI

    init(id: UUID = UUID(), deviceName: String = "", deviceUniqueID: Int32 = 0, kind: MIDIMessageKind = .note,
         channel: Int = 0, number: Int = 0, function: String = "", input: String = "", value: String = "",
         continuous: Bool = false, pickup: Bool = true, label: String = "") {
        self.id = id; self.deviceName = deviceName; self.deviceUniqueID = deviceUniqueID; self.kind = kind
        self.channel = channel; self.number = number; self.function = function; self.input = input
        self.value = value; self.continuous = continuous; self.pickup = pickup; self.label = label
    }

    // Tolerant decoding: settings written by older/newer builds never wipe the whole list.
    private enum K: String, CodingKey { case id, deviceName, deviceUniqueID, kind, channel, number, function, input, value, continuous, pickup, label }
    init(from d: Decoder) throws {
        let c = try d.container(keyedBy: K.self)
        id = (try? c.decode(UUID.self, forKey: .id)) ?? UUID()
        deviceName = (try? c.decode(String.self, forKey: .deviceName)) ?? ""
        deviceUniqueID = (try? c.decode(Int32.self, forKey: .deviceUniqueID)) ?? 0
        kind = (try? c.decode(MIDIMessageKind.self, forKey: .kind)) ?? .note
        channel = (try? c.decode(Int.self, forKey: .channel)) ?? 0
        number = (try? c.decode(Int.self, forKey: .number)) ?? 0
        function = (try? c.decode(String.self, forKey: .function)) ?? ""
        input = (try? c.decode(String.self, forKey: .input)) ?? ""
        value = (try? c.decode(String.self, forKey: .value)) ?? ""
        continuous = (try? c.decode(Bool.self, forKey: .continuous)) ?? false
        pickup = (try? c.decode(Bool.self, forKey: .pickup)) ?? true
        label = (try? c.decode(String.self, forKey: .label)) ?? ""
    }

    /// "Note 12 · ch 1", "CC 48" … (control part only).
    var controlDescription: String {
        let ch = channel < 0 ? "" : (channel == 0 ? "" : " (ch \(channel + 1))")
        switch kind {
        case .pitchBend: return "Pitch Bend" + ch
        default: return "\(kind.shortName) \(number)" + ch
        }
    }

    /// "PreviewInput · Input 3", "SetVolume · Input 1 · 0–100" …
    var actionDescription: String {
        var s = function
        if !input.isEmpty { s += " · Input \(input)" }
        if continuous {
            if let r = MIDIMapper.continuousRange(function) { s += " · \(Int(r.lowerBound))–\(Int(r.upperBound))" }
        } else if !value.isEmpty { s += " · Value \(value)" }
        return s
    }
}

/// What the user picked before pressing "Learn".
struct MIDIActionDraft: Equatable {
    var function: String
    var input = ""
    var value = ""
    /// nil = decide from the control (CC / pitch bend + a fader-type function with empty Value → continuous)
    var continuous: Bool? = nil
}

/// A function call produced by a mapping, ready for APIProcessor.perform (keys lowercase like parseQuery).
struct MIDIDispatch: Equatable {
    var function: String
    var query: [String: String]
    var mappingID: UUID
}

enum MIDIMapperOutput: Equatable {
    case dispatch(MIDIDispatch)
    case learned(MIDIMapping, isNew: Bool)
}

/// Pure mapping engine: message → matching mappings → dispatches. Holds learn, edge and pickup state.
/// Used on the main thread only (current values come from the engine there).
struct MIDIMapper {
    var mappings: [MIDIMapping] = []
    var learnDraft: MIDIActionDraft?

    /// Pickup tolerance (normalised): ≈ 4 CC steps.
    static let pickupTolerance = 0.03

    private struct Pickup { var pickedUp = false; var lastIncoming: Double?; var lastSent: Double? }
    private var pickup: [UUID: Pickup] = [:]
    private var tbarFlipped: [UUID: Bool] = [:]
    private var down: [String: Bool] = [:]     // CC / pitch-bend button state for edge detection

    init(mappings: [MIDIMapping] = []) { self.mappings = mappings }

    /// API value range of continuous targets (nil = function can't be driven by a fader).
    static func continuousRange(_ function: String) -> ClosedRange<Double>? {
        let f = function.lowercased()
        if f == "setfader" { return 0...255 }
        if ["setvolume", "setmastervolume", "setheadphonesvolume", "setvolumechannel1", "setvolumechannel2"].contains(f) { return 0...100 }
        if f.hasPrefix("setbus"), f.hasSuffix("volume"), f.count == "setbusavolume".count { return 0...100 }
        return nil
    }

    /// Functions whose LED shows the tally of `input`, and the tally they represent on single-colour LEDs.
    static func tallyRole(_ m: MIDIMapping) -> MIDITally? {
        guard !m.continuous, !m.input.isEmpty else { return nil }
        switch m.function.lowercased() {
        case "previewinput": return .preview
        case "cutdirect", "activeinput", "quickplay": return .program
        default: return nil
        }
    }

    static func deviceMatches(_ m: MIDIMapping, _ src: MIDISourceInfo, onlineIDs: Set<Int32>) -> Bool {
        if m.deviceName.isEmpty && m.deviceUniqueID == 0 { return true }
        if m.deviceUniqueID != 0, onlineIDs.contains(m.deviceUniqueID) { return m.deviceUniqueID == src.uniqueID }
        return m.deviceName.caseInsensitiveCompare(src.name) == .orderedSame
    }

    static func controlMatches(_ m: MIDIMapping, _ msg: MIDIInMessage) -> Bool {
        guard m.kind == msg.kind else { return false }
        if m.channel >= 0 && m.channel != msg.channel { return false }
        return msg.kind == .pitchBend || m.number == msg.number
    }

    func matching(_ msg: MIDIInMessage, from src: MIDISourceInfo, onlineIDs: Set<Int32>) -> [MIDIMapping] {
        mappings.filter { Self.controlMatches($0, msg) && Self.deviceMatches($0, src, onlineIDs: onlineIDs) }
    }

    /// Drops intermediate fader/knob moves of a burst, keeping the first and the last one per control
    /// (the first keeps soft-takeover crossing detection intact). Only controls that feed continuous
    /// mappings are merged — button presses/releases are never dropped.
    func coalesce(_ batch: [(MIDIInMessage, MIDISourceInfo)], onlineIDs: Set<Int32>) -> [(MIDIInMessage, MIDISourceInfo)] {
        guard batch.count > 2 else { return batch }
        var firstIndex: [String: Int] = [:]
        var lastIndex: [String: Int] = [:]
        var continuousKey = [String?](repeating: nil, count: batch.count)
        for (i, (m, s)) in batch.enumerated() {
            let maps = matching(m, from: s, onlineIDs: onlineIDs)
            guard !maps.isEmpty, maps.allSatisfy({ $0.continuous }) else { continue }
            let k = "\(s.uniqueID)/\(m.kind.rawValue)/\(m.channel)/\(m.number)"
            continuousKey[i] = k
            if firstIndex[k] == nil { firstIndex[k] = i }
            lastIndex[k] = i
        }
        return batch.enumerated().compactMap { i, e in
            if let k = continuousKey[i], lastIndex[k] != i, firstIndex[k] != i { return nil }
            return e
        }
    }

    /// Forget fader positions (device re-plugged, mappings edited).
    mutating func resetContinuousState() { pickup.removeAll(); tbarFlipped.removeAll(); down.removeAll() }

    /// Handles one message. `current` returns the target's present value normalised to 0…1
    /// (nil = unknown → no soft takeover).
    mutating func handle(_ msg: MIDIInMessage, from src: MIDISourceInfo, onlineIDs: Set<Int32>,
                         current: (MIDIMapping) -> Double?) -> [MIDIMapperOutput] {
        // Button edge (CC / pitch bend used as buttons): press = crossing the midpoint upwards.
        let edgeKey = "\(src.uniqueID)/\(msg.kind.rawValue)/\(msg.channel)/\(msg.number)"
        var isPress: Bool
        switch msg.kind {
        case .note: isPress = msg.value > 0
        case .programChange: isPress = true
        case .controlChange, .pitchBend:
            let isDown = msg.kind == .controlChange ? msg.value >= 64 : msg.value >= 12288
            isPress = isDown && !(down[edgeKey] ?? false)
            down[edgeKey] = isDown
        }

        if let draft = learnDraft {
            if msg.isNoteOff { return [] }                       // learn on press / movement only
            if (msg.kind == .controlChange || msg.kind == .pitchBend) && !isPress {
                // a fader move also learns (any CC value); a button release (0) after a learned press doesn't
                let wantsContinuous = draft.continuous ?? (Self.continuousRange(draft.function) != nil && draft.value.isEmpty)
                if !wantsContinuous { return [] }
            }
            learnDraft = nil
            return [learn(msg, from: src, draft: draft)]
        }

        var out: [MIDIMapperOutput] = []
        for m in matching(msg, from: src, onlineIDs: onlineIDs) {
            if m.continuous {
                guard msg.kind != .programChange else { continue }
                out += continuousOutputs(m, msg.normalized, current: current)
            } else if isPress {
                var q: [String: String] = [:]
                if !m.input.isEmpty { q["input"] = m.input }
                if !m.value.isEmpty { q["value"] = m.value }
                out.append(.dispatch(MIDIDispatch(function: m.function, query: q, mappingID: m.id)))
            }
        }
        return out
    }

    private mutating func learn(_ msg: MIDIInMessage, from src: MIDISourceInfo, draft: MIDIActionDraft) -> MIDIMapperOutput {
        let canBeContinuous = msg.kind == .controlChange || msg.kind == .pitchBend || msg.kind == .note
        let continuous = canBeContinuous && Self.continuousRange(draft.function) != nil &&
            (draft.continuous ?? ((msg.kind == .controlChange || msg.kind == .pitchBend) && draft.value.isEmpty))
        let number = msg.kind == .pitchBend ? 0 : msg.number
        if let i = mappings.firstIndex(where: {
            $0.kind == msg.kind && $0.channel == msg.channel && $0.number == number &&
            ($0.deviceUniqueID == src.uniqueID || $0.deviceName.caseInsensitiveCompare(src.name) == .orderedSame)
        }) {
            mappings[i].function = draft.function
            mappings[i].input = draft.input
            mappings[i].value = continuous ? "" : draft.value
            mappings[i].continuous = continuous
            mappings[i].deviceName = src.name
            mappings[i].deviceUniqueID = src.uniqueID
            pickup[mappings[i].id] = nil
            return .learned(mappings[i], isNew: false)
        }
        let m = MIDIMapping(deviceName: src.name, deviceUniqueID: src.uniqueID, kind: msg.kind, channel: msg.channel,
                            number: number, function: draft.function, input: draft.input,
                            value: continuous ? "" : draft.value, continuous: continuous)
        mappings.append(m)
        return .learned(m, isNew: true)
    }

    static func formatValue(_ v: Double, function: String) -> String {
        if function.lowercased() == "setfader" { return String(Int(v.rounded())) }
        let r = (v * 10).rounded() / 10
        return r == r.rounded() ? String(Int(r)) : String(format: "%.1f", r)
    }

    private func dispatch(_ m: MIDIMapping, _ x: Double) -> MIDIMapperOutput {
        let r = Self.continuousRange(m.function) ?? 0...127
        var q: [String: String] = ["value": Self.formatValue(r.lowerBound + x * (r.upperBound - r.lowerBound), function: m.function)]
        if !m.input.isEmpty { q["input"] = m.input }
        return .dispatch(MIDIDispatch(function: m.function, query: q, mappingID: m.id))
    }

    /// Soft takeover ("pickup"): the control is ignored until it reaches or crosses the target's current
    /// value; it is dropped again when the target was changed elsewhere (UI, API, auto transition).
    /// T-bar (SetFader): like a hardware switcher lever, the direction flips after each completed
    /// transition (top → bottom drives the next one), so the lever never has to be pulled back first.
    private mutating func continuousOutputs(_ m: MIDIMapping, _ raw: Double, current: (MIDIMapping) -> Double?) -> [MIDIMapperOutput] {
        let isTBar = m.function.lowercased() == "setfader"
        var st = pickup[m.id] ?? Pickup()
        let flipped = tbarFlipped[m.id] ?? false
        let x = isTBar && flipped ? 1 - raw : raw
        let tol = Self.pickupTolerance
        if m.pickup, let cur = current(m) {
            if st.pickedUp, let sent = st.lastSent, abs(cur - sent) > tol { st.pickedUp = false }
            if !st.pickedUp {
                if abs(x - cur) <= tol { st.pickedUp = true }
                else if let prev = st.lastIncoming, (prev - cur) * (x - cur) < 0 { st.pickedUp = true }
            }
        } else {
            st.pickedUp = true
        }
        st.lastIncoming = x
        guard st.pickedUp else { pickup[m.id] = st; return [] }
        var out: [MIDIMapperOutput] = []
        if isTBar && x >= 0.999 {
            // A completed pull. If the lever jumped straight from rest (fast flick, coalesced), start the
            // transition first so the engine performs the take instead of ignoring a bare 255.
            if (st.lastSent ?? 0) < 0.004 { out.append(dispatch(m, 1.0 / 255)) }
            out.append(dispatch(m, 1))
            tbarFlipped[m.id] = !flipped
            st.lastSent = 0          // the engine resets its T-bar to 0 after the take
            st.lastIncoming = 0
            pickup[m.id] = st
            return out
        }
        st.lastSent = x
        pickup[m.id] = st
        return [dispatch(m, x)]
    }
}

// MARK: LED feedback

enum MIDITally: Int, Comparable {
    case off = 0, preview = 1, program = 2
    static func < (a: MIDITally, b: MIDITally) -> Bool { a.rawValue < b.rawValue }
}

/// LED protocols of the supported controllers. Only these profiles ever receive LED messages —
/// unknown devices (synths etc.) are never sent anything.
enum MIDILEDProfile: String, Codable, CaseIterable {
    case none
    /// Akai APC mini (mk1). Pads notes 0–63 (0 = bottom-left), Note On ch 1, velocity 0 off,
    /// 1 green, 2 green blink, 3 red, 4 red blink, 5 yellow, 6 yellow blink. Round track buttons
    /// notes 64–71 (red) and scene buttons 82–89 (green): 0 off, 1 on, 2 blink.
    /// Source: community protocol notes, github.com/TomasHubelbauer/akai-apc-mini (notes 0x00–0x3F,
    /// 0x40–0x47, 0x52–0x59, shift 0x62, faders CC 0x30–0x38) and Ableton's APC mini script colours.
    case apcMiniMk1
    /// Akai APC mini mk2. Pads notes 0x00–0x3F, colour = velocity from the fixed 128-entry palette
    /// (5 = #FF0000, 21 = #00FF00, 13 = #FFFF00, 0 = off), behaviour = MIDI channel (0x90–0x96 solid
    /// 10 %…100 %, 0x97–0x9A pulse, 0x9B–0x9F blink). Track buttons 0x64–0x6B (red) and scene
    /// buttons 0x70–0x77 (green) use 0x90 + velocity 0 off / 1 on / 2 blink.
    /// Source: Akai "APC mini mk2 Communications Protocol v1.0" (2023-01-23), cdn.inmusicbrands.com.
    case apcMiniMk2
    /// Behringer X-Touch Mini, standard mode. Button LEDs: Note On on the GLOBAL channel (default 1),
    /// notes 0–7 upper row, 8–15 lower row; velocity 0 off, 1 on, 2 blink. (The buttons themselves
    /// send notes 8–23 in preset A / 32–47 in preset B on ch 11, so LED note = sent note − 8 for preset A.)
    /// Source: Behringer X-TOUCH MINI Quick Start Guide, "MIDI map" and "RX MIDI data" tables.
    case xTouchMini
    /// Korg nanoKONTROL2 (factory CC scene, ch 1). LEDs echo the button's CC: 127 on, 0 off — only
    /// after "LED Mode = External" is set in KORG KONTROL Editor (Internal mode lights on press).
    case nanoKontrol2

    static func detect(_ name: String) -> MIDILEDProfile {
        let n = name.lowercased()
        if n.contains("apc mini mk2") || n.contains("apc mini mkii") || n.contains("apc mini 2") { return .apcMiniMk2 }
        if n.contains("apc mini") { return .apcMiniMk1 }
        if n.contains("x-touch mini") || n.contains("x-touch-mini") || n.contains("xtouch mini") { return .xTouchMini }
        if n.contains("nanokontrol2") { return .nanoKontrol2 }
        return .none
    }

    /// The LED message for a mapping in a tally state (nil = this control has no addressable LED).
    func led(for m: MIDIMapping, tally: MIDITally) -> [UInt8]? {
        guard let role = MIDIMapper.tallyRole(m), m.number >= 0, m.number <= 127 else { return nil }
        let n = UInt8(m.number)
        let single: UInt8 = tally == role ? 1 : 0          // single-colour LEDs show "their" tally
        switch self {
        case .none:
            return nil
        case .apcMiniMk1:
            guard m.kind == .note else { return nil }
            switch m.number {
            case 0...63: return [0x90, n, tally == .program ? 3 : (tally == .preview ? 1 : 0)]
            case 64...71, 82...89: return [0x90, n, single]
            default: return nil
            }
        case .apcMiniMk2:
            guard m.kind == .note else { return nil }
            switch m.number {
            case 0...63: return [0x96, n, tally == .program ? 5 : (tally == .preview ? 21 : 0)]
            case 100...107, 112...119: return [0x90, n, single]
            default: return nil
            }
        case .xTouchMini:
            guard m.kind == .note, (8...23).contains(m.number) else { return nil }   // preset A buttons
            return [0x90, n - 8, single]
        case .nanoKontrol2:
            guard m.kind == .controlChange, m.channel >= 0 else { return nil }
            let buttons = Array(32...39) + Array(48...55) + Array(64...71) + [41, 42, 43, 44, 45, 46, 58, 59, 60, 61, 62]
            guard buttons.contains(m.number) else { return nil }
            return [0xB0 | UInt8(m.channel & 0x0F), n, single == 1 ? 127 : 0]
        }
    }

    /// Desired LED state for all mappings of one device: address (status<<8 | note) → message.
    func frame(_ mappings: [MIDIMapping], tally: (MIDIMapping) -> MIDITally) -> [UInt16: [UInt8]] {
        var out: [UInt16: [UInt8]] = [:]
        for m in mappings {
            guard let b = led(for: m, tally: tally(m)) else { continue }
            let key = UInt16(b[0]) << 8 | UInt16(b[1])
            if let old = out[key], old[2] >= b[2], old[2] != 0 { continue }   // two mappings on one pad: lit wins
            out[key] = b
        }
        return out
    }

    /// Messages needed to go from `previous` to `desired` (only changes; removed LEDs are turned off).
    static func diff(_ desired: [UInt16: [UInt8]], _ previous: [UInt16: [UInt8]]) -> [[UInt8]] {
        var out: [[UInt8]] = []
        for k in desired.keys.sorted() where previous[k] != desired[k] { out.append(desired[k]!) }
        for k in previous.keys.sorted() where desired[k] == nil {
            let p = previous[k]!
            if p[2] != 0 { out.append([p[0], p[1], 0]) }
        }
        return out
    }
}

// MARK: Templates

/// Built-in one-step presets. Mappings are created for the chosen device (name + uniqueID).
struct MIDITemplate: Identifiable {
    let id: String
    let name: String
    let profile: MIDILEDProfile
    let build: () -> [MIDIMapping]

    func mappings(for device: MIDISourceInfo) -> [MIDIMapping] {
        build().map { var m = $0; m.deviceName = device.name; m.deviceUniqueID = device.uniqueID; return m }
    }

    /// Best template for a device name (nil = none).
    static func suggested(for deviceName: String) -> MIDITemplate? {
        let p = MIDILEDProfile.detect(deviceName)
        return all.first { $0.profile == p && p != .none }
    }

    private static func note(_ n: Int, ch: Int = 0, _ f: String, _ input: String = "", _ value: String = "", _ label: String = "") -> MIDIMapping {
        MIDIMapping(kind: .note, channel: ch, number: n, function: f, input: input, value: value, label: label)
    }
    private static func cc(_ n: Int, ch: Int = 0, _ f: String, _ input: String = "", continuous: Bool = false, _ label: String = "") -> MIDIMapping {
        MIDIMapping(kind: .controlChange, channel: ch, number: n, function: f, input: input, continuous: continuous, label: label)
    }

    /// Scene / transport buttons shared by the APC templates.
    private static let sceneFunctions = ["Cut", "Fade", "Transition2", "Transition3", "Transition4",
                                         "FadeToBlack", "OverlayInputAllOff", "StartStopRecording"]

    /// APC mini mk1 and mk2 share the layout; only the round-button notes differ.
    private static func apc(track: Int, scene: Int) -> [MIDIMapping] {
        var m: [MIDIMapping] = []
        for i in 0..<8 {
            m.append(note(i, "PreviewInput", "\(i + 1)"))               // bottom pad row → Preview 1–8
            m.append(note(8 + i, "CutDirect", "\(i + 1)"))              // row above → Program 1–8
            m.append(note(16 + i, "OverlayInput1", "\(i + 1)"))         // 3rd row → overlay 1 on/off
            m.append(note(track + i, "Audio", "\(i + 1)"))              // track buttons → mute toggle
            m.append(note(scene + i, sceneFunctions[i]))                // scene buttons (top → bottom)
            m.append(cc(48 + i, "SetVolume", "\(i + 1)", continuous: true))   // faders 1–8 → volume 1–8
        }
        m.append(cc(56, "SetFader", continuous: true))                  // fader 9 → T-bar
        return m
    }

    static let all: [MIDITemplate] = [
        // Korg nanoKONTROL2 factory CC map (ch 1): sliders CC 0–7, knobs 16–23, S 32–39, M 48–55,
        // R 64–71, Play 41, Stop 42, Rew 43, FF 44, Rec 45, Cycle 46, Track◀ 58, Track▶ 59,
        // Marker Set 60, Marker◀ 61, Marker▶ 62.
        // Source: Ardour's share/midi_maps/Korg_nanoKONTROL2.map (github.com/Ardour/ardour) and the Korg
        // nanoKONTROL2 Parameter Guide. Buttons must stay "Momentary" (127/0); LEDs need LED Mode External.
        MIDITemplate(id: "nanokontrol2", name: "Korg nanoKONTROL2", profile: .nanoKontrol2) {
            var m: [MIDIMapping] = []
            for i in 0..<8 {
                m.append(cc(i, "SetVolume", "\(i + 1)", continuous: true))      // sliders → volume 1–8
                m.append(cc(32 + i, "PreviewInput", "\(i + 1)"))                 // S → Preview
                m.append(cc(48 + i, "Audio", "\(i + 1)"))                        // M → mute toggle
                m.append(cc(64 + i, "CutDirect", "\(i + 1)"))                    // R → Program
            }
            m.append(cc(16, "SetMasterVolume", continuous: true))                // knob 1 → master
            m.append(cc(17, "SetHeadphonesVolume", continuous: true))            // knob 2 → headphones
            m.append(cc(23, "SetFader", continuous: true))                       // knob 8 → T-bar
            m.append(cc(41, "Cut"))                                              // ▶ Play
            m.append(cc(42, "Fade"))                                             // ■ Stop
            m.append(cc(46, "FadeToBlack"))                                      // Cycle
            m.append(cc(45, "StartStopRecording"))                               // ● Rec
            m.append(cc(58, "PreviewInputPrevious"))                             // Track ◀
            m.append(cc(59, "PreviewInputNext"))                                 // Track ▶
            return m
        },
        // Akai APC mini (mk1): pads notes 0–63 (0 = bottom-left), track buttons 64–71, scene buttons
        // 82–89, Shift 98, faders CC 48–56 (fader 9 = master). Source: see MIDILEDProfile.apcMiniMk1.
        MIDITemplate(id: "apcmini", name: "Akai APC mini", profile: .apcMiniMk1) { apc(track: 64, scene: 82) },
        // Akai APC mini mk2: pads 0x00–0x3F, track buttons 0x64–0x6B, scene 0x70–0x77, Shift 0x7A,
        // faders CC 48–56 (as mk1). Source: Akai "APC mini mk2 Communications Protocol v1.0";
        // shift/fader numbers from the Bome forum "APC mini mk2 LED mapping summary".
        MIDITemplate(id: "apcminimk2", name: "Akai APC mini mk2", profile: .apcMiniMk2) { apc(track: 100, scene: 112) },
        // Behringer X-Touch Mini, standard mode, ch 11: preset A encoders CC 1–8 (push notes 0–7),
        // buttons notes 8–15 (upper) / 16–23 (lower), fader CC 9; preset B encoders CC 11–18 (push 24–31),
        // buttons 32–39 / 40–47, fader CC 10. Source: Behringer X-TOUCH MINI Quick Start Guide "MIDI map".
        MIDITemplate(id: "xtouchmini", name: "Behringer X-Touch Mini", profile: .xTouchMini) {
            var m: [MIDIMapping] = []
            for i in 0..<8 {
                m.append(note(8 + i, ch: 10, "PreviewInput", "\(i + 1)"))        // A upper row → Preview
                m.append(note(16 + i, ch: 10, "CutDirect", "\(i + 1)"))          // A lower row → Program
                m.append(note(i, ch: 10, "Audio", "\(i + 1)"))                    // A encoder push → mute
                m.append(cc(1 + i, ch: 10, "SetVolume", "\(i + 1)", continuous: true))   // A encoders → volume
                m.append(note(32 + i, ch: 10, "OverlayInput1", "\(i + 1)"))      // B upper row → overlay 1
                m.append(note(40 + i, ch: 10, sceneFunctions[i]))                 // B lower row → transitions
            }
            m.append(cc(9, ch: 10, "SetFader", continuous: true))                 // A fader → T-bar
            m.append(cc(10, ch: 10, "SetFader", continuous: true))                // B fader → T-bar
            m.append(cc(11, ch: 10, "SetMasterVolume", continuous: true))         // B encoder 1 → master
            m.append(cc(12, ch: 10, "SetHeadphonesVolume", continuous: true))     // B encoder 2 → headphones
            return m
        },
    ]
}

// MARK: - 2. CoreMIDI transport

/// Thin CoreMIDI layer: one client, one input port connected to every source, one output port.
/// Hot-plug: kMIDIMsgSetupChanged → `refresh()` on the main thread reconnects all sources.
final class MIDITransport {
    struct Endpoint: Equatable {
        let ref: MIDIEndpointRef
        let uniqueID: Int32
        let name: String
        let entity: MIDIEntityRef     // 0 for virtual endpoints
        let device: MIDIDeviceRef     // 0 for virtual endpoints
        var info: MIDISourceInfo { MIDISourceInfo(name: name, uniqueID: uniqueID) }
    }

    /// Main thread: a burst of decoded messages (in arrival order).
    var onMessages: (([(MIDIInMessage, MIDISourceInfo)]) -> Void)?
    /// Main thread: after the source/destination lists changed.
    var onSetupChanged: (() -> Void)?

    private(set) var sources: [Endpoint] = []
    private(set) var destinations: [Endpoint] = []
    private(set) var started = false
    private var client = MIDIClientRef()
    private var inPort = MIDIPortRef()
    private var outPort = MIDIPortRef()
    private var connected: [Int32: MIDIEndpointRef] = [:]
    private var refreshScheduled = false

    // CoreMIDI thread → main thread hand-off
    private let lock = NSLock()
    private var queue: [(MIDIInMessage, Int32)] = []
    private var drainScheduled = false
    private static let queueLimit = 8192

    init() {}

    deinit {
        if inPort != 0 { MIDIPortDispose(inPort) }
        if outPort != 0 { MIDIPortDispose(outPort) }
        if client != 0 { MIDIClientDispose(client) }
    }

    /// Creates the client and ports (main thread). Returns noErr on success.
    @discardableResult
    func start(clientName: String = "HongMix") -> OSStatus {
        guard !started else { return noErr }
        var st = MIDIClientCreateWithBlock(clientName as CFString, &client) { [weak self] n in
            // Called on the run loop that created the client (main). Coalesce bursts of notifications.
            guard n.pointee.messageID == .msgSetupChanged else { return }
            DispatchQueue.main.async { self?.scheduleRefresh() }
        }
        guard st == noErr else { return st }
        st = MIDIInputPortCreateWithProtocol(client, "\(clientName) In" as CFString, ._1_0, &inPort) { [weak self] list, srcRef in
            self?.receive(list, uid: MIDITransport.uid(from: srcRef))
        }
        guard st == noErr else { return st }
        st = MIDIOutputPortCreate(client, "\(clientName) Out" as CFString, &outPort)
        guard st == noErr else { return st }
        started = true
        refresh()
        return noErr
    }

    private func scheduleRefresh() {
        guard !refreshScheduled else { return }
        refreshScheduled = true
        // devices often announce several objects in a row; wait for the burst to settle
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
            self?.refreshScheduled = false
            self?.refresh()
        }
    }

    // refCon carries the source's uniqueID (bit 40 set so uniqueID 0 still gives a non-nil pointer)
    private static func refCon(_ uid: Int32) -> UnsafeMutableRawPointer? {
        UnsafeMutableRawPointer(bitPattern: Int(UInt32(bitPattern: uid)) | (1 << 40))
    }
    private static func uid(from p: UnsafeMutableRawPointer?) -> Int32 {
        Int32(bitPattern: UInt32(truncatingIfNeeded: Int(bitPattern: p) & 0xFFFF_FFFF))
    }

    static func endpoint(_ e: MIDIEndpointRef) -> Endpoint {
        var uid: Int32 = 0
        MIDIObjectGetIntegerProperty(e, kMIDIPropertyUniqueID, &uid)
        var name: Unmanaged<CFString>?
        var s = ""
        if MIDIObjectGetStringProperty(e, kMIDIPropertyDisplayName, &name) == noErr, let n = name {
            s = n.takeRetainedValue() as String
        } else if MIDIObjectGetStringProperty(e, kMIDIPropertyName, &name) == noErr, let n = name {
            s = n.takeRetainedValue() as String
        }
        var entity = MIDIEntityRef()
        if MIDIEndpointGetEntity(e, &entity) != noErr { entity = 0 }
        var device = MIDIDeviceRef()
        if entity == 0 || MIDIEntityGetDevice(entity, &device) != noErr { device = 0 }
        return Endpoint(ref: e, uniqueID: uid, name: s, entity: entity, device: device)
    }

    private static func isOffline(_ e: MIDIEndpointRef) -> Bool {
        var off: Int32 = 0
        return MIDIObjectGetIntegerProperty(e, kMIDIPropertyOffline, &off) == noErr && off != 0
    }

    /// Re-enumerates endpoints and (re)connects every source. Main thread.
    func refresh() {
        guard started else { return }
        var srcs: [Endpoint] = []
        for i in 0..<MIDIGetNumberOfSources() {
            let e = MIDIGetSource(i)
            guard e != 0, !Self.isOffline(e) else { continue }
            srcs.append(Self.endpoint(e))
        }
        var dsts: [Endpoint] = []
        for i in 0..<MIDIGetNumberOfDestinations() {
            let e = MIDIGetDestination(i)
            guard e != 0, !Self.isOffline(e) else { continue }
            dsts.append(Self.endpoint(e))
        }
        let ids = Set(srcs.map { $0.uniqueID })
        for (uid, ref) in connected where !ids.contains(uid) {
            MIDIPortDisconnectSource(inPort, ref)
            connected[uid] = nil
        }
        for s in srcs where connected[s.uniqueID] != s.ref {
            if let old = connected[s.uniqueID] { MIDIPortDisconnectSource(inPort, old) }
            if MIDIPortConnectSource(inPort, s.ref, Self.refCon(s.uniqueID)) == noErr { connected[s.uniqueID] = s.ref }
        }
        let changed = srcs != sources || dsts != destinations
        sources = srcs
        destinations = dsts
        if changed { onSetupChanged?() }
    }

    /// The output that belongs to a source: same entity, else same device with a matching name,
    /// else a destination with exactly the same name (virtual ports, most class-compliant devices).
    func destination(for source: MIDISourceInfo) -> Endpoint? {
        guard let s = sources.first(where: { $0.uniqueID == source.uniqueID }) ?? sources.first(where: { $0.name == source.name }) else {
            return destinations.first { $0.name == source.name }
        }
        if s.entity != 0, let d = destinations.first(where: { $0.entity == s.entity }) { return d }
        if s.device != 0, let d = destinations.first(where: { $0.device == s.device && $0.name == s.name }) { return d }
        return destinations.first { $0.name == s.name }
    }

    // MARK: receive (CoreMIDI thread — never blocks, never touches the main thread synchronously)

    private func receive(_ list: UnsafePointer<MIDIEventList>, uid: Int32) {
        var msgs: [MIDIInMessage] = []
        Self.decode(list) { msgs.append($0) }
        guard !msgs.isEmpty else { return }
        lock.lock()
        for m in msgs { queue.append((m, uid)) }
        if queue.count > Self.queueLimit { queue.removeFirst(queue.count - Self.queueLimit) }
        let schedule = !drainScheduled
        drainScheduled = true
        lock.unlock()
        if schedule { DispatchQueue.main.async { [weak self] in self?.drain() } }
    }

    /// UMP decode: only MIDI 1.0 channel-voice packets (message type 2).
    static func decode(_ list: UnsafePointer<MIDIEventList>, _ emit: (MIDIInMessage) -> Void) {
        let wordsOffset = MemoryLayout<MIDIEventPacket>.offset(of: \MIDIEventPacket.words) ?? 12
        for packet in list.unsafeSequence() {
            let count = Int(packet.pointee.wordCount)
            let words = UnsafeRawPointer(packet).advanced(by: wordsOffset).assumingMemoryBound(to: UInt32.self)
            var i = 0
            while i < count {
                let w = words[i]
                let type = w >> 28
                if type == 0x2, let m = MIDIInMessage.make(status: UInt8((w >> 16) & 0xFF), UInt8((w >> 8) & 0xFF), UInt8(w & 0xFF)) {
                    emit(m)
                }
                // UMP sizes by message type: 0–2 = 1 word, 3–4 = 2, 5 = 4, others per spec
                switch type {
                case 0x0, 0x1, 0x2, 0x6, 0x7: i += 1
                case 0x3, 0x4, 0x8, 0x9, 0xA: i += 2
                case 0xB, 0xC: i += 3
                default: i += 4
                }
            }
        }
    }

    private func drain() {
        lock.lock()
        let batch = queue
        queue.removeAll(keepingCapacity: true)
        drainScheduled = false
        lock.unlock()
        guard !batch.isEmpty else { return }
        var names: [Int32: String] = [:]
        for s in sources { names[s.uniqueID] = s.name }
        onMessages?(batch.map { ($0.0, MIDISourceInfo(name: names[$0.1] ?? "MIDI", uniqueID: $0.1)) })
    }

    // MARK: send

    /// Sends MIDI 1.0 channel-voice messages (each [status, d1, d2] or [status, d1]) as UMP.
    @discardableResult
    func send(_ messages: [[UInt8]], to dest: MIDIEndpointRef) -> OSStatus {
        guard started, dest != 0, !messages.isEmpty else { return noErr }
        var result: OSStatus = noErr
        let chunk = 48
        var start = 0
        let size = 1024 + chunk * 16
        let raw = UnsafeMutableRawPointer.allocate(byteCount: size, alignment: 8)
        defer { raw.deallocate() }
        let list = raw.bindMemory(to: MIDIEventList.self, capacity: 1)
        while start < messages.count {
            let part = messages[start..<min(messages.count, start + chunk)]
            var packet: UnsafeMutablePointer<MIDIEventPacket>? = MIDIEventListInit(list, ._1_0)
            for m in part where !m.isEmpty {
                var w = Self.umpWord(m)
                packet = MIDIEventListAdd(list, size, packet!, 0, 1, &w)
                if packet == nil { break }
            }
            let st = MIDISendEventList(outPort, dest, list)
            if st != noErr { result = st }
            start += chunk
        }
        return result
    }

    static func umpWord(_ m: [UInt8]) -> UInt32 {
        let s = UInt32(m[0]), a = m.count > 1 ? UInt32(m[1] & 0x7F) : 0, b = m.count > 2 ? UInt32(m[2] & 0x7F) : 0
        return 0x2000_0000 | (s << 16) | (a << 8) | b
    }
}

// MARK: - 3. Router (transport + mapper + LEDs)

/// Everything except the engine bindings and UI state. Main thread.
final class MIDIRouter {
    let transport = MIDITransport()
    var mapper = MIDIMapper()
    var enabled = true
    var ledFeedback = true

    /// Executes an API function (app: APIProcessor.perform). Returns an error string or nil.
    var dispatcher: (String, [String: String]) -> String? = { _, _ in nil }
    /// Current target value normalised to 0…1 for soft takeover (nil = unknown).
    var currentValue: (MIDIMapping) -> Double? = { _ in nil }
    /// Tally of an input string ("1", name, GUID).
    var tally: (String) -> MIDITally = { _ in .off }
    /// Every incoming message (after learn/dispatch), for "last message" display.
    var onMessage: ((MIDIInMessage, MIDISourceInfo) -> Void)?
    var onLearned: ((MIDIMapping, Bool) -> Void)?
    var onDispatchError: ((MIDIDispatch, String) -> Void)?
    var onDevicesChanged: (() -> Void)?

    private var ledCache: [Int32: [UInt16: [UInt8]]] = [:]    // destination uniqueID → last sent frame

    init() {
        transport.onMessages = { [weak self] in self?.handle($0) }
        transport.onSetupChanged = { [weak self] in
            guard let self else { return }
            // a re-plugged controller has unknown LED and fader positions
            let ids = Set(self.transport.destinations.map { $0.uniqueID })
            self.ledCache = self.ledCache.filter { ids.contains($0.key) }
            self.mapper.resetContinuousState()
            self.onDevicesChanged?()
            self.updateLEDs(force: true)
        }
    }

    var onlineIDs: Set<Int32> { Set(transport.sources.map { $0.uniqueID }) }

    func handle(_ batch: [(MIDIInMessage, MIDISourceInfo)]) {
        let online = onlineIDs
        let msgs = mapper.learnDraft == nil ? mapper.coalesce(batch, onlineIDs: online) : batch
        for (m, src) in msgs {
            onMessage?(m, src)
            guard enabled || mapper.learnDraft != nil else { continue }
            for out in mapper.handle(m, from: src, onlineIDs: online, current: currentValue) {
                switch out {
                case .dispatch(let d):
                    if let err = dispatcher(d.function, d.query) { onDispatchError?(d, err) }
                case .learned(let map, let isNew):
                    onLearned?(map, isNew)
                }
            }
        }
    }

    /// Recomputes LED frames for every online controller with a known LED profile and sends changes.
    func updateLEDs(force: Bool = false) {
        if force { ledCache.removeAll() }
        for s in transport.sources {
            let profile = MIDILEDProfile.detect(s.name)
            guard profile != .none, let d = transport.destination(for: s.info) else { continue }
            let maps = mapper.mappings.filter { MIDIMapper.deviceMatches($0, s.info, onlineIDs: onlineIDs) }
            let desired = (enabled && ledFeedback) ? profile.frame(maps) { m in self.tally(m.input) } : [:]
            let previous = ledCache[d.uniqueID] ?? (force ? Self.allOff(profile, maps) : [:])
            let msgs = MIDILEDProfile.diff(desired, previous)
            if !msgs.isEmpty { transport.send(msgs, to: d.ref) }
            ledCache[d.uniqueID] = desired
        }
    }

    /// On (re)connect the device's LEDs are in an unknown state: treat every mapped LED as lit so the
    /// first diff explicitly turns off the ones that should be dark.
    private static func allOff(_ p: MIDILEDProfile, _ maps: [MIDIMapping]) -> [UInt16: [UInt8]] {
        var out: [UInt16: [UInt8]] = [:]
        for m in maps {
            guard let b = p.led(for: m, tally: .program) else { continue }
            out[UInt16(b[0]) << 8 | UInt16(b[1])] = [b[0], b[1], 0x7F]
        }
        return out
    }
}

// MARK: - 4. App integration

#if !MIDI_STANDALONE_TEST

/// Persisted MIDI settings (UserDefaults "midiSettings", JSON like "captionSettings").
struct MIDISettings: Codable, Equatable {
    var enabled = true
    var ledFeedback = true
    var mappings: [MIDIMapping] = []

    init() {}
    private enum K: String, CodingKey { case enabled, ledFeedback, mappings }
    init(from d: Decoder) throws {
        let c = try d.container(keyedBy: K.self)
        enabled = (try? c.decode(Bool.self, forKey: .enabled)) ?? true
        ledFeedback = (try? c.decode(Bool.self, forKey: .ledFeedback)) ?? true
        mappings = (try? c.decode([MIDIMapping].self, forKey: .mappings)) ?? []
    }
}

/// App-facing MIDI controller state for "Settings › MIDI". Main thread only.
final class MIDIControl: ObservableObject {
    struct Device: Identifiable, Equatable {
        var id: String { "\(name)#\(uniqueID)" }
        var name: String
        var uniqueID: Int32
        var online: Bool
        var hasOutput: Bool               // LED feedback possible
        var profile: MIDILEDProfile
        var mappingCount: Int
        var suggestedTemplateID: String?
        var info: MIDISourceInfo { MIDISourceInfo(name: name, uniqueID: uniqueID) }
    }

    static let defaultsKey = "midiSettings"

    /// Online sources + devices that only exist in saved mappings (offline).
    @Published private(set) var devices: [Device] = []
    @Published var mappings: [MIDIMapping] = [] {
        didSet {
            guard mappings != oldValue else { return }
            router.mapper.mappings = mappings
            save()
            refreshDevices()
            scheduleLEDs()
        }
    }
    @Published var enabled = true {
        didSet { guard enabled != oldValue else { return }; router.enabled = enabled; save(); scheduleLEDs() }
    }
    @Published var ledFeedback = true {
        didSet { guard ledFeedback != oldValue else { return }; router.ledFeedback = ledFeedback; save(); scheduleLEDs() }
    }
    @Published private(set) var learning = false
    @Published private(set) var learnDraft: MIDIActionDraft?
    /// e.g. "nanoKONTROL2 · CC 0 = 64" (updated at most ~20×/s)
    @Published private(set) var lastMessage = ""
    /// Status / error line (localised), e.g. learn result or CoreMIDI failure.
    @Published private(set) var status = ""

    static var templates: [MIDITemplate] { MIDITemplate.all }
    /// Continuous targets offered for faders/knobs (function, label).
    static var continuousTargets: [(function: String, label: String)] {
        [("SetFader", L("T-바")), ("SetVolume", L("입력 볼륨")), ("SetMasterVolume", L("마스터 볼륨")),
         ("SetHeadphonesVolume", L("헤드폰 볼륨"))] +
        AudioBus.aux.map { ("SetBus\($0)Volume", Lf("버스 %@ 볼륨", $0)) }
    }

    private let router = MIDIRouter()
    private weak var engine: SwitcherEngine?
    private var bag: Set<AnyCancellable> = []
    private var ledTimer: Timer?
    private var ledScheduled = false
    private var pendingLast: String?
    private var lastScheduled = false

    init() {
        if let d = UserDefaults.standard.data(forKey: Self.defaultsKey),
           let s = try? JSONDecoder().decode(MIDISettings.self, from: d) {
            enabled = s.enabled
            ledFeedback = s.ledFeedback
            mappings = s.mappings
        }
        router.mapper.mappings = mappings
        router.enabled = enabled
        router.ledFeedback = ledFeedback
    }

    private func save() {
        var s = MIDISettings()
        s.enabled = enabled; s.ledFeedback = ledFeedback; s.mappings = mappings
        if let d = try? JSONEncoder().encode(s) { UserDefaults.standard.set(d, forKey: Self.defaultsKey) }
    }

    /// Called once by SwitcherEngine after it is set up (main thread).
    func start(engine e: SwitcherEngine) {
        guard engine == nil else { return }
        engine = e
        router.dispatcher = { [weak e] fn, q in
            guard let e else { return "No engine" }
            return APIProcessor.perform(fn, q, e)
        }
        router.currentValue = { [weak e] m in e.flatMap { MIDIControl.currentValue(m, $0) } }
        router.tally = { [weak e] input in
            guard let e, let i = APIProcessor.resolveInput(input, e) else { return .off }
            if i.id == e.programID { return .program }
            if i.id == e.previewID { return .preview }
            return .off
        }
        router.onMessage = { [weak self] m, src in self?.setLast(m.describe(device: src.name)) }
        router.onLearned = { [weak self] map, isNew in
            guard let self else { return }
            self.learning = false
            self.learnDraft = nil
            self.mappings = self.router.mapper.mappings
            self.status = Lf("MIDI 학습됨: %@ → %@", "\(map.deviceName) · \(map.controlDescription)", map.actionDescription)
            _ = isNew
        }
        router.onDispatchError = { [weak self] d, err in
            self?.status = Lf("MIDI 동작 실패: %@ (%@)", d.function, err)
        }
        router.onDevicesChanged = { [weak self] in self?.refreshDevices() }
        let st = router.transport.start(clientName: "HongMix")
        if st != noErr { status = Lf("MIDI를 시작할 수 없음 (%@)", String(st)) }
        refreshDevices()

        // LED tally: program/preview/input-list changes, throttled; @Published fires in willSet, so the
        // frame is computed on the next main-queue turn when the new values are in place.
        Publishers.Merge3(e.$programID.map { _ in () }, e.$previewID.map { _ in () }, e.$inputs.map { _ in () })
            .throttle(for: .milliseconds(40), scheduler: RunLoop.main, latest: true)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in self?.router.updateLEDs() }
            .store(in: &bag)
        // safety net (renumbered inputs, missed edges); only changes are sent
        ledTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.router.updateLEDs() }
        router.updateLEDs(force: true)
    }

    private func scheduleLEDs() {
        guard !ledScheduled else { return }
        ledScheduled = true
        DispatchQueue.main.async { [weak self] in
            self?.ledScheduled = false
            self?.router.updateLEDs()
        }
    }

    private func setLast(_ s: String) {
        pendingLast = s
        guard !lastScheduled else { return }
        lastScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
            guard let self else { return }
            self.lastScheduled = false
            if let p = self.pendingLast, p != self.lastMessage { self.lastMessage = p }
        }
    }

    /// Engine value of a continuous target, normalised 0…1 (same scale as the API range).
    static func currentValue(_ m: MIDIMapping, _ e: SwitcherEngine) -> Double? {
        let f = m.function.lowercased()
        switch f {
        case "setfader": return e.tbar
        case "setvolume": return APIProcessor.resolveInput(m.input, e).map { Double($0.volume) }
        case "setmastervolume": return Double(e.masterVolume)
        case "setheadphonesvolume": return Double(e.headphonesVolume)
        default:
            if f.hasPrefix("setbus"), f.hasSuffix("volume"), f.count == "setbusavolume".count,
               let b = AudioBus.index(String(f.dropFirst(6).prefix(1))), b < e.busSettings.count {
                return Double(e.busSettings[b].volume)
            }
            return nil
        }
    }

    func refreshDevices() {
        let online = router.transport.sources
        let dstNames = router.transport.destinations
        var out: [Device] = online.map { s in
            Device(name: s.name, uniqueID: s.uniqueID, online: true,
                   hasOutput: router.transport.destination(for: s.info) != nil || dstNames.contains { $0.name == s.name },
                   profile: MIDILEDProfile.detect(s.name),
                   mappingCount: mappings.filter { MIDIMapper.deviceMatches($0, s.info, onlineIDs: router.onlineIDs) }.count,
                   suggestedTemplateID: MIDITemplate.suggested(for: s.name)?.id)
        }
        // offline devices still referenced by mappings
        var seen = Set(out.map { $0.name.lowercased() })
        for m in mappings where !m.deviceName.isEmpty && !seen.contains(m.deviceName.lowercased()) {
            seen.insert(m.deviceName.lowercased())
            out.append(Device(name: m.deviceName, uniqueID: m.deviceUniqueID, online: false, hasOutput: false,
                              profile: MIDILEDProfile.detect(m.deviceName),
                              mappingCount: mappings.filter { $0.deviceName.caseInsensitiveCompare(m.deviceName) == .orderedSame }.count,
                              suggestedTemplateID: MIDITemplate.suggested(for: m.deviceName)?.id))
        }
        if out != devices { devices = out }
    }

    // MARK: learn

    /// The next incoming message creates (or re-targets) a mapping for this action.
    func startLearn(_ draft: MIDIActionDraft) {
        router.mapper.learnDraft = draft
        learnDraft = draft
        learning = true
        status = L("MIDI 학습: 컨트롤러의 버튼이나 페이더를 움직이세요")
    }

    func cancelLearn() {
        router.mapper.learnDraft = nil
        learnDraft = nil
        learning = false
        status = ""
    }

    /// API MIDILearn: Value=Function|Input|Value ("" or "cancel" stops learning).
    func apiLearn(_ value: String) -> String? {
        let v = value.trimmingCharacters(in: .whitespaces)
        if v.isEmpty || v.lowercased() == "cancel" || v.lowercased() == "off" { cancelLearn(); return nil }
        let p = v.split(separator: "|", maxSplits: 2, omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespaces) }
        guard let fn = p.first, !fn.isEmpty else { return "Value=Function|Input|Value" }
        startLearn(MIDIActionDraft(function: fn, input: p.count > 1 ? p[1] : "", value: p.count > 2 ? p[2] : ""))
        return nil
    }

    // MARK: editing

    func addMapping(_ m: MIDIMapping) { mappings.append(m) }
    func updateMapping(_ m: MIDIMapping) {
        if let i = mappings.firstIndex(where: { $0.id == m.id }) { mappings[i] = m }
    }
    func removeMapping(id: UUID) { mappings.removeAll { $0.id == id } }
    func removeMappings(for device: Device) {
        mappings.removeAll { $0.deviceName.caseInsensitiveCompare(device.name) == .orderedSame || ($0.deviceUniqueID != 0 && $0.deviceUniqueID == device.uniqueID) }
    }

    /// Applies a built-in template to a device (replacing that device's mappings unless `replace` is false).
    func applyTemplate(id: String, to device: Device, replace: Bool = true) {
        guard let t = MIDITemplate.all.first(where: { $0.id == id }) else { return }
        var list = mappings
        if replace {
            list.removeAll { $0.deviceName.caseInsensitiveCompare(device.name) == .orderedSame || ($0.deviceUniqueID != 0 && $0.deviceUniqueID == device.uniqueID) }
        }
        list += t.mappings(for: device.info)
        router.mapper.resetContinuousState()
        mappings = list
        status = Lf("MIDI 템플릿 적용됨: %@", t.name)
    }

    /// Re-sends every LED (e.g. after the controller was power-cycled on a hub).
    func resendLEDs() { router.updateLEDs(force: true) }
    func rescanDevices() { router.transport.refresh(); refreshDevices() }
}

#endif
