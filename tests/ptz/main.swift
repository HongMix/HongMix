// Standalone test of the PTZ engine (VISCA encoder, Sony framing, transports, throttle, dead-man) against
// tests/ptz/fake_visca_camera.py. Built together with Sources/App/Engine/PTZ.swift with -D PTZ_STANDALONE.
// Run: bash tests/ptz/run.sh
import Foundation

// Localisation stubs (the app's L/Lf live in Localization.swift).
func L(_ s: String) -> String { s }
func Lf(_ t: String, _ args: String...) -> String {
    var out = t
    for a in args { if let r = out.range(of: "%@") { out.replaceSubrange(r, with: a) } }
    return out
}

var failures = 0
var passes = 0
func check(_ ok: Bool, _ what: String, _ detail: @autoclosure () -> String = "") {
    if ok { passes += 1; print("PASS  \(what)") } else { failures += 1; print("FAIL  \(what) \(detail())") }
}
func hex(_ b: [UInt8]) -> String { b.map { String(format: "%02x", $0) }.joined(separator: " ") }
func now() -> Double { Double(DispatchTime.now().uptimeNanoseconds) / 1e9 }
func wait(_ timeout: Double, _ cond: () -> Bool) -> Bool {
    let end = now() + timeout
    while now() < end { if cond() { return true }; usleep(5_000) }
    return cond()
}

// MARK: fake camera

let logPath = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : NSTemporaryDirectory() + "ptz_fake.log"
let script = CommandLine.arguments.count > 2 ? CommandLine.arguments[2] : "tests/ptz/fake_visca_camera.py"
try? FileManager.default.removeItem(atPath: logPath)
let cam = Process()
cam.executableURL = URL(fileURLWithPath: "/usr/bin/env")
cam.arguments = ["python3", "-u", script, logPath]
try cam.run()
defer { cam.terminate() }

func logLines() -> [(String, String)] {
    guard let s = try? String(contentsOfFile: logPath, encoding: .utf8) else { return [] }
    return s.split(separator: "\n").map { l in
        let p = l.split(separator: " ", maxSplits: 1).map(String.init)
        return (p[0], p.count > 1 ? p[1] : "")
    }
}
var logMark = 0
/// Waits for `expected` (proto, hex) to be the next new matching-proto lines after the mark.
func expectNext(_ proto: String, _ expected: [String], _ what: String, timeout: Double = 2) {
    var got: [String] = []
    _ = wait(timeout) {
        got = logLines().dropFirst(logMark).filter { $0.0 == proto }.map { $0.1 }
        return got.count >= expected.count
    }
    let ok = Array(got.prefix(expected.count)) == expected
    check(ok, what, "\n      expected \(expected)\n      got      \(got)")
    if ok {   // advance the mark past the consumed lines
        var seen = 0, idx = logMark
        let all = logLines()
        while idx < all.count && seen < expected.count { if all[idx].0 == proto { seen += 1 }; idx += 1 }
        logMark = idx
    }
}
_ = wait(3) { logLines().contains { $0.0 == "READY" } }
check(logLines().contains { $0.0 == "READY" }, "fake camera started")

// MARK: 1. pure encoder / parser

