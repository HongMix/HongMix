import Foundation
import Network
#if !PTZ_STANDALONE
import Combine
#endif

// PTZ camera control engine (no UI here).
//
// Layers:
//   1. Config (`PTZCameraConfig`, stored per input in `InputConfig.ptz`).
//   2. VISCA encoder / reply parser / Sony VISCA-over-IP framing (`VISCA`, `VISCAReply`, `VISCAIPFrame`).
//   3. Transports (`VISCAClient`: Sony UDP 52381, raw TCP 5678, raw UDP 1259; `NDIPTZBackend`: NDI SDK PTZ).
//   4. `PTZAxisDriver`: throttled (max ~20 msgs/s, send-on-change) continuous-move driver with a 500 ms
//      dead-man stop, used by the joystick and the zoom rocker.
//   5. App glue (`PTZController` per input, `PTZManager.shared`, vMix API functions, Preview hook).
//
// Layers 1–4 only need Foundation + Network: compile this file with `-D PTZ_STANDALONE` (plus a file that
// defines `L`) to test them outside the app — see tests/ptz/.

// MARK: - Configuration

enum PTZTransport: String, Codable, CaseIterable, Identifiable {
    case viscaIP     // Sony VISCA over IP framing, UDP 52381 (Sony, Panasonic AW VISCA, BirdDog …)
    case viscaTCP    // raw VISCA over TCP (PTZOptics and many OEM cameras, port 5678)
    case viscaUDP    // raw VISCA over UDP (port 1259)
    case ndi         // NDI PTZ through the input's NDI receiver

    var id: String { rawValue }

    var defaultPort: Int {
        switch self {
        case .viscaIP: return 52381
        case .viscaTCP: return 5678
        case .viscaUDP: return 1259
        case .ndi: return 0
        }
    }

    var label: String {
        switch self {
        case .viscaIP: return L("VISCA over IP (Sony, UDP 52381)")
        case .viscaTCP: return L("VISCA TCP (PTZOptics, 5678)")
        case .viscaUDP: return L("VISCA UDP (1259)")
        case .ndi: return "NDI PTZ"
        }
    }
}

struct PTZPreset: Codable, Equatable, Identifiable {
    /// Preset number as the user sees it (1, 2, 3 …). Sent as VISCA `pp` / NDI preset_no, see `wireNumber`.
    var number: Int
    var name: String
    var id: Int { number }
}

struct PTZCameraConfig: Codable, Equatable {
    var transport: PTZTransport = .viscaIP
    var host: String = ""
    var port: Int = PTZTransport.viscaIP.defaultPort
    /// VISCA camera address 1…7 (header byte 0x80 + address).
    var address: Int = 1
    /// "Speed" slider 0…1: scales the joystick and the vMix PTZMove…/PTZFocus… default speed.
    var panTiltSpeed: Double = 0.5
    /// Zoom speed slider 0…1 (vMix PTZZoomIn/Out default speed).
    var zoomSpeed: Double = 0.5
    /// NDI preset recall speed 0…1 (VISCA recalls at the camera's own preset speed).
    var presetSpeed: Double = 1
    /// true: preset 1 is sent as VISCA pp 00 / NDI 0 (Sony numbering). false: preset N → pp N (PTZOptics …).
    var presetZeroBased: Bool = false
    var presets: [PTZPreset] = []
    /// "Move to preset when put in Preview".
    var recallOnPreview: Bool = false
    /// Preset recalled on Preview (and by PTZMoveToVirtualInputPosition); nil = first preset in the list.
    var previewPreset: Int? = nil

    init() {}

    init(transport: PTZTransport, host: String = "", port: Int? = nil) {
        self.transport = transport
        self.host = host
        self.port = port ?? transport.defaultPort
    }

    func wireNumber(_ preset: Int) -> Int { max(0, min(254, presetZeroBased ? preset - 1 : preset)) }

    var effectivePreviewPreset: Int? { previewPreset ?? presets.first?.number }

    /// Next free preset number for "+ Save".
    var nextPresetNumber: Int {
        var n = 1
        let used = Set(presets.map(\.number))
        while used.contains(n) { n += 1 }
        return n
    }

    // Tolerant decoding: newer keys may be missing in older project files.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = PTZCameraConfig()
        func v<T: Decodable>(_ k: CodingKeys, _ f: T) -> T { ((try? c.decodeIfPresent(T.self, forKey: k)) ?? nil) ?? f }
        transport = v(.transport, d.transport)
        host = v(.host, d.host)
        port = v(.port, transport.defaultPort)
        address = v(.address, d.address)
        panTiltSpeed = v(.panTiltSpeed, d.panTiltSpeed)
        zoomSpeed = v(.zoomSpeed, d.zoomSpeed)
        presetSpeed = v(.presetSpeed, d.presetSpeed)
        presetZeroBased = v(.presetZeroBased, d.presetZeroBased)
        presets = v(.presets, d.presets)
        recallOnPreview = v(.recallOnPreview, d.recallOnPreview)
        previewPreset = v(.previewPreset, d.previewPreset)
    }
}

// MARK: - Commands

/// Transport-independent PTZ command. Speeds are in VISCA steps so every backend gets the same quantisation.
enum PTZCommand: Equatable {
    /// pan: -24…24 (+ = right), tilt: -20…20 (+ = up); 0 stops that axis. (0, 0) = stop.
    case panTilt(pan: Int, tilt: Int)
    case home
    /// -8…8, + = tele (zoom in), - = wide, 0 = stop
    case zoom(Int)
    case focusAuto
    case focusManual
    /// -8…8, + = far, - = near, 0 = stop
    case focus(Int)
    /// wire preset number (already mapped by `PTZCameraConfig.wireNumber`)
    case presetRecall(Int)
    case presetStore(Int)

    static let stop = PTZCommand.panTilt(pan: 0, tilt: 0)

