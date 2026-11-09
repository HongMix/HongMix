// Standalone test of the MIDI controller engine (Sources/App/Engine/MIDIControl.swift, compiled with
// -D MIDI_STANDALONE_TEST so the app-only part is left out). Run: bash tests/midi/run.sh
//
// Covers: byte/UMP parsing, mapping match + press semantics, learn, soft takeover, T-bar flip,
// APC mini LED bytes/diffs, and an end-to-end CoreMIDI loop through a virtual source + destination
// (including unplug/replug of the virtual source).
import Foundation
import CoreMIDI

var failures = 0
var checks = 0
func check(_ ok: Bool, _ what: String, file: String = #file, line: Int = #line) {
    checks += 1
    if ok { print("  ok   \(what)") } else { failures += 1; print("  FAIL \(what)  (line \(line))") }
}
func spin(_ seconds: Double, until: () -> Bool = { false }) {
    let end = Date().addingTimeInterval(seconds)
    while Date() < end && !until() { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
}
func dispatches(_ outs: [MIDIMapperOutput]) -> [String] {
    outs.compactMap {
        if case .dispatch(let d) = $0 {
            return d.function + (d.query["input"].map { " I=\($0)" } ?? "") + (d.query["value"].map { " V=\($0)" } ?? "")
        }
        return nil
    }
}

// MARK: parsing
print("== parser")
do {
    var p = MIDIByteParser()
    // note on, running-status note on vel 0 (= off), clock in between, CC, sysex, PC, pitch bend
    let msgs = p.feed([0x90, 60, 100, 0xF8, 60, 0, 0xB1, 7, 64, 0xF0, 0x47, 0x7F, 0xF7, 0xC2, 5, 0xE0, 0x00, 0x40])
    check(msgs.count == 5, "parses 5 channel-voice messages (got \(msgs.count))")
    check(msgs.first == MIDIInMessage(kind: .note, channel: 0, number: 60, value: 100), "note on")
    check(msgs.count > 1 && msgs[1].isNoteOff, "running status note-on vel 0 = note off")
    check(msgs.count > 2 && msgs[2] == MIDIInMessage(kind: .controlChange, channel: 1, number: 7, value: 64), "CC ch 2")
    check(msgs.count > 3 && msgs[3] == MIDIInMessage(kind: .programChange, channel: 2, number: 5, value: 0), "program change")
    check(msgs.count > 4 && msgs[4].kind == .pitchBend && msgs[4].value == 8192, "pitch bend centre = 8192")
    check(MIDIInMessage(kind: .controlChange, channel: 0, number: 0, value: 64).describe(device: "nanoKONTROL2") == "nanoKONTROL2 · CC 0 = 64",
          "describe → \"nanoKONTROL2 · CC 0 = 64\"")
    check(MIDITransport.umpWord([0x96, 0x05, 0x15]) == 0x2096_0515, "UMP MIDI1 word encoding")
}

// MARK: mapper
print("== mapper: press semantics + device matching")
let apcA = MIDISourceInfo(name: "APC MINI", uniqueID: 111)
let apcB = MIDISourceInfo(name: "APC MINI", uniqueID: 222)
do {
    var m = MIDIMapper(mappings: MIDITemplate.all.first { $0.id == "apcmini" }!.mappings(for: apcA))
    let none: (MIDIMapping) -> Double? = { _ in nil }
    var o = m.handle(MIDIInMessage(kind: .note, channel: 0, number: 2, value: 127), from: apcA, onlineIDs: [111], current: none)
    check(dispatches(o) == ["PreviewInput I=3"], "pad note 2 → PreviewInput 3 (\(dispatches(o)))")
    o = m.handle(MIDIInMessage(kind: .note, channel: 0, number: 2, value: 0), from: apcA, onlineIDs: [111], current: none)
    check(o.isEmpty, "note off ignored")
    o = m.handle(MIDIInMessage(kind: .note, channel: 0, number: 9, value: 127), from: apcA, onlineIDs: [111], current: none)
    check(dispatches(o) == ["CutDirect I=2"], "row 2 note 9 → CutDirect 2")
    o = m.handle(MIDIInMessage(kind: .note, channel: 0, number: 82, value: 127), from: apcA, onlineIDs: [111], current: none)
    check(dispatches(o) == ["Cut"], "scene 1 → Cut")
    // same name, other uniqueID while the mapped ID is online → no match; mapped ID offline → name fallback
    o = m.handle(MIDIInMessage(kind: .note, channel: 0, number: 2, value: 127), from: apcB, onlineIDs: [111, 222], current: none)
    check(o.isEmpty, "second identical device (other ID) does not trigger while the mapped one is online")
    o = m.handle(MIDIInMessage(kind: .note, channel: 0, number: 2, value: 127), from: apcB, onlineIDs: [222], current: none)
    check(dispatches(o) == ["PreviewInput I=3"], "re-enumerated device with a new ID matches by name")

    // CC buttons: one press per 0→127 edge, repeats/ releases ignored
    var n = MIDIMapper(mappings: MIDITemplate.all.first { $0.id == "nanokontrol2" }!.mappings(for: MIDISourceInfo(name: "nanoKONTROL2 SLIDER/KNOB", uniqueID: 5)))
    let nano = MIDISourceInfo(name: "nanoKONTROL2 SLIDER/KNOB", uniqueID: 5)
    var got: [String] = []
    for v in [127, 127, 0, 127, 0] {
        got += dispatches(n.handle(MIDIInMessage(kind: .controlChange, channel: 0, number: 41, value: v), from: nano, onlineIDs: [5], current: none))
    }
    check(got == ["Cut", "Cut"], "CC button: press on rising edge only (\(got))")
}

print("== mapper: learn")
do {
    var m = MIDIMapper()
    let src = MIDISourceInfo(name: "X-TOUCH MINI", uniqueID: 77)
    m.learnDraft = MIDIActionDraft(function: "PreviewInput", input: "4")
    var o = m.handle(MIDIInMessage(kind: .note, channel: 10, number: 8, value: 0), from: src, onlineIDs: [77], current: { _ in nil })
    check(o.isEmpty && m.learnDraft != nil, "learn ignores note off")
    o = m.handle(MIDIInMessage(kind: .note, channel: 10, number: 8, value: 127), from: src, onlineIDs: [77], current: { _ in nil })
    if case .learned(let map, let isNew)? = o.first {
        check(isNew && map.kind == .note && map.number == 8 && map.channel == 10 && map.function == "PreviewInput" && map.input == "4" && !map.continuous,
              "learn creates note mapping (\(map.controlDescription) → \(map.actionDescription))")
    } else { check(false, "learn produced a mapping") }
    check(m.learnDraft == nil && m.mappings.count == 1, "learn ends after one message")
    o = m.handle(MIDIInMessage(kind: .note, channel: 10, number: 8, value: 127), from: src, onlineIDs: [77], current: { _ in nil })
    check(dispatches(o) == ["PreviewInput I=4"], "learned mapping dispatches")
    // re-learn same button → updates instead of duplicating
    m.learnDraft = MIDIActionDraft(function: "CutDirect", input: "4")
    o = m.handle(MIDIInMessage(kind: .note, channel: 10, number: 8, value: 90), from: src, onlineIDs: [77], current: { _ in nil })
    if case .learned(_, let isNew)? = o.first { check(!isNew && m.mappings.count == 1 && m.mappings[0].function == "CutDirect", "re-learn updates the mapping") }
    else { check(false, "re-learn produced a mapping") }
    // fader learn → continuous
    m.learnDraft = MIDIActionDraft(function: "SetVolume", input: "2")
    o = m.handle(MIDIInMessage(kind: .controlChange, channel: 10, number: 3, value: 20), from: src, onlineIDs: [77], current: { _ in nil })
    if case .learned(let map, true)? = o.first { check(map.continuous && map.kind == .controlChange && map.number == 3, "fader learn → continuous SetVolume") }
    else { check(false, "fader learn") }
    o = m.handle(MIDIInMessage(kind: .controlChange, channel: 10, number: 3, value: 127), from: src, onlineIDs: [77], current: { _ in nil })
    check(dispatches(o) == ["SetVolume I=2 V=100"], "continuous CC 127 → SetVolume 100 (\(dispatches(o)))")
}

print("== mapper: soft takeover")
do {
    let src = MIDISourceInfo(name: "APC MINI", uniqueID: 111)
    var m = MIDIMapper(mappings: MIDITemplate.all.first { $0.id == "apcmini" }!.mappings(for: src))
    var volume1 = 0.8   // engine value of input 1, 0…1
    let cur: (MIDIMapping) -> Double? = { $0.function == "SetVolume" && $0.input == "1" ? volume1 : nil }
    func move(_ v: Int) -> [String] {
        let o = dispatches(m.handle(MIDIInMessage(kind: .controlChange, channel: 0, number: 48, value: v), from: src, onlineIDs: [111], current: cur))
        for d in o { if let r = d.range(of: "V=") { volume1 = Double(d[r.upperBound...])! / 100 } }
        return o
    }
    check(move(10).isEmpty, "fader far below current (0.08 vs 0.8) ignored")
    check(move(60).isEmpty, "still below → ignored")
    check(move(108) == ["SetVolume I=1 V=85"], "crossing current value picks up (\(volume1))")
    check(move(64) == ["SetVolume I=1 V=50.4"], "after pickup follows the fader")
    volume1 = 0.2   // changed in the UI
    check(move(70).isEmpty, "target changed elsewhere → pickup lost")
    check(move(26) == ["SetVolume I=1 V=20.5"], "near current again → picked up")
}

print("== mapper: T-bar flip")
do {
    let src = MIDISourceInfo(name: "APC MINI", uniqueID: 111)
    var m = MIDIMapper(mappings: MIDITemplate.all.first { $0.id == "apcmini" }!.mappings(for: src))
    var tbar = 0.0
    let cur: (MIDIMapping) -> Double? = { $0.function == "SetFader" ? tbar : nil }
    func move(_ v: Int) -> [String] {
        let o = dispatches(m.handle(MIDIInMessage(kind: .controlChange, channel: 0, number: 56, value: v), from: src, onlineIDs: [111], current: cur))
        for d in o { if let r = d.range(of: "V=") { tbar = Double(d[r.upperBound...])! / 255 } }
        if tbar >= 0.999 { tbar = 0 }   // engine completes the take and resets the T-bar
        return o
    }
    check(move(0) == ["SetFader V=0"], "lever at rest picks up")
    check(move(64) == ["SetFader V=129"], "half way → 129")
    check(move(127) == ["SetFader V=255"], "top → take (255)")
    check(move(100) == ["SetFader V=54"], "after the take the direction flips (127→100 = 54)")
    check(move(0) == ["SetFader V=255"], "bottom completes the next take")
    check(move(127) == ["SetFader V=1", "SetFader V=255"], "fast flick rest→end sends start + take")
}

print("== coalescing")
do {
    let src = MIDISourceInfo(name: "APC MINI", uniqueID: 111)
    let m = MIDIMapper(mappings: MIDITemplate.all.first { $0.id == "apcmini" }!.mappings(for: src))
    let batch: [(MIDIInMessage, MIDISourceInfo)] = [
        (MIDIInMessage(kind: .controlChange, channel: 0, number: 48, value: 10), src),
        (MIDIInMessage(kind: .note, channel: 0, number: 0, value: 127), src),
        (MIDIInMessage(kind: .controlChange, channel: 0, number: 48, value: 20), src),
        (MIDIInMessage(kind: .note, channel: 0, number: 0, value: 0), src),
        (MIDIInMessage(kind: .controlChange, channel: 0, number: 48, value: 30), src),
    ]
    let c = m.coalesce(batch, onlineIDs: [111])
    check(c.map { $0.0.value } == [10, 127, 0, 30], "fader moves merged to first+last, button press/release kept (\(c.map { $0.0.value }))")
}

// MARK: LEDs
print("== LED bytes")
do {
    let src = MIDISourceInfo(name: "APC MINI", uniqueID: 111)
    let maps = MIDITemplate.all.first { $0.id == "apcmini" }!.mappings(for: src)
    var program = "1", preview = "2"
    let tally: (MIDIMapping) -> MIDITally = { $0.input == program ? .program : ($0.input == preview ? .preview : .off) }
    let p = MIDILEDProfile.detect("APC MINI")
    check(p == .apcMiniMk1, "detect APC mini mk1")
    check(MIDILEDProfile.detect("APC mini mk2 Control") == .apcMiniMk2, "detect APC mini mk2")
    check(MIDILEDProfile.detect("nanoKONTROL2 SLIDER/KNOB") == .nanoKontrol2, "detect nanoKONTROL2")
    check(MIDILEDProfile.detect("X-TOUCH MINI") == .xTouchMini, "detect X-Touch Mini")
    let f1 = p.frame(maps, tally: tally)
    check(f1[0x9000] == [0x90, 0, 3], "pad 0 (Preview 1, input 1 on program) red = vel 3")
    check(f1[0x9001] == [0x90, 1, 1], "pad 1 (Preview 2, input 2 on preview) green = vel 1")
    check(f1[0x9008] == [0x90, 8, 3], "pad 8 (Program 1) red")
    check(f1[0x9009] == [0x90, 9, 1], "pad 9 (Program 2) green")
    check(f1[0x9002] == [0x90, 2, 0], "pad 2 off")
    check(f1[0x9010] == nil, "overlay pads have no tally LED")
    let first = MIDILEDProfile.diff(f1, [:])
    check(first.count == 16, "first frame sends all 16 tally pads (\(first.count))")
    check(MIDILEDProfile.diff(f1, f1).isEmpty, "unchanged frame sends nothing")
    program = "2"; preview = "3"
    let f2 = p.frame(maps, tally: tally)
    let d = MIDILEDProfile.diff(f2, f1)
    check(d == [[0x90, 0, 0], [0x90, 1, 3], [0x90, 2, 1], [0x90, 8, 0], [0x90, 9, 3], [0x90, 10, 1]],
          "cut 1→2 with 3 on preview sends only 6 changes: \(d.map { $0.map { String(format: "%02X", $0) }.joined(separator: " ") })")
    // mk2: RGB pads on channel 7 (0x96, 100 %), palette 5 red / 21 green
    let maps2 = MIDITemplate.all.first { $0.id == "apcminimk2" }!.mappings(for: MIDISourceInfo(name: "APC mini mk2 Control", uniqueID: 9))
    let g = MIDILEDProfile.apcMiniMk2.frame(maps2, tally: tally)
    check(g[0x9600] == [0x96, 0, 0] && g[0x9601] == [0x96, 1, 5] && g[0x9602] == [0x96, 2, 21], "mk2 pads: 96 01 05 (red), 96 02 15 (green)")
    // nanoKONTROL2: single LEDs show their own role (S = preview, R = program)
    let nmaps = MIDITemplate.all.first { $0.id == "nanokontrol2" }!.mappings(for: MIDISourceInfo(name: "nanoKONTROL2", uniqueID: 1))
    let nf = MIDILEDProfile.nanoKontrol2.frame(nmaps, tally: tally)
    check(nf[0xB021] == [0xB0, 33, 0] && nf[0xB022] == [0xB0, 34, 127] && nf[0xB041] == [0xB0, 65, 127] && nf[0xB042] == [0xB0, 66, 0],
          "nano: S3 lit (preview 3), R2 lit (program 2)")
    let xmaps = MIDITemplate.all.first { $0.id == "xtouchmini" }!.mappings(for: MIDISourceInfo(name: "X-TOUCH MINI", uniqueID: 2))
    let xf = MIDILEDProfile.xTouchMini.frame(xmaps, tally: tally)
    check(xf[0x9002] == [0x90, 2, 1] && xf[0x9009] == [0x90, 9, 1] && xf[0x9008] == [0x90, 8, 0], "X-Touch: upper LED 3 (preview 3) + lower LED 2 (program 2)")
}

// MARK: end-to-end through CoreMIDI virtual endpoints
print("== CoreMIDI loopback (virtual source + destination)")
do {
    var client = MIDIClientRef()
    var st = MIDIClientCreateWithBlock("HongMix MIDI test" as CFString, &client) { _ in }
    check(st == noErr, "test client")
    var vsrc = MIDIEndpointRef()
    st = MIDISourceCreateWithProtocol(client, "APC MINI" as CFString, ._1_0, &vsrc)
    check(st == noErr, "virtual source \"APC MINI\"")
    let ledLock = NSLock()
    var ledBytes: [[UInt8]] = []
    var vdst = MIDIEndpointRef()
    st = MIDIDestinationCreateWithProtocol(client, "APC MINI" as CFString, ._1_0, &vdst) { list, _ in
        MIDITransport.decode(list) { m in ledLock.lock(); ledBytes.append(m.bytes); ledLock.unlock() }
    }
    check(st == noErr, "virtual destination \"APC MINI\"")
    func takeLED() -> [[UInt8]] { ledLock.lock(); defer { ledBytes.removeAll(); ledLock.unlock() }; return ledBytes }

    func sendFromDevice(_ msgs: [[UInt8]]) {
        let size = 1024
        let raw = UnsafeMutableRawPointer.allocate(byteCount: size, alignment: 8)
        defer { raw.deallocate() }
        let list = raw.bindMemory(to: MIDIEventList.self, capacity: 1)
        var pkt = MIDIEventListInit(list, ._1_0)
        for m in msgs { var w = MIDITransport.umpWord(m); pkt = MIDIEventListAdd(list, size, pkt, 0, 1, &w) }
        MIDIReceivedEventList(vsrc, list)
    }

    let router = MIDIRouter()
    var calls: [String] = []
    var program = "1", preview = "2"
    var tbar = 0.0
    router.dispatcher = { fn, q in
        calls.append(fn + (q["input"].map { " I=\($0)" } ?? "") + (q["value"].map { " V=\($0)" } ?? ""))
        if fn == "PreviewInput" { preview = q["input"] ?? "" }
        if fn == "CutDirect" { program = q["input"] ?? "" }
        if fn == "SetFader" { tbar = Double(q["value"] ?? "0")! / 255; if tbar >= 0.999 { tbar = 0 } }
        return nil
    }
    router.currentValue = { m in m.function == "SetFader" ? tbar : nil }
    router.tally = { $0 == program ? .program : ($0 == preview ? .preview : .off) }
    var seen: [String] = []
    router.onMessage = { m, s in seen.append(m.describe(device: s.name)) }
    var learned: MIDIMapping?
    router.onLearned = { m, _ in learned = m }

    st = router.transport.start(clientName: "HongMix-test")
    check(st == noErr, "transport started")
    spin(2) { router.transport.sources.contains { $0.uniqueID != 0 && $0.name == "APC MINI" } }
    guard let dev = router.transport.sources.first(where: { $0.name == "APC MINI" }) else {
        check(false, "transport sees the virtual source"); exit(1)
    }
    check(true, "transport sees the virtual source (uniqueID \(dev.uniqueID))")
    check(router.transport.destination(for: dev.info) != nil, "source paired with destination by name")
    router.mapper.mappings = MIDITemplate.all.first { $0.id == "apcmini" }!.mappings(for: dev.info)

    // LED: initial frame (all mapped LEDs explicitly set)
    router.updateLEDs(force: true)
    spin(1) { ledLock.lock(); defer { ledLock.unlock() }; return ledBytes.count >= 16 }
    var leds = takeLED()
    check(leds.contains([0x90, 0, 3]) && leds.contains([0x90, 1, 1]) && leds.contains([0x90, 8, 3]) && leds.contains([0x90, 9, 1]),
          "initial LED frame received on the device (\(leds.count) msgs, pad0 red, pad1 green)")
    check(leds.count == 16 && !leds.contains { $0[1] >= 16 }, "only the 16 tally pads are addressed (no stray LED messages)")

    // pad press → PreviewInput 3 → tally change → only changed LEDs
    sendFromDevice([[0x90, 2, 127], [0x80, 2, 0]])
    spin(1) { !calls.isEmpty }
    check(calls == ["PreviewInput I=3"], "pad press dispatched through CoreMIDI (\(calls))")
    check(seen.first == "APC MINI · Note 2 = 127", "lastMessage text: \(seen.first ?? "-")")
    router.updateLEDs()
    spin(0.5) { ledLock.lock(); defer { ledLock.unlock() }; return ledBytes.count >= 4 }
    leds = takeLED().map { $0[0] == 0x80 ? [0x90, $0[1], 0] : $0 }   // note-off with vel 0 == note-on vel 0
    check(Set(leds.map { $0.map(String.init).joined(separator: ",") }) ==
          Set([[0x90, 1, 0], [0x90, 2, 1], [0x90, 9, 0], [0x90, 10, 1]].map { $0.map(String.init).joined(separator: ",") }),
          "LED diff: only pads 1,2,9,10 changed (\(leds))")

    // fader 9 → T-bar, burst coalesced
    calls.removeAll()
    sendFromDevice([[0xB0, 56, 0], [0xB0, 56, 20], [0xB0, 56, 40], [0xB0, 56, 64]])
    spin(1) { !calls.isEmpty }
    spin(0.2)
    check(calls == ["SetFader V=0", "SetFader V=129"], "T-bar burst coalesced to first+last (\(calls))")

    // learn through the transport
    router.mapper.learnDraft = MIDIActionDraft(function: "OverlayInput2", input: "5")
    sendFromDevice([[0x90, 40, 127]])
    spin(1) { learned != nil }
    check(learned?.number == 40 && learned?.deviceUniqueID == dev.uniqueID && learned?.function == "OverlayInput2", "learn via CoreMIDI")

    // hot-plug: remove + re-create the virtual source → transport reconnects automatically
    MIDIEndpointDispose(vsrc)
    spin(2) { !router.transport.sources.contains { $0.name == "APC MINI" } }
    check(!router.transport.sources.contains { $0.name == "APC MINI" }, "unplug noticed")
    st = MIDISourceCreateWithProtocol(client, "APC MINI" as CFString, ._1_0, &vsrc)
    spin(2) { router.transport.sources.contains { $0.name == "APC MINI" } }
    check(router.transport.sources.contains { $0.name == "APC MINI" }, "replug noticed")
    calls.removeAll()
    sendFromDevice([[0x90, 11, 127]])
    spin(1) { !calls.isEmpty }
    check(calls == ["CutDirect I=4"], "messages flow again after replug, matched by name (new ID) (\(calls))")
    MIDIEndpointDispose(vsrc)
    MIDIEndpointDispose(vdst)
    MIDIClientDispose(client)
}

print("\n\(checks - failures)/\(checks) checks passed")
exit(failures == 0 ? 0 : 1)