check(hex(VISCA.panTilt(address: 1, pan: 24, tilt: 0)) == "81 01 06 01 18 01 02 03 ff", "encode pan right max")
check(hex(VISCA.panTilt(address: 1, pan: -12, tilt: -20)) == "81 01 06 01 0c 14 01 02 ff", "encode pan left/tilt down")
check(hex(VISCA.stop(address: 1)) == "81 01 06 01 01 01 03 03 ff", "encode stop")
check(hex(VISCA.home(address: 3)) == "83 01 06 04 ff", "encode home addr 3")
check(hex(VISCA.zoom(address: 1, speed: 8)) == "81 01 04 07 27 ff", "encode zoom tele p7")
check(hex(VISCA.zoom(address: 1, speed: -1)) == "81 01 04 07 30 ff", "encode zoom wide p0")
check(hex(VISCA.zoom(address: 1, speed: 0)) == "81 01 04 07 00 ff", "encode zoom stop")
check(hex(VISCA.focus(address: 1, speed: 3)) == "81 01 04 08 22 ff", "encode focus far p2")
check(hex(VISCA.focus(address: 1, speed: -3)) == "81 01 04 08 32 ff", "encode focus near p2")
check(hex(VISCA.focusAuto(address: 1)) == "81 01 04 38 02 ff", "encode focus auto")
check(hex(VISCA.focusManual(address: 1)) == "81 01 04 38 03 ff", "encode focus manual")
check(hex(VISCA.presetRecall(address: 1, preset: 2)) == "81 01 04 3f 02 02 ff", "encode preset recall 2")
check(hex(VISCA.presetStore(address: 1, preset: 3)) == "81 01 04 3f 01 03 ff", "encode preset store 3")
check(hex(VISCA.absolutePanTilt(address: 1, pan: -1, tilt: 0x123, panSpeed: 0x10, tiltSpeed: 0x10))
      == "81 01 06 02 10 10 0f 0f 0f 0f 00 01 02 03 ff", "encode absolute pan/tilt")
check(hex(VISCAIPFrame.resetSequence()) == "02 00 00 01 00 00 00 00 01", "Sony reset sequence frame")
check(hex(VISCAIPFrame.wrap(VISCAIPFrame.command, [0x81, 0x01, 0x06, 0x04, 0xFF], seq: 0x01020304))
      == "01 00 00 05 01 02 03 04 81 01 06 04 ff", "Sony command header")