    /// Continuous-motion commands are stale once superseded, so they are not queued while disconnected.
    var isMotion: Bool {
        switch self {
        case .panTilt, .zoom, .focus: return true
        default: return false
        }
    }

    func visca(address: Int) -> [UInt8] {
        switch self {
        case let .panTilt(p, t): return VISCA.panTilt(address: address, pan: p, tilt: t)
        case .home: return VISCA.home(address: address)
        case let .zoom(s): return VISCA.zoom(address: address, speed: s)
        case .focusAuto: return VISCA.focusAuto(address: address)
        case .focusManual: return VISCA.focusManual(address: address)
        case let .focus(s): return VISCA.focus(address: address, speed: s)
        case let .presetRecall(n): return VISCA.presetRecall(address: address, preset: n)
        case let .presetStore(n): return VISCA.presetStore(address: address, preset: n)
        }
    }
}

// MARK: - VISCA encoder

enum VISCA {
    static let maxPanSpeed = 0x18
    static let maxTiltSpeed = 0x14
    /// Zoom / focus variable speed steps 1…8 (VISCA p = step - 1 = 0…7).
    static let maxZoomSpeed = 8
    static let maxFocusSpeed = 8

    static func header(_ address: Int) -> UInt8 { UInt8(0x80 | (max(1, min(7, address)) & 0x07)) }

    /// Pan-tiltDrive: 8x 01 06 01 VV WW 0p 0t FF (p: 01 left, 02 right, 03 stop; t: 01 up, 02 down, 03 stop).
    static func panTilt(address: Int, pan: Int, tilt: Int) -> [UInt8] {
        let vv = UInt8(max(1, min(maxPanSpeed, abs(pan))))
        let ww = UInt8(max(1, min(maxTiltSpeed, abs(tilt))))
        let pd: UInt8 = pan < 0 ? 0x01 : (pan > 0 ? 0x02 : 0x03)
        let td: UInt8 = tilt > 0 ? 0x01 : (tilt < 0 ? 0x02 : 0x03)
        return [header(address), 0x01, 0x06, 0x01, vv, ww, pd, td, 0xFF]
    }

    static func stop(address: Int) -> [UInt8] { panTilt(address: address, pan: 0, tilt: 0) }

    /// Pan-tiltDrive Home: 8x 01 06 04 FF
    static func home(address: Int) -> [UInt8] { [header(address), 0x01, 0x06, 0x04, 0xFF] }

    /// Pan-tiltDrive AbsolutePosition: 8x 01 06 02 VV WW 0Y 0Y 0Y 0Y 0Z 0Z 0Z 0Z FF (16-bit signed, camera units).
    static func absolutePanTilt(address: Int, pan: Int, tilt: Int, panSpeed: Int = maxPanSpeed, tiltSpeed: Int = maxTiltSpeed) -> [UInt8] {
        func nibbles(_ v: Int) -> [UInt8] {
            let u = UInt16(bitPattern: Int16(clamping: v))
            return [UInt8((u >> 12) & 0xF), UInt8((u >> 8) & 0xF), UInt8((u >> 4) & 0xF), UInt8(u & 0xF)]
        }
        return [header(address), 0x01, 0x06, 0x02,
                UInt8(max(1, min(maxPanSpeed, panSpeed))), UInt8(max(1, min(maxTiltSpeed, tiltSpeed)))]
            + nibbles(pan) + nibbles(tilt) + [0xFF]
    }

    /// CAM_Zoom: stop 8x 01 04 07 00 FF, tele 8x 01 04 07 2p FF, wide 8x 01 04 07 3p FF (p = |speed| - 1 = 0…7)
    static func zoom(address: Int, speed: Int) -> [UInt8] {
        let p = UInt8(max(0, min(maxZoomSpeed, abs(speed) - 1)))
        let b: UInt8 = speed == 0 ? 0x00 : (speed > 0 ? 0x20 | p : 0x30 | p)
        return [header(address), 0x01, 0x04, 0x07, b, 0xFF]
    }

    /// CAM_Focus: stop 8x 01 04 08 00 FF, far 8x 01 04 08 2p FF, near 8x 01 04 08 3p FF
    static func focus(address: Int, speed: Int) -> [UInt8] {
        let p = UInt8(max(0, min(maxFocusSpeed, abs(speed) - 1)))
        let b: UInt8 = speed == 0 ? 0x00 : (speed > 0 ? 0x20 | p : 0x30 | p)
        return [header(address), 0x01, 0x04, 0x08, b, 0xFF]
    }

    /// CAM_Focus Auto 8x 01 04 38 02 FF / Manual 8x 01 04 38 03 FF
    static func focusAuto(address: Int) -> [UInt8] { [header(address), 0x01, 0x04, 0x38, 0x02, 0xFF] }
    static func focusManual(address: Int) -> [UInt8] { [header(address), 0x01, 0x04, 0x38, 0x03, 0xFF] }

    /// CAM_Memory: reset 8x 01 04 3F 00 pp FF, set 01, recall 02
    static func presetRecall(address: Int, preset: Int) -> [UInt8] { memory(address, 0x02, preset) }
    static func presetStore(address: Int, preset: Int) -> [UInt8] { memory(address, 0x01, preset) }
    static func presetReset(address: Int, preset: Int) -> [UInt8] { memory(address, 0x00, preset) }
    private static func memory(_ a: Int, _ op: UInt8, _ n: Int) -> [UInt8] {
        [header(a), 0x01, 0x04, 0x3F, op, UInt8(max(0, min(0xFE, n))), 0xFF]
    }

    /// CAM_PowerInq 8x 09 04 00 FF (used as a "is anybody there" probe).
    static func powerInquiry(address: Int) -> [UInt8] { [header(address), 0x09, 0x04, 0x00, 0xFF] }

    /// Speed 1…max for a joystick value (sign kept; |x| below the dead zone → 0).
    static func step(_ x: Double, scale: Double, max m: Int, deadZone: Double = 0.04) -> Int {
        let a = abs(x)
        guard a.isFinite, a > deadZone else { return 0 }
        let s = Swift.max(0.05, Swift.min(1, scale))
        let v = Swift.max(1, Swift.min(m, Int((Swift.min(1, a) * s * Double(m)).rounded())))
        return x < 0 ? -v : v
    }
}

// MARK: - VISCA replies

enum VISCAReply: Equatable {
    case ack(socket: Int)                       // 90 4y FF
    case completion(socket: Int, data: [UInt8]) // 90 5y … FF
    case error(socket: Int, code: UInt8)        // 90 6y 0z FF
    case other([UInt8])

    static func parse(_ m: [UInt8]) -> VISCAReply {
        guard m.count >= 3, m.last == 0xFF, m[0] & 0xF0 >= 0x90 else { return .other(m) }
        let kind = m[1] & 0xF0, socket = Int(m[1] & 0x0F)
        switch kind {
        case 0x40 where m.count == 3: return .ack(socket: socket)
        case 0x50: return .completion(socket: socket, data: Array(m[2..<(m.count - 1)]))
        case 0x60 where m.count >= 4: return .error(socket: socket, code: m[2])
        default: return .other(m)
        }
    }

    /// Extracts complete FF-terminated messages from a byte stream buffer (keeps the incomplete tail).
    static func split(_ buffer: inout [UInt8]) -> [[UInt8]] {
        var out: [[UInt8]] = []
        while let i = buffer.firstIndex(of: 0xFF) {
            out.append(Array(buffer[...i]))
            buffer.removeSubrange(...i)
        }
        if buffer.count > 64 { buffer.removeAll() }   // garbage without terminator
        return out
    }

    static func errorText(_ code: UInt8) -> String {
        switch code {
        case 0x01: return L("VISCA 오류: 메시지 길이 오류")
        case 0x02: return L("VISCA 오류: 명령 구문 오류")
        case 0x03: return L("VISCA 오류: 명령 버퍼 가득 참")
        case 0x04: return L("VISCA 오류: 명령 취소됨")
        case 0x05: return L("VISCA 오류: 소켓 없음")
        case 0x41: return L("VISCA 오류: 지금 실행할 수 없는 명령")
        default: return Lf("VISCA 오류: 코드 %@", String(format: "%02X", code))
        }
    }
}

/// Sony VISCA-over-IP 8-byte header: payload type (2), payload length (2), sequence number (4), big endian.
enum VISCAIPFrame {
    static let command: UInt16 = 0x0100
    static let inquiry: UInt16 = 0x0110
    static let reply: UInt16 = 0x0111
    static let deviceSetting: UInt16 = 0x0120
    static let control: UInt16 = 0x0200
    static let controlReply: UInt16 = 0x0201

    static func wrap(_ type: UInt16, _ payload: [UInt8], seq: UInt32) -> [UInt8] {
        let n = UInt16(payload.count)
        return [UInt8(type >> 8), UInt8(type & 0xFF), UInt8(n >> 8), UInt8(n & 0xFF),
                UInt8(seq >> 24), UInt8((seq >> 16) & 0xFF), UInt8((seq >> 8) & 0xFF), UInt8(seq & 0xFF)] + payload
    }

    /// RESET of the sequence number: 02 00 00 01 <seq> 01
    static func resetSequence(seq: UInt32 = 0) -> [UInt8] { wrap(control, [0x01], seq: seq) }

    static func parse(_ d: [UInt8]) -> (type: UInt16, seq: UInt32, payload: [UInt8])? {
        guard d.count >= 8 else { return nil }
        let type = UInt16(d[0]) << 8 | UInt16(d[1])
        let len = Int(UInt16(d[2]) << 8 | UInt16(d[3]))
        let seq = UInt32(d[4]) << 24 | UInt32(d[5]) << 16 | UInt32(d[6]) << 8 | UInt32(d[7])
        guard d.count >= 8 + len else { return nil }
        return (type, seq, Array(d[8..<(8 + len)]))
    }
}

// MARK: - Backends

enum PTZLinkState: Equatable {
    case idle
    case connecting
    case connected
    case error(String)

    var isConnected: Bool { self == .connected }

    var text: String {
        switch self {
        case .idle: return L("연결 안 됨")
        case .connecting: return L("연결 중…")
        case .connected: return L("연결됨")
        case .error(let m): return m
        }
    }
}

protocol PTZBackend: AnyObject {
    /// Link state changes (called on the backend's queue).
    var onState: ((PTZLinkState) -> Void)? { get set }
    /// Camera-reported command errors (VISCA 90 6y …); nil clears after a later successful completion.
    var onCameraError: ((String?) -> Void)? { get set }
    func start()
    func stop()
    func send(_ cmd: PTZCommand)
}

/// VISCA over Sony IP framing (UDP), raw TCP or raw UDP, with reply parsing and TCP reconnect.
final class VISCAClient: PTZBackend {
    enum Framing: Equatable { case sonyIP, rawTCP, rawUDP }

    let host: String
    let port: UInt16
    let framing: Framing
    let address: Int
    var onState: ((PTZLinkState) -> Void)?
    var onCameraError: ((String?) -> Void)?
    /// Every parsed reply (tests / diagnostics). Called on the client queue.
    var onReply: ((VISCAReply) -> Void)?
    /// No reply within this time after a command → "camera not responding".
    var replyTimeout: TimeInterval = 1.5