check(VISCAReply.parse([0x90, 0x41, 0xFF]) == .ack(socket: 1), "parse ACK")
check(VISCAReply.parse([0x90, 0x52, 0xFF]) == .completion(socket: 2, data: []), "parse completion")
check(VISCAReply.parse([0x90, 0x60, 0x02, 0xFF]) == .error(socket: 0, code: 2), "parse syntax error")
check(VISCAReply.parse([0x90, 0x61, 0x41, 0xFF]) == .error(socket: 1, code: 0x41), "parse not executable")
var sbuf: [UInt8] = [0x90, 0x41, 0xFF, 0x90, 0x51, 0xFF, 0x90]
let parts = VISCAReply.split(&sbuf)
check(parts.count == 2 && sbuf == [0x90], "split stream keeps partial tail")
check(PTZVelocity(pan: 1, tilt: 0, scale: 0.5) == PTZVelocity(pan: 12, tilt: 0), "speed slider scales joystick")
check(PTZVelocity(pan: 0.02, tilt: -0.01, scale: 1) == .zero, "joystick dead zone")
check(PTZVelocity(pan: 0.06, tilt: 0.06, scale: 0.05) == PTZVelocity(pan: 1, tilt: 1), "minimum speed 1")
var zc = PTZCameraConfig(); zc.presetZeroBased = true
check(zc.wireNumber(1) == 0 && PTZCameraConfig().wireNumber(1) == 1, "preset numbering (Sony zero-based vs 1-based)")
let old = try JSONDecoder().decode(PTZCameraConfig.self, from: Data(#"{"transport":"viscaTCP","host":"10.0.0.9"}"#.utf8))
check(old.port == 5678 && old.address == 1 && old.presets.isEmpty && !old.recallOnPreview, "tolerant config decoding")
var cfg = PTZCameraConfig(transport: .viscaIP, host: "1.2.3.4")
cfg.presets = [PTZPreset(number: 1, name: "Wide"), PTZPreset(number: 2, name: "Host")]
cfg.recallOnPreview = true
let rt = try JSONDecoder().decode(PTZCameraConfig.self, from: JSONEncoder().encode(cfg))
check(rt == cfg && rt.nextPresetNumber == 3 && rt.effectivePreviewPreset == 1, "config round trip / next preset / preview preset")

// MARK: 2. Sony VISCA over IP (UDP 52381)

final class Box<T> { var v: T; init(_ v: T) { self.v = v } }
let states = Box<[PTZLinkState]>([])
let camErr = Box<[String?]>([])
let repliesSeen = Box<[VISCAReply]>([])
let lock = NSLock()
func hook(_ c: VISCAClient) {
    c.onState = { s in lock.lock(); states.v.append(s); lock.unlock() }
    c.onCameraError = { e in lock.lock(); camErr.v.append(e); lock.unlock() }
    c.onReply = { r in lock.lock(); repliesSeen.v.append(r); lock.unlock() }
}
func lastState() -> PTZLinkState? { lock.lock(); defer { lock.unlock() }; return states.v.last }

let sony = VISCAClient(host: "127.0.0.1", port: 52381, framing: .sonyIP, address: 1)
hook(sony)
sony.start()
expectNext("SONY", ["02 00 00 01 00 00 00 00 01"], "Sony: RESET sent on connect")
check(wait(2) { lastState() == .connected }, "Sony: connected after camera reply", "\(states.v)")

sony.send(.presetRecall(2))
expectNext("SONY", ["01 00 00 07 00 00 00 01 81 01 04 3f 02 02 ff"], "Sony: preset recall 2 (seq 1)")
sony.send(.presetStore(3))
expectNext("SONY", ["01 00 00 07 00 00 00 02 81 01 04 3f 01 03 ff"], "Sony: preset store 3 (seq 2)")
sony.send(.zoom(4)); sony.send(.zoom(0)); sony.send(.zoom(-8))
expectNext("SONY", ["01 00 00 06 00 00 00 03 81 01 04 07 23 ff",
                    "01 00 00 06 00 00 00 04 81 01 04 07 00 ff",
                    "01 00 00 06 00 00 00 05 81 01 04 07 37 ff"], "Sony: zoom tele 4 / stop / wide 8")
sony.send(.home)
expectNext("SONY", ["01 00 00 05 00 00 00 06 81 01 06 04 ff"], "Sony: home")
sony.send(.focusAuto); sony.send(.focusManual); sony.send(.focus(2)); sony.send(.focus(-1)); sony.send(.focus(0))
expectNext("SONY", ["01 00 00 06 00 00 00 07 81 01 04 38 02 ff",
                    "01 00 00 06 00 00 00 08 81 01 04 38 03 ff",
                    "01 00 00 06 00 00 00 09 81 01 04 08 21 ff",
                    "01 00 00 06 00 00 00 0a 81 01 04 08 30 ff",
                    "01 00 00 06 00 00 00 0b 81 01 04 08 00 ff"], "Sony: focus auto / manual / far / near / stop")
sony.sendRaw(VISCA.powerInquiry(address: 1))
expectNext("SONY", ["01 10 00 05 00 00 00 0c 81 09 04 00 ff"], "Sony: inquiry uses payload type 0x0110")
_ = wait(1) { lock.lock(); defer { lock.unlock() }; return repliesSeen.v.contains(.completion(socket: 0, data: [0x02])) }
lock.lock()
let acks = repliesSeen.v.filter { if case .ack = $0 { return true }; return false }.count
let dones = repliesSeen.v.filter { if case .completion = $0 { return true }; return false }.count
lock.unlock()
check(acks >= 11 && dones >= 12, "Sony: ACK + completion replies parsed", "acks \(acks) completions \(dones)")

sony.send(.presetRecall(0x7E))   // fake camera answers 90 61 41 FF
expectNext("SONY", ["01 00 00 07 00 00 00 0d 81 01 04 3f 02 7e ff"], "Sony: preset 0x7E sent")
check(wait(1) { lock.lock(); defer { lock.unlock() }; return camErr.v.last == .some("VISCA 오류: 지금 실행할 수 없는 명령") },
      "Sony: camera error 90 61 41 FF surfaced", "\(camErr.v)")
sony.send(.home)
check(wait(1) { lock.lock(); defer { lock.unlock() }; return camErr.v.last == .some(nil) }, "Sony: error cleared by next completion")
expectNext("SONY", ["01 00 00 05 00 00 00 0e 81 01 06 04 ff"], "Sony: home after error")

// MARK: 3. Joystick driver: throttle, latest-wins, repeats, dead-man (on the Sony client)

let emits = Box<[(Double, PTZVelocity)]>([])
let joy = PTZAxisDriver<PTZVelocity>(zero: .zero) { v in
    lock.lock(); emits.v.append((now(), v)); lock.unlock()
    sony.send(.panTilt(pan: v.pan, tilt: v.tilt))
}
func emitted() -> [(Double, PTZVelocity)] { lock.lock(); defer { lock.unlock() }; return emits.v }

joy.set(PTZVelocity(pan: 1, tilt: 0, scale: 1))
expectNext("SONY", ["01 00 00 09 00 00 00 0f 81 01 06 01 18 01 02 03 ff"], "joystick: full right → 81 01 06 01 18 01 02 03 FF")

// 40 distinct updates 5 ms apart → throttled to ≤ 20/s
usleep(60_000)
let t0 = now()
var lastV = PTZVelocity.zero
for i in 0..<40 {
    lastV = PTZVelocity(pan: 0.2 + Double(i) * 0.02, tilt: 0.5, scale: 1)
    joy.set(lastV)
    usleep(5_000)
}
let tEnd = now()
usleep(80_000)
let burst = emitted().filter { $0.0 >= t0 }
let gaps = zip(burst.dropFirst(), burst).map { $0.0 - $1.0 }
let rate = Double(burst.count) / (tEnd - t0 + 0.05)
print(String(format: "      burst: 40 updates in %.0f ms → %d sent, min gap %.1f ms, rate %.1f msg/s",
             (tEnd - t0) * 1000, burst.count, (gaps.min() ?? 0) * 1000, rate))
check(burst.count >= 3 && burst.count <= 7, "throttle: 40 updates at 5 ms intervals send 3…7 messages", "\(burst.count)")
check((gaps.min() ?? 1) >= 0.045, "throttle: ≥ 50 ms between messages (max ~20/s)")
check(burst.last?.1 == lastV, "throttle: latest value wins", "\(String(describing: burst.last?.1)) vs \(lastV)")
let lastBurstHex = hex(VISCA.panTilt(address: 1, pan: lastV.pan, tilt: lastV.tilt))
_ = wait(1) { logLines().dropFirst(logMark).filter { $0.0 == "SONY" }.count >= burst.count }
let sonyNew = logLines().dropFirst(logMark).filter { $0.0 == "SONY" }.map { $0.1 }
check(sonyNew.count == burst.count && sonyNew.last?.hasSuffix(lastBurstHex) == true,
      "throttle: camera received exactly the throttled messages", "\(sonyNew.count) vs \(burst.count), last \(sonyNew.last ?? "-")")
logMark = logLines().count

// repeats are not re-sent
let before = emitted().count
for _ in 0..<10 { joy.set(lastV); usleep(10_000) }
check(emitted().count == before, "repeated identical value is not re-sent")

// dead-man: no updates for 500 ms → stop
let tLast = now()
joy.set(lastV)
check(wait(1.2) { emitted().last?.1 == .zero }, "dead-man: stop sent without any UI event")
let dmDelay = (emitted().last!.0 - tLast) * 1000
print(String(format: "      dead-man stop after %.0f ms", dmDelay))
check(dmDelay >= 480 && dmDelay <= 650, "dead-man fires ~500 ms after the last update", String(format: "%.0f ms", dmDelay))
expectNext("SONY", ["01 00 00 09 00 00 00 \(String(format: "%02x", 0x0f + burst.count + 1)) 81 01 06 01 01 01 03 03 ff"],
           "dead-man: camera received stop 81 01 06 01 01 01 03 03 FF")

// heartbeat keeps it moving; explicit stop is immediate
let hb = PTZVelocity(pan: -0.5, tilt: -1, scale: 1)
let tHB = now()
joy.set(hb)
for _ in 0..<6 { usleep(200_000); joy.set(hb) }   // 1.2 s held still with 200 ms keep-alives
let hbEmits = emitted().filter { $0.0 >= tHB }
check(hbEmits.count == 1 && hbEmits[0].1 == PTZVelocity(pan: -12, tilt: -20), "heartbeat: held joystick sends once, no dead-man stop",
      "\(hbEmits.map { $0.1 })")
let tStop = now()
joy.stop()
check(wait(0.2) { emitted().last?.1 == .zero }, "explicit stop sent")
let stopLatency = (emitted().last!.0 - tStop) * 1000
check(stopLatency < 20, "explicit stop bypasses throttle", String(format: "%.1f ms", stopLatency))
let seqHB = 0x0f + burst.count + 2
expectNext("SONY", ["01 00 00 09 00 00 00 \(String(format: "%02x", seqHB)) 81 01 06 01 0c 14 01 02 ff",
                    "01 00 00 09 00 00 00 \(String(format: "%02x", seqHB + 1)) 81 01 06 01 01 01 03 03 ff"],
           "camera received left-down 0C/14 then stop")
sony.stop()

// MARK: 4. Raw VISCA over TCP (5678) incl. reconnect

states.v.removeAll()
let tcpC = VISCAClient(host: "127.0.0.1", port: 5678, framing: .rawTCP, address: 1)
hook(tcpC)
tcpC.start()
check(wait(3) { lastState() == .connected }, "TCP: connected", "\(states.v)")
tcpC.send(.presetRecall(1))
tcpC.send(.panTilt(pan: -24, tilt: 20))
tcpC.send(.stop)
expectNext("TCP", ["81 01 04 3f 02 01 ff", "81 01 06 01 18 14 01 01 ff", "81 01 06 01 01 01 03 03 ff"],
           "TCP: raw preset recall 1 / up-left max / stop")
tcpC.send(.presetRecall(0x7D))   // fake camera drops the connection after this
check(wait(3) { logLines().contains { $0.0 == "TCPDROP" } }, "TCP: camera dropped the connection")
check(wait(3) { lock.lock(); defer { lock.unlock() }; return states.v.contains { if case .error = $0 { return true }; return false } },
      "TCP: drop reported as error", "\(states.v)")
check(wait(6) { lastState() == .connected && logLines().filter { $0.0 == "TCPCONNECT" }.count >= 2 }, "TCP: reconnected", "\(states.v)")
print("      TCP states: \(states.v.map { $0.text })")
logMark = logLines().count
tcpC.send(.home)
expectNext("TCP", ["81 01 06 04 ff"], "TCP: command after reconnect")
tcpC.stop()

// MARK: 5. Raw VISCA over UDP (1259), camera address 2

states.v.removeAll()
let rawU = VISCAClient(host: "127.0.0.1", port: 1259, framing: .rawUDP, address: 2)
hook(rawU)
rawU.start()
rawU.send(.presetRecall(5))     // non-motion: queued until the socket is ready
expectNext("RAWUDP", ["82 01 04 3f 02 05 ff"], "raw UDP: preset recall 5 at address 2")
check(wait(2) { lastState() == .connected }, "raw UDP: connected after reply")
rawU.stop()

// MARK: 6. Unreachable camera

states.v.removeAll()
let dead = VISCAClient(host: "127.0.0.1", port: 5699, framing: .rawTCP)
hook(dead)
dead.start()
check(wait(4) { if case .error = lastState() { return true }; return false }, "TCP: unreachable camera → error", "\(states.v)")
print("      unreachable status: \(lastState()?.text ?? "-")")
dead.stop()
let deadU = VISCAClient(host: "127.0.0.1", port: 52399, framing: .sonyIP)
deadU.replyTimeout = 0.5
states.v.removeAll()
hook(deadU)
deadU.start()
usleep(100_000)
deadU.send(.home)
check(wait(3) { if case .error = lastState() { return true }; return false }, "UDP: silent camera → error", "\(states.v)")
print("      silent UDP status: \(lastState()?.text ?? "-")")
deadU.stop()

print("\nfake camera log: \(logPath)")
print("RESULT: \(passes) passed, \(failures) failed")
cam.terminate()
exit(failures == 0 ? 0 : 1)