    private let q = DispatchQueue(label: "hongmix.ptz.visca")
    private var conn: NWConnection?
    private var running = false
    private var state: PTZLinkState = .idle
    private var seq: UInt32 = 0
    private var rx: [UInt8] = []
    private var ready = false
    private var pending: [[UInt8]] = []     // non-motion commands sent before the link was ready
    private var reconnectDelay: TimeInterval = 1
    private var reconnectScheduled = false
    private var lastSend: UInt64 = 0
    private var lastRx: UInt64 = 0
    private var hadError = false

    init(host: String, port: Int, framing: Framing, address: Int = 1) {
        self.host = host.trimmingCharacters(in: .whitespaces)
        self.port = UInt16(clamping: max(1, port))
        self.framing = framing
        self.address = address
    }

    convenience init?(config: PTZCameraConfig) {
        let f: Framing
        switch config.transport {
        case .viscaIP: f = .sonyIP
        case .viscaTCP: f = .rawTCP
        case .viscaUDP: f = .rawUDP
        case .ndi: return nil
        }
        self.init(host: config.host, port: config.port, framing: f, address: config.address)
    }

    func start() { q.async { guard !self.running else { return }; self.running = true; self.connect() } }

    func stop() {
        q.async {
            self.running = false
            self.conn?.cancel()
            self.conn = nil
            self.ready = false
            self.pending.removeAll()
            self.setState(.idle)
        }
    }

    func send(_ cmd: PTZCommand) {
        let payload = cmd.visca(address: address)
        let motion = cmd.isMotion
        q.async { self.sendPayload(payload, queueIfNotReady: !motion) }
    }

    /// Sends a raw VISCA message (e.g. `VISCA.absolutePanTilt`). Inquiries (8x 09 …) use the inquiry type.
    func sendRaw(_ payload: [UInt8]) { q.async { self.sendPayload(payload, queueIfNotReady: true) } }

    /// Blocks until queued work on the client queue has run (tests).
    func sync() { q.sync {} }

    // MARK: private (client queue)

    private static func now() -> UInt64 { DispatchTime.now().uptimeNanoseconds }

    private func setState(_ s: PTZLinkState) {
        guard s != state else { return }
        state = s
        onState?(s)
    }

    private func connect() {
        guard running, conn == nil else { return }
        guard !host.isEmpty, let p = NWEndpoint.Port(rawValue: port) else {
            setState(.error(L("카메라 IP 주소를 입력하세요")))
            return
        }
        let params: NWParameters
        if framing == .rawTCP {
            let tcp = NWProtocolTCP.Options()
            tcp.noDelay = true
            tcp.connectionTimeout = 3
            params = NWParameters(tls: nil, tcp: tcp)
        } else {
            params = .udp
        }
        let c = NWConnection(host: NWEndpoint.Host(host), port: p, using: params)
        conn = c
        ready = false
        rx.removeAll()
        setState(.connecting)
        c.stateUpdateHandler = { [weak self] st in self?.connectionState(c, st) }
        c.start(queue: q)
    }

    private func connectionState(_ c: NWConnection, _ st: NWConnection.State) {
        guard c === conn else { return }
        switch st {
        case .ready:
            ready = true
            reconnectDelay = 1
            if framing == .rawTCP { setState(.connected) }   // UDP: connected once the camera answers
            receive(c)
            if framing == .sonyIP { resetSequence() }
            let p = pending
            pending.removeAll()
            for m in p { sendPayload(m, queueIfNotReady: false) }
        case .waiting(let e), .failed(let e):
            fail(Lf("카메라 연결 실패: %@", Self.describe(e)))
        case .cancelled, .setup, .preparing:
            break
        @unknown default:
            break
        }
    }

    private static func describe(_ e: NWError) -> String {
        switch e {
        case .posix(let code): return String(cString: strerror(code.rawValue))
        default: return e.localizedDescription
        }
    }

    private func fail(_ message: String) {
        conn?.cancel()
        conn = nil
        ready = false
        setState(.error(message))
        guard running, !reconnectScheduled else { return }
        reconnectScheduled = true
        let delay = reconnectDelay
        reconnectDelay = min(10, reconnectDelay * 2)
        q.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self else { return }
            self.reconnectScheduled = false
            self.connect()
        }
    }

    private func receive(_ c: NWConnection) {
        if framing == .rawTCP {
            c.receive(minimumIncompleteLength: 1, maximumLength: 4096) { [weak self] data, _, complete, err in
                guard let self, c === self.conn else { return }
                if let data, !data.isEmpty { self.received(Array(data)) }
                if let err { self.fail(Lf("카메라 연결 실패: %@", Self.describe(err))); return }
                if complete { self.fail(L("카메라가 연결을 끊음")); return }
                self.receive(c)
            }
        } else {
            c.receiveMessage { [weak self] data, _, _, err in
                guard let self, c === self.conn else { return }
                if let data, !data.isEmpty { self.received(Array(data)) }
                if err != nil {
                    // UDP: ICMP "port unreachable" etc. Keep the socket, report and retry receiving.
                    self.setState(.error(L("카메라 응답 없음")))
                }
                self.q.asyncAfter(deadline: .now() + (err == nil ? 0 : 0.5)) { [weak self] in
                    guard let self, c === self.conn else { return }
                    self.receive(c)
                }
            }
        }
    }

    private func received(_ bytes: [UInt8]) {
        lastRx = Self.now()
        var messages: [[UInt8]] = []
        if framing == .sonyIP {
            guard let f = VISCAIPFrame.parse(bytes) else { return }
            if f.type == VISCAIPFrame.controlReply {
                if f.payload == [0x0F, 0x01] {          // sequence number error → reset again
                    resetSequence()
                } else if f.payload == [0x0F, 0x02] {   // message abnormality
                    report(L("VISCA 오류: 메시지 이상"))
                }
                setState(.connected)
                return
            }
            var b = f.payload
            messages = VISCAReply.split(&b)
        } else {
            rx += bytes
            messages = VISCAReply.split(&rx)
        }
        setState(.connected)
        for m in messages {
            let r = VISCAReply.parse(m)
            onReply?(r)
            switch r {
            case .error(_, let code): report(VISCAReply.errorText(code))
            case .completion:
                if hadError { hadError = false; onCameraError?(nil) }
            default: break
            }
        }
    }

    private func report(_ text: String) {
        hadError = true
        onCameraError?(text)
    }

    private func resetSequence() {
        seq = 0
        write(VISCAIPFrame.resetSequence(seq: 0))
    }

    private func sendPayload(_ payload: [UInt8], queueIfNotReady: Bool) {
        if conn == nil && running && !reconnectScheduled { connect() }
        guard ready, conn != nil else {
            if queueIfNotReady && running { pending = Array((pending + [payload]).suffix(4)) }
            return
        }
        switch framing {
        case .sonyIP:
            seq &+= 1
            let type = payload.count > 1 && payload[1] == 0x09 ? VISCAIPFrame.inquiry : VISCAIPFrame.command
            write(VISCAIPFrame.wrap(type, payload, seq: seq))
        case .rawTCP, .rawUDP:
            write(payload)
        }
        let sent = Self.now()
        lastSend = sent
        q.asyncAfter(deadline: .now() + replyTimeout) { [weak self] in
            guard let self, self.running, self.lastSend == sent, self.lastRx < sent, self.conn != nil else { return }
            self.setState(.error(L("카메라 응답 없음")))
        }
    }

    private func write(_ bytes: [UInt8]) {
        conn?.send(content: Data(bytes), completion: .contentProcessed { [weak self] err in
            guard let self, let err else { return }
            if self.framing == .rawTCP { self.fail(Lf("카메라 연결 실패: %@", Self.describe(err))) }
        })
    }
}

// MARK: - Throttled continuous-motion driver

/// Drives one continuous control (pan/tilt pair, zoom rocker …) from a UI that sends rapid updates.
///  - sends only when the value changes, at most once per `minInterval` (latest value wins);
///  - the zero value (stop) is sent immediately, bypassing the throttle;
///  - dead-man: if `set` isn't called for `deadman` seconds while moving, the zero value is sent, so a lost
///    mouse-up / gesture-end never leaves the camera moving. A held, unmoved control must therefore call
///    `set` with the same value periodically (e.g. every 200 ms) — repeats are free (not sent).
final class PTZAxisDriver<V: Equatable> {
    let zero: V
    let minInterval: TimeInterval
    let deadman: TimeInterval
    private let emit: (V) -> Void
    private let q: DispatchQueue
    private var lastSent: V?
    private var lastSentAt: UInt64 = 0
    private var lastUpdate: UInt64 = 0
    private var pending: V?
    private var flushScheduled = false
    private var deadmanArmed = false

    init(zero: V, minInterval: TimeInterval = 0.05, deadman: TimeInterval = 0.5,
         queue: DispatchQueue = DispatchQueue(label: "hongmix.ptz.driver"), emit: @escaping (V) -> Void) {
        self.zero = zero
        self.minInterval = minInterval
        self.deadman = deadman
        self.q = queue
        self.emit = emit
    }

    private static func now() -> UInt64 { DispatchTime.now().uptimeNanoseconds }

    func set(_ v: V) {
        q.async {
            let now = Self.now()
            self.lastUpdate = now
            if v == self.zero {
                self.pending = nil
                if self.lastSent != self.zero { self.send(v, now) }
                return
            }
            self.armDeadman()
            if v == self.lastSent { self.pending = nil; return }
            let elapsed = Double(now &- self.lastSentAt) / 1e9
            if !self.flushScheduled && (self.lastSent == nil || elapsed >= self.minInterval) {
                self.send(v, now)
            } else {
                self.pending = v
                if !self.flushScheduled {
                    self.flushScheduled = true
                    self.q.asyncAfter(deadline: .now() + (self.minInterval - elapsed)) { self.flush() }
                }
            }
        }
    }

    /// Immediate stop (sends zero unless the last value sent was already zero).
    func stop() { set(zero) }

    /// Forget what was sent last (after a command sent outside this driver, e.g. an API PTZMoveUp),
    /// so the next value — including zero — is always sent.
    func invalidate() { q.async { self.lastSent = nil; self.pending = nil } }

    func sync() { q.sync {} }

    private func send(_ v: V, _ now: UInt64) {
        pending = nil
        lastSent = v
        lastSentAt = now
        emit(v)
    }

    private func flush() {
        flushScheduled = false
        guard let v = pending else { return }
        pending = nil
        send(v, Self.now())
    }

    private func armDeadman() {
        guard !deadmanArmed else { return }
        deadmanArmed = true
        q.asyncAfter(deadline: .now() + deadman) { self.deadmanFire() }
    }

    private func deadmanFire() {
        deadmanArmed = false
        let moving = (lastSent != nil && lastSent != zero) || pending != nil
        guard moving else { return }
        let idle = Double(Self.now() &- lastUpdate) / 1e9
        if idle >= deadman - 0.002 {
            pending = nil
            send(zero, Self.now())
        } else {
            deadmanArmed = true
            q.asyncAfter(deadline: .now() + (deadman - idle)) { self.deadmanFire() }
        }
    }
}

/// Joystick value → VISCA pan/tilt steps.
struct PTZVelocity: Equatable {
    var pan: Int
    var tilt: Int
    static let zero = PTZVelocity(pan: 0, tilt: 0)

    /// pan/tilt -1…1 (+ = right / up), scaled by the "Speed" slider 0…1.
    init(pan: Double, tilt: Double, scale: Double) {
        self.pan = VISCA.step(pan, scale: scale, max: VISCA.maxPanSpeed)
        self.tilt = VISCA.step(tilt, scale: scale, max: VISCA.maxTiltSpeed)
    }

    init(pan: Int, tilt: Int) {
        self.pan = pan
        self.tilt = tilt
    }
}

#if !PTZ_STANDALONE

// MARK: - NDI PTZ backend

/// NDI PTZ through the NDI receiver of the input showing that source (mc_ndi.c registry).
final class NDIPTZBackend: PTZBackend {
    var onState: ((PTZLinkState) -> Void)?
    var onCameraError: ((String?) -> Void)?
    private let source: String
    private let presetSpeed: Float
    private let q = DispatchQueue(label: "hongmix.ptz.ndi")
    private var timer: DispatchSourceTimer?
    private var state: PTZLinkState = .idle

    init(source: String, presetSpeed: Double) {
        self.source = source
        self.presetSpeed = Float(max(0, min(1, presetSpeed)))
    }

    func start() {
        q.async { [weak self] in
            guard let self, self.timer == nil else { return }
            self.setState(.connecting)
            let t = DispatchSource.makeTimerSource(queue: self.q)
            t.schedule(deadline: .now(), repeating: 2)
            t.setEventHandler { [weak self] in self?.poll() }
            t.resume()
            self.timer = t
        }
    }

    func stop() {
        q.async {
            self.timer?.cancel()
            self.timer = nil
            self.setState(.idle)
        }
    }

    func send(_ cmd: PTZCommand) {
        q.async {
            let rc: Int32
            switch cmd {
            case let .panTilt(p, t):   // NDI: pan + = left, so invert
                rc = self.call(MC_NDI_PTZ_PAN_TILT_SPEED, -Float(p) / Float(VISCA.maxPanSpeed), Float(t) / Float(VISCA.maxTiltSpeed))
            case .home: rc = self.call(MC_NDI_PTZ_PAN_TILT, 0, 0)
            case let .zoom(s): rc = self.call(MC_NDI_PTZ_ZOOM_SPEED, Float(s) / Float(VISCA.maxZoomSpeed), 0)
            case .focusAuto: rc = self.call(MC_NDI_PTZ_FOCUS_AUTO, 0, 0)
            case .focusManual: rc = self.call(MC_NDI_PTZ_FOCUS_SPEED, 0, 0)
            case let .focus(s):        // ours + = far; NDI -1 = outwards (far)
                rc = self.call(MC_NDI_PTZ_FOCUS_SPEED, -Float(s) / Float(VISCA.maxFocusSpeed), 0)
            case let .presetRecall(n): rc = self.call(MC_NDI_PTZ_RECALL_PRESET, Float(min(99, n)), self.presetSpeed)
            case let .presetStore(n): rc = self.call(MC_NDI_PTZ_STORE_PRESET, Float(min(99, n)), 0)
            }
            self.apply(rc)
        }
    }

    private func call(_ cmd: Int32, _ a: Float, _ b: Float) -> Int32 {
        mc_ndi_ptz_source(source, cmd, a, b)
    }

    private func poll() { apply(call(MC_NDI_PTZ_SUPPORTED, 0, 0)) }

    private func apply(_ rc: Int32) {
        switch rc {
        case 1: setState(.connected)
        case 0: setState(.error(L("이 NDI 소스는 PTZ 제어를 지원하지 않음")))
        default: setState(.error(mc_ndi_available() != 0 ? L("NDI 입력이 연결되어 있지 않음") : L("NDI 런타임이 설치되어 있지 않음")))
        }
    }

    private func setState(_ s: PTZLinkState) {
        guard s != state else { return }
        state = s
        onState?(s)
    }
}

// MARK: - Per-input controller (UI model)

/// PTZ control of one input. Main thread API; bind the PTZ panel to this object.
final class PTZController: ObservableObject {
    let inputID: UUID
    private weak var engine: SwitcherEngine?

    /// Camera settings (transport, address, speeds, presets, Preview recall). Saved into the input's config.
    @Published var config: PTZCameraConfig {
        didSet {
            guard config != oldValue else { return }
            engine?.input(withID: inputID)?.config.ptz = config
            let linkChanged = config.transport != oldValue.transport || config.host != oldValue.host
                || config.port != oldValue.port || config.address != oldValue.address
                || config.presetSpeed != oldValue.presetSpeed
            if linkChanged && backend != nil { reconnect() }
        }
    }
    /// Connection status (idle / connecting / connected / error message).
    @Published private(set) var link: PTZLinkState = .idle
    /// Last error reported by the camera (VISCA 90 6y …), cleared by a later successful command.
    @Published private(set) var cameraError: String?
    /// Last preset recalled (highlight in the preset row).
    @Published private(set) var activePreset: Int?

    var statusText: String { cameraError ?? link.text }
    var isConnected: Bool { link.isConnected }

    private var backend: PTZBackend?
    private lazy var panTilt = PTZAxisDriver<PTZVelocity>(zero: .zero) { [weak self] v in
        self?.backend?.send(.panTilt(pan: v.pan, tilt: v.tilt))
    }
    private lazy var zoomDriver = PTZAxisDriver<Int>(zero: 0) { [weak self] z in
        self?.backend?.send(.zoom(z))
    }

    init(input: InputSource, engine: SwitcherEngine?) {
        inputID = input.id
        self.engine = engine
        config = input.config.ptz ?? PTZController.autoConfig(for: input)
    }

    /// First-time defaults: NDI inputs use NDI PTZ (no IP needed); a camera pulled over SRT / RTSP / RTMP /
    /// HTTP pre-fills its IP for VISCA (listener / server URLs and local addresses are left empty).
    static func autoConfig(for input: InputSource) -> PTZCameraConfig {
        if input.kind == .ndi { return PTZCameraConfig(transport: .ndi) }
        var c = PTZCameraConfig(transport: .viscaIP)
        let url = input.config.url.replacingOccurrences(of: "#tcp", with: "").replacingOccurrences(of: "#udp", with: "")
        guard let comps = URLComponents(string: url), let host = comps.host, !host.isEmpty else { return c }
        let q = comps.queryItems ?? []
        let listener = q.contains { ($0.name == "mode" && $0.value == "listener") || ($0.name == "listen" && $0.value == "1") }
        let local = ["0.0.0.0", "127.0.0.1", "localhost", "::", "::1"].contains(host)
        if ["srt", "rtsp", "rtmp", "rtmps", "http", "https", "udp", "tcp"].contains(comps.scheme ?? ""), !listener, !local {
            c.host = host
        }
        return c
    }

    deinit { backend?.stop() }

    // MARK: connection

    /// Opens the link (lazy: every command also connects). Safe to call repeatedly.
    func connect() {
        guard backend == nil else { return }
        let b: PTZBackend
        if config.transport == .ndi {
            let src = engine?.input(withID: inputID)?.config.ndiSource ?? ""
            b = NDIPTZBackend(source: src, presetSpeed: config.presetSpeed)
        } else if let v = VISCAClient(config: config) {
            b = v
        } else { return }
        b.onState = { [weak self] s in DispatchQueue.main.async { self?.link = s } }
        b.onCameraError = { [weak self] e in DispatchQueue.main.async { self?.cameraError = e } }
        backend = b
        b.start()
    }

    func disconnect() {
        panTilt.stop()
        zoomDriver.stop()
        panTilt.sync()
        zoomDriver.sync()
        backend?.stop()
        backend = nil
        link = .idle
        cameraError = nil
    }

    func reconnect() {
        disconnect()
        connect()
    }

    private func send(_ cmd: PTZCommand) {
        connect()
        backend?.send(cmd)
    }

    // MARK: joystick / zoom rocker (throttled, dead-man)

    /// Joystick: pan/tilt -1…1 (+ = right / up), scaled by `config.panTiltSpeed`. Call on every drag
    /// change and every ~200 ms while held still; (0, 0) or `stopMove()` on release. Stops by itself if
    /// no call arrives for 500 ms.
    func move(panSpeed: Double, tiltSpeed: Double) {
        connect()
        panTilt.set(PTZVelocity(pan: panSpeed, tilt: tiltSpeed, scale: config.panTiltSpeed))
    }

    func stopMove() {
        panTilt.invalidate()
        panTilt.stop()
    }

    /// Zoom rocker: -1 (wide) … +1 (tele), scaled by `config.zoomSpeed`; same throttle / dead-man rules.
    func zoom(_ speed: Double) {
        connect()
        zoomDriver.set(VISCA.step(speed, scale: config.zoomSpeed, max: VISCA.maxZoomSpeed))
    }

    func zoomStop() {
        zoomDriver.invalidate()
        zoomDriver.stop()
    }

    // MARK: latched commands (buttons / API) — no dead-man

    /// Starts moving until `stopMove()` (vMix PTZMove…). pan/tilt direction -1, 0, 1; speed 0…1.
    func startMove(pan: Int, tilt: Int, speed: Double) {
        panTilt.invalidate()
        let s = max(0.01, min(1, speed))
        send(.panTilt(pan: pan.signum() * max(1, Int((s * Double(VISCA.maxPanSpeed)).rounded())),
                      tilt: tilt.signum() * max(1, Int((s * Double(VISCA.maxTiltSpeed)).rounded()))))
    }

    /// Starts zooming until `zoomStop()`: direction + = in (tele), - = out; speed 0…1.
    func startZoom(direction: Int, speed: Double) {
        zoomDriver.invalidate()
        send(.zoom(direction.signum() * max(1, Int((max(0, min(1, speed)) * Double(VISCA.maxZoomSpeed)).rounded()))))
    }

    func home() {
        panTilt.invalidate()
        send(.home)
    }

    func focusAuto() { send(.focusAuto) }
    func focusManual() { send(.focusManual) }
    func focusNear(speed: Double = 0.5) { send(.focus(-max(1, Int((max(0, min(1, speed)) * Double(VISCA.maxFocusSpeed)).rounded())))) }
    func focusFar(speed: Double = 0.5) { send(.focus(max(1, Int((max(0, min(1, speed)) * Double(VISCA.maxFocusSpeed)).rounded())))) }
    func focusStop() { send(.focus(0)) }

    // MARK: presets

    func recallPreset(_ number: Int) {
        panTilt.invalidate()
        zoomDriver.invalidate()
        activePreset = number
        send(.presetRecall(config.wireNumber(number)))
    }

    /// Stores the current position as preset `number` (adds it to the list, or renames an existing one).
    func storePreset(_ number: Int, name: String? = nil) {
        send(.presetStore(config.wireNumber(number)))
        if let i = config.presets.firstIndex(where: { $0.number == number }) {
            if let name, !name.isEmpty { config.presets[i].name = name }
        } else {
            config.presets.append(PTZPreset(number: number, name: name ?? Lf("프리셋 %@", String(number))))
            config.presets.sort { $0.number < $1.number }
        }
        activePreset = number
    }

    /// "+ Save": stores the current position under the next free number.
    @discardableResult
    func saveNewPreset(name: String? = nil) -> Int {
        let n = config.nextPresetNumber
        storePreset(n, name: name)
        return n
    }

    func renamePreset(_ number: Int, to name: String) {
        if let i = config.presets.firstIndex(where: { $0.number == number }) { config.presets[i].name = name }
    }

    /// Removes the preset from the list (the camera's memory is left as is).
    func deletePreset(_ number: Int) {
        config.presets.removeAll { $0.number == number }
        if config.previewPreset == number { config.previewPreset = nil }
        if activePreset == number { activePreset = nil }
    }
}

// MARK: - Manager (engine hook + API)

final class PTZManager {
    static let shared = PTZManager()
    private weak var engine: SwitcherEngine?
    private var controllers: [UUID: PTZController] = [:]
    private var subs = Set<AnyCancellable>()

    /// Installs the Preview hook ("Move to preset when put in Preview") and input-removal cleanup. Idempotent.
    func attach(engine e: SwitcherEngine) {
        guard engine !== e else { return }
        engine = e
        subs.removeAll()
        e.$previewID
            .removeDuplicates()
            .sink { [weak self] id in
                // @Published fires in willSet; act on the next run-loop turn when the switch is complete.
                DispatchQueue.main.async { self?.previewChanged(id) }
            }
            .store(in: &subs)
        e.$inputs
            .sink { [weak self] list in
                DispatchQueue.main.async {
                    guard let self else { return }
                    let ids = Set(list.map(\.id))
                    for (id, c) in self.controllers where !ids.contains(id) {
                        c.disconnect()
                        self.controllers[id] = nil
                    }
                }
            }
            .store(in: &subs)
    }

    /// The PTZ controller of an input (created on first use). Main thread.
    func controller(for input: InputSource) -> PTZController {
        if let c = controllers[input.id] { return c }
        let c = PTZController(input: input, engine: engine)
        controllers[input.id] = c
        return c
    }

    /// True when the input has a PTZ configuration, or is an NDI input (NDI PTZ is tried automatically).
    func isPTZCapable(_ input: InputSource) -> Bool {
        input.config.ptz != nil || input.kind == .ndi
    }

    private func previewChanged(_ id: UUID?) {
        guard let e = engine, let id, e.previewID == id, let input = e.input(withID: id) else { return }
        guard let cfg = input.config.ptz, cfg.recallOnPreview, let preset = cfg.effectivePreviewPreset else { return }
        guard e.programID != id else { return }   // never move a camera that is on air
        controller(for: input).recallPreset(preset)
    }

    // MARK: vMix API

    /// vMix PTZ functions (lowercased name) plus HongMix PTZPresetRecall / PTZPresetStore.
    /// Returns nil on success or an error text (API response).
    func api(_ fn: String, value: String, input: InputSource?, engine e: SwitcherEngine) -> String? {
        attach(engine: e)
        guard let input else { return "Input not found" }
        let c = controller(for: input)
        let v = value.trimmingCharacters(in: .whitespaces)
        let speed = Double(v).map { max(0, min(1, $0)) }
        let pt = speed ?? c.config.panTiltSpeed
        if fn == "ptzsetcamera" {
            // HongMix: Value = "transport,host[,port[,address]]" — transport viscaIP | viscaTCP | viscaUDP | ndi
            let p = v.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
            guard let t = p.first.flatMap({ s in PTZTransport.allCases.first { $0.rawValue.caseInsensitiveCompare(s) == .orderedSame } })
            else { return "Value=viscaIP|viscaTCP|viscaUDP|ndi,host[,port[,address]]" }
            var cfg = c.config
            cfg.transport = t
            cfg.host = p.count > 1 ? p[1] : ""
            cfg.port = p.count > 2 ? (Int(p[2]) ?? t.defaultPort) : t.defaultPort
            if p.count > 3, let a = Int(p[3]) { cfg.address = max(1, min(7, a)) }
            c.config = cfg
            c.reconnect()
            return nil
        }
        switch fn {
        case "ptzmoveup": c.startMove(pan: 0, tilt: 1, speed: pt)
        case "ptzmovedown": c.startMove(pan: 0, tilt: -1, speed: pt)
        case "ptzmoveleft": c.startMove(pan: -1, tilt: 0, speed: pt)
        case "ptzmoveright": c.startMove(pan: 1, tilt: 0, speed: pt)
        case "ptzmoveupleft": c.startMove(pan: -1, tilt: 1, speed: pt)
        case "ptzmoveupright": c.startMove(pan: 1, tilt: 1, speed: pt)
        case "ptzmovedownleft": c.startMove(pan: -1, tilt: -1, speed: pt)
        case "ptzmovedownright": c.startMove(pan: 1, tilt: -1, speed: pt)
        case "ptzmovestop": c.stopMove()
        case "ptzhome": c.home()
        case "ptzzoomin": c.startZoom(direction: 1, speed: speed ?? c.config.zoomSpeed)
        case "ptzzoomout": c.startZoom(direction: -1, speed: speed ?? c.config.zoomSpeed)
        case "ptzzoomstop": c.zoomStop()
        case "ptzfocusauto": c.focusAuto()
        case "ptzfocusmanual": c.focusManual()
        case "ptzfocusnear": c.focusNear(speed: speed ?? 0.5)
        case "ptzfocusfar": c.focusFar(speed: speed ?? 0.5)
        case "ptzfocusstop": c.focusStop()
        case "ptzpresetrecall", "ptzpresetstore":   // HongMix: Value = preset number
            guard let n = Int(v), (0...255).contains(n) else { return "Value=preset number" }
            if fn == "ptzpresetrecall" { c.recallPreset(n) } else { c.storePreset(n) }
        case "ptzmovetovirtualinputposition":
            // vMix moves to a PTZ virtual input's position. HongMix has no virtual inputs: Input = the camera
            // input, and it moves to the camera's Preview preset (or the first preset).
            guard let n = c.config.effectivePreviewPreset else { return "No PTZ presets on this input" }
            c.recallPreset(n)
        case "ptzmovetovirtualinputpositionbyindex":
            // vMix: Value = index (0-based) of the virtual inputs of this camera → HongMix: index in the preset list.
            guard let i = Int(v), c.config.presets.indices.contains(i) else { return "Value=preset index 0…\(max(0, c.config.presets.count - 1))" }
            c.recallPreset(c.config.presets[i].number)
        case "ptzcreatevirtualinput", "ptzupdatevirtualinput":
            return "Not supported in HongMix (no PTZ virtual inputs; use PTZPresetStore)"
        default:
            return "Function not found: \(fn)"
        }
        return nil
    }
}

#endif
