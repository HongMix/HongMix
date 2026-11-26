import Foundation
import Network
import Combine
import CoreImage
import CoreVideo

// MARK: - Access control (Settings › Network › Remote control)

/// Who may use the HTTP (8088) / TCP (8099) control API.
///  - enabled (Settings › Network › Remote control): off = both ports stay closed. Off by default from
///    2.1.3 — turned on only by those who use Companion / Stream Deck / the web remote.
///  - mode "lan" (like vMix): any device on the network, optionally only the listed IPs
///  - mode "local": only this Mac  ·  mode "off" (older versions): nobody
///  - HTTP password (optional): HTTP Basic auth, any user name (like vMix's Web Controller password)
enum APIAccess {
    static let modeKey = "apiAccessMode", passwordKey = "apiPassword", allowKey = "apiAllowedIPs"
    static let enabledKey = "apiEnabled"
    /// Not set yet: on only if an earlier version's mode was chosen on purpose (lan/local), else off.
    static var enabled: Bool {
        let d = UserDefaults.standard
        if d.object(forKey: enabledKey) != nil { return d.bool(forKey: enabledKey) }
        if let m = d.string(forKey: modeKey) { return m != "off" }
        return false
    }
    static var mode: String { UserDefaults.standard.string(forKey: modeKey) ?? "lan" }
    static var password: String { UserDefaults.standard.string(forKey: passwordKey) ?? "" }
    static var allowed: [String] {
        (UserDefaults.standard.string(forKey: allowKey) ?? "").split(whereSeparator: { $0 == "," || $0 == " " || $0 == "\n" })
            .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    static func host(of conn: NWConnection) -> String? {
        if case let .hostPort(h, _) = conn.endpoint {
            var s = "\(h)"
            if let pct = s.firstIndex(of: "%") { s = String(s[..<pct]) }       // fe80::1%en0
            if s.hasPrefix("::ffff:") { s = String(s.dropFirst(7)) }          // IPv4-mapped
            return s
        }
        return nil
    }

    static func isLoopback(_ h: String) -> Bool { h == "127.0.0.1" || h == "::1" || h.hasPrefix("127.") }

    /// true = this connection may talk to the API.
    static func permits(_ conn: NWConnection) -> Bool {
        guard enabled, let h = host(of: conn) else { return false }
        if isLoopback(h) { return mode != "off" }
        switch mode {
        case "off", "local": return false
        default:
            let list = allowed
            return list.isEmpty || list.contains(h)
        }
    }
}

// MARK: - HTTP (port 8088): /api/?Function=...  and a touch web controller at /

final class HTTPAPIServer {
    weak var engine: SwitcherEngine?
    private var listener: NWListener?
    private let queue = DispatchQueue(label: "HongMix.http")
    private let thumbQueue = DispatchQueue(label: "HongMix.http.thumbs", qos: .utility)   // JPEG work never delays commands

    var isRunning: Bool { listener != nil }

    func start(port: UInt16) -> Bool {
        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true      // turning remote control off → on re-binds at once
        guard let p = NWEndpoint.Port(rawValue: port), let l = try? NWListener(using: params, on: p) else { return false }
        l.newConnectionHandler = { [weak self] conn in self?.handle(conn) }
        l.start(queue: queue)
        listener = l
        return true
    }

    func stop() {
        listener?.cancel()
        listener = nil
    }

    /// Reads until the end of the HTTP headers (requests can arrive in several TCP segments), max 16 KB.
    private func readRequest(_ conn: NWConnection, _ buf: Data, _ done: @escaping (Data?) -> Void) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 16384) { [weak self] data, _, isComplete, error in
            var b = buf
            if let d = data { b.append(d) }
            if b.range(of: Data("\r\n\r\n".utf8)) != nil || b.count >= 16384 { done(b); return }
            if isComplete || error != nil || data == nil { done(b.isEmpty ? nil : b); return }
            self?.readRequest(conn, b, done)
        }
    }

    private func handle(_ conn: NWConnection) {
        guard APIAccess.permits(conn) else { conn.cancel(); return }
        conn.start(queue: queue)
        var got = false
        queue.asyncAfter(deadline: .now() + 10) { if !got { conn.cancel() } }   // never sent a request: close
        readRequest(conn, Data()) { [weak self] data in
            got = true
            guard let self = self, let data = data, let text = String(data: data, encoding: .utf8) else {
                conn.cancel()
                return
            }
            let lines = text.components(separatedBy: "\r\n")
            let firstLine = lines.first ?? ""
            let parts = firstLine.split(separator: " ")
            let target = parts.count > 1 ? String(parts[1]) : "/"
            var headers: [String: String] = [:]
            for l in lines.dropFirst() {
                guard let i = l.firstIndex(of: ":") else { continue }
                headers[l[..<i].lowercased()] = l[l.index(after: i)...].trimmingCharacters(in: .whitespaces)
            }
            let path = target.split(separator: "?", maxSplits: 1).first.map(String.init)?.lowercased() ?? "/"
            if let deny = HTTPAPIServer.reject(headers, path: path) {
                self.reply(conn, deny.0, "text/plain; charset=utf-8", Data(deny.1.utf8), extra: deny.2)
                return
            }
            if path == "/stream.mjpg" {
                // live PREVIEW / PROGRAM for the web remote (WebStream.swift) — the connection stays open
                let queryPart = target.contains("?") ? String(target.split(separator: "?", maxSplits: 1)[1]) : ""
                WebStreamHub.shared.attach(conn, query: APIProcessor.parseQuery(queryPart))
                return
            }
            if path == "/thumb" || path == "/thumbnail" {
                // picture on the main thread, JPEG encoding here (keeps the switcher UI free)
                let queryPart = target.contains("?") ? String(target.split(separator: "?", maxSplits: 1)[1]) : ""
                let q = APIProcessor.parseQuery(queryPart)
                DispatchQueue.main.async {
                    let pb = self.engine.flatMap { WebRemote.thumbBuffer(q, $0) }
                    self.thumbQueue.async {
                        if let pb = pb, let jpg = self.thumbnail(pb, width: Int(q["width"] ?? "") ?? 320) {
                            self.reply(conn, "200 OK", "image/jpeg", jpg, extra: "Cache-Control: no-store\r\n")
                        } else {
                            self.reply(conn, "404 Not Found", "text/plain", Data("no picture".utf8))
                        }
                    }
                }
                return
            }
            DispatchQueue.main.async {
                let (status, contentType, bodyData) = self.routeData(target)
                self.reply(conn, status, contentType, bodyData)
            }
        }
    }

    /// Blocks other websites from driving the switcher through the operator's browser (cross-site
    /// requests), and asks for the password when one is set.
    static func reject(_ h: [String: String], path: String = "/") -> (String, String, String)? {
        // only this page itself (same-origin) or a typed address / Companion (none or no header) may send
        if let site = h["sec-fetch-site"], site != "same-origin", site != "none",
           !TalentAccess.allowsCrossSiteNavigation(path: path, fetchMode: h["sec-fetch-mode"]) {
            return ("403 Forbidden", "cross-site request blocked", "")
        }
        if let origin = h["origin"], let host = h["host"] {
            let o = origin.replacingOccurrences(of: "http://", with: "").replacingOccurrences(of: "https://", with: "")
            if o != host { return ("403 Forbidden", "cross-origin request blocked", "") }
        }
        let pw = APIAccess.password
        // the tally is view-only: no password · Talent Cue paths check their own link key (TalentRemote)
        if !pw.isEmpty && !WebRemote.publicPaths.contains(path) && !TalentRemote.isTalentPath(path) {
            var ok = false
            if let a = h["authorization"], a.lowercased().hasPrefix("basic "),
               let d = Data(base64Encoded: String(a.dropFirst(6))), let s = String(data: d, encoding: .utf8),
               let colon = s.firstIndex(of: ":") {
                ok = String(s[s.index(after: colon)...]) == pw
            }
            if !ok { return ("401 Unauthorized", "password required", "WWW-Authenticate: Basic realm=\"HongMix\"\r\n") }
        }
        return nil
    }

    private func reply(_ conn: NWConnection, _ status: String, _ contentType: String, _ bodyData: Data, extra: String = "") {
                var head = "HTTP/1.1 \(status)\r\n"
                head += "Content-Type: \(contentType)\r\n"
                head += "Content-Length: \(bodyData.count)\r\n"
                head += extra
                head += "Connection: close\r\n\r\n"
                var resp = Data(head.utf8)
                resp.append(bodyData)
                conn.send(content: resp, completion: .contentProcessed { _ in conn.cancel() })
    }

    private let ciContext = CIContext(options: [.cacheIntermediates: false])

    private func routeData(_ target: String) -> (String, String, Data) {
        let (st, ct, body) = route(target)
        return (st, ct, Data(body.utf8))
    }

    /// Small JPEG of an input's latest frame (works for BGRA and NV12 sources).
    private func thumbnail(_ pb: CVPixelBuffer, width: Int) -> Data? {
        let img = CIImage(cvPixelBuffer: pb)
        let w = max(64, min(960, width))
        let scale = CGFloat(w) / max(1, img.extent.width)
        let small = img.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        guard let cs = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        return ciContext.jpegRepresentation(of: small, colorSpace: cs,
                                            options: [kCGImageDestinationLossyCompressionQuality as CIImageRepresentationOption: 0.6])
    }

    private func route(_ target: String) -> (String, String, String) {
        guard let engine = engine else { return ("500 Internal Server Error", "text/plain", "engine unavailable") }
        let pathPart = target.split(separator: "?", maxSplits: 1).first.map(String.init) ?? "/"
        let queryPart = target.contains("?") ? String(target.split(separator: "?", maxSplits: 1)[1]) : ""
        let path = pathPart.lowercased()
        let q = APIProcessor.parseQuery(queryPart)
        if let r = TalentRemote.route(path, q) { return r }
        if path == "/" || path == "/index.html" {
            return ("200 OK", "text/html; charset=utf-8", WebRemote.remotePage())
        }
        if path == "/remote.json" {
            return ("200 OK", "application/json; charset=utf-8", WebRemote.remoteState(engine))
        }
        if path == "/tally.json" {
            return ("200 OK", "application/json; charset=utf-8", WebRemote.tallyState(engine))
        }
        if path == "/api" || path == "/api/" {
            if let fn = q["function"], !fn.isEmpty {
                if let err = APIProcessor.perform(fn, q, engine) {
                    return ("500 Internal Server Error", "text/plain; charset=utf-8", err)
                }
                return ("200 OK", "text/plain; charset=utf-8", "Function completed successfully.")
            }
            return ("200 OK", "text/xml; charset=utf-8", APIProcessor.stateXML(engine))
        }
        if path == "/tally" || path == "/tally/" {
            // vMix-style phone tally light (pick an input, the whole screen turns red/green)
            return ("200 OK", "text/html; charset=utf-8", WebRemote.tallyPage())
        }
        if path == "/tally.txt" {
            return ("200 OK", "text/plain", APIProcessor.tallyString(engine))
        }
        return ("404 Not Found", "text/plain", "not found")
    }

    /// First non-loopback IPv4 address (for display).
    static func localIPAddress() -> String? {
        var addr: String?
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let first = ifaddr else { return nil }
        defer { freeifaddrs(ifaddr) }
        var ptr: UnsafeMutablePointer<ifaddrs>? = first
        while let p = ptr {
            let flags = Int32(p.pointee.ifa_flags)
            if let sa = p.pointee.ifa_addr, sa.pointee.sa_family == UInt8(AF_INET),
               (flags & IFF_UP) != 0, (flags & IFF_LOOPBACK) == 0 {
                var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                if getnameinfo(sa, socklen_t(sa.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 {
                    addr = String(cString: host)
                    let name = String(cString: p.pointee.ifa_name)
                    if name.hasPrefix("en") { break }
                }
            }
            ptr = p.pointee.ifa_next
        }
        return addr
    }
}

// MARK: - TCP (port 8099): FUNCTION / XML / XMLTEXT / TALLY / ACTS / SUBSCRIBE / QUIT

final class TCPAPIServer {
    weak var engine: SwitcherEngine? {
        didSet { subscribeToEngine() }
    }
    private var listener: NWListener?
    private let queue = DispatchQueue(label: "HongMix.tcp")
    private var clients: [ObjectIdentifier: TCPClient] = [:]   // main thread
    private var eventSub: AnyCancellable?
    private var lastActs: [String: String] = [:]                // activator key -> value

    var isRunning: Bool { listener != nil }

    func start(port: UInt16) -> Bool {
        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true      // turning remote control off → on re-binds at once
        guard let p = NWEndpoint.Port(rawValue: port), let l = try? NWListener(using: params, on: p) else { return false }
        l.newConnectionHandler = { [weak self] conn in
            DispatchQueue.main.async { self?.accept(conn) }
        }
        l.start(queue: queue)
        listener = l
        return true
    }

    func stop() {
        listener?.cancel()
        listener = nil
        for c in clients.values { c.conn.cancel() }
        clients.removeAll()
    }

    private func subscribeToEngine() {
        eventSub = engine?.switchEvents
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.broadcastChanges() }
    }

    private func accept(_ conn: NWConnection) {
        guard APIAccess.permits(conn) else { conn.cancel(); return }
        let client = TCPClient(conn: conn)
        let key = ObjectIdentifier(client)
        clients[key] = client
        conn.stateUpdateHandler = { [weak self] state in
            switch state {
            case .failed, .cancelled:
                DispatchQueue.main.async { self?.clients[key] = nil }
            default: break
            }
        }
        conn.start(queue: queue)
        receive(client)
    }

    private func receive(_ client: TCPClient) {
        client.conn.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, done, error in
            if let data = data, !data.isEmpty {
                DispatchQueue.main.async {
                    client.buffer.append(data)
                    self?.drainLines(client)
                }
            }
            if done || error != nil {
                client.conn.cancel()
                return
            }
            self?.receive(client)
        }
    }

    private func drainLines(_ client: TCPClient) {
        while let r = client.buffer.range(of: Data("\n".utf8)) {
            let lineData = client.buffer.subdata(in: client.buffer.startIndex..<r.lowerBound)
            client.buffer.removeSubrange(client.buffer.startIndex..<r.upperBound)
            let line = String(decoding: lineData, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            if !line.isEmpty { handle(line, client) }
        }
    }

    private func send(_ client: TCPClient, _ text: String) {
        client.conn.send(content: Data(text.utf8), completion: .contentProcessed { _ in })
    }

    private func sendData(_ client: TCPClient, header: String, body: Data) {
        var d = Data(header.utf8)
        d.append(body)
        client.conn.send(content: d, completion: .contentProcessed { _ in })
    }

    private func handle(_ line: String, _ client: TCPClient) {
        guard let e = engine else { return }
        let parts = line.split(separator: " ", maxSplits: 2).map(String.init)
        let cmd = parts[0].uppercased()
        switch cmd {
        case "FUNCTION":
            guard parts.count >= 2 else { send(client, "FUNCTION ER Missing function\r\n"); return }
            let q = parts.count > 2 ? APIProcessor.parseQuery(parts[2]) : [:]
            if let err = APIProcessor.perform(parts[1], q, e) {
                send(client, "FUNCTION ER \(err)\r\n")
            } else {
                send(client, "FUNCTION OK \(parts[1])\r\n")
            }
        case "XML":
            let body = Data(APIProcessor.stateXML(e).utf8)
            sendData(client, header: "XML \(body.count)\r\n", body: body)
        case "XMLTEXT":
            guard parts.count >= 2 else { send(client, "XMLTEXT ER Missing path\r\n"); return }
            let path = parts.dropFirst().joined(separator: " ")
            if let v = xmlText(path, e) { send(client, "XMLTEXT OK \(v)\r\n") } else { send(client, "XMLTEXT ER Not found\r\n") }
        case "TALLY":
            send(client, "TALLY OK \(APIProcessor.tallyString(e))\r\n")
        case "ACTS":
            guard parts.count >= 2 else { send(client, "ACTS ER Missing activator\r\n"); return }
            let n = parts.count > 2 ? Int(parts[2].trimmingCharacters(in: .whitespaces)) : nil
            send(client, acts(parts[1], n, e))
        case "SUBSCRIBE", "UNSUBSCRIBE":
            guard parts.count >= 2 else { send(client, "\(cmd) ER Missing\r\n"); return }
            let what = parts[1].uppercased()
            guard what == "TALLY" || what == "ACTS" else { send(client, "\(cmd) ER Unknown\r\n"); return }
            if cmd == "SUBSCRIBE" { client.subs.insert(what) } else { client.subs.remove(what) }
            send(client, "\(cmd) OK \(what)\r\n")
            if cmd == "SUBSCRIBE" && what == "TALLY" { send(client, "TALLY OK \(APIProcessor.tallyString(e))\r\n") }
        case "VERSION":
            send(client, "VERSION OK 27.0.0.0\r\n")
        case "QUIT":
            send(client, "QUIT OK Bye\r\n")
            client.conn.cancel()
        default:
            send(client, "\(cmd) ER Unknown command\r\n")
        }
    }

    /// Minimal XPath support for the common Companion queries, e.g. vmix/inputs/input[1]/@title
    private func xmlText(_ path: String, _ e: SwitcherEngine) -> String? {
        let p = path.lowercased().trimmingCharacters(in: .whitespaces)
        switch p {
        case "vmix/active": return String(e.number(ofID: e.programID))
        case "vmix/preview": return String(e.number(ofID: e.previewID))
        case "vmix/version": return "27.0.0.0"
        case "vmix/streaming": return e.anyRunning(kind: .stream) ? "True" : "False"
        case "vmix/recording": return e.anyRunning(kind: .record) ? "True" : "False"
        default: break
        }
        if p.hasPrefix("vmix/inputs/input["), let close = p.firstIndex(of: "]") {
            let numStr = p[p.index(p.startIndex, offsetBy: "vmix/inputs/input[".count)..<close]
            guard let n = Int(numStr), n >= 1, n <= e.inputs.count else { return nil }
            let i = e.inputs[n - 1]
            let attr = p[p.index(after: close)...]
            switch attr {
            case "/@title", "": return i.name
            case "/@key": return i.id.uuidString.lowercased()
            case "/@type": return APIProcessor.typeName(i.kind)
            case "/@muted": return i.muted ? "True" : "False"
            case "/@volume": return String(Int((i.volume * 100).rounded()))
            default: return nil
            }
        }
        return nil
    }

    private func actsValues(_ e: SwitcherEngine) -> [String: String] {
        var v: [String: String] = [:]
        for (idx, i) in e.inputs.enumerated() {
            let n = idx + 1
            v["Input \(n)"] = i.id == e.programID ? "1" : "0"
            v["InputPreview \(n)"] = i.id == e.previewID ? "1" : "0"
            v["InputAudio \(n)"] = i.muted ? "0" : "1"
            for c in 0..<SwitcherEngine.overlayCount {
                v["Overlay\(c + 1) \(n)"] = (e.overlayOn[c] && e.overlayIDs[c] == i.id) ? "1" : "0"
            }
        }
        v["Streaming"] = e.anyRunning(kind: .stream) ? "1" : "0"
        v["Recording"] = e.anyRunning(kind: .record) ? "1" : "0"
        v["External"] = (e.anyRunning(kind: .ndi) || e.anyRunning(kind: .decklink)) ? "1" : "0"
        v["FadeToBlack"] = e.ftbOn ? "1" : "0"
        return v
    }

    private func acts(_ name: String, _ n: Int?, _ e: SwitcherEngine) -> String {
        let values = actsValues(e)
        let lname = name.lowercased()
        func canonical(_ s: String) -> String? {
            ["Input", "InputPreview", "InputAudio", "Overlay1", "Overlay2", "Overlay3", "Overlay4",
             "Streaming", "Recording", "External", "FadeToBlack"].first { $0.lowercased() == s }
        }
        guard let act = canonical(lname) else { return "ACTS ER Unknown activator\r\n" }
        if ["Streaming", "Recording", "External", "FadeToBlack"].contains(act) {
            return "ACTS OK \(act) \(values[act] ?? "0")\r\n"
        }
        var num = n
        if num == nil {
            switch act {
            case "Input": num = e.number(ofID: e.programID)
            case "InputPreview": num = e.number(ofID: e.previewID)
            case let o where o.hasPrefix("Overlay"):
                let c = Int(String(o.last!))! - 1
                num = e.overlayOn[c] ? e.number(ofID: e.overlayIDs[c]) : 0
            default: num = nil
            }
        }
        guard let k = num, k >= 1 else { return "ACTS ER No Input\r\n" }
        return "ACTS OK \(act) \(k) \(values["\(act) \(k)"] ?? "0")\r\n"
    }

    /// Push tally / activator changes to subscribed clients.
    private func broadcastChanges() {
        guard let e = engine, !clients.isEmpty else {
            if let e = engine { lastActs = actsValues(e) }
            return
        }
        let tally = "TALLY OK \(APIProcessor.tallyString(e))\r\n"
        let now = actsValues(e)
        var lines = ""
        for (k, v) in now where lastActs[k] != v {
            lines += "ACTS OK \(k) \(v)\r\n"
        }
        lastActs = now
        for c in clients.values {
            if c.subs.contains("TALLY") { send(c, tally) }
            if c.subs.contains("ACTS") && !lines.isEmpty { send(c, lines) }
        }
    }
}

final class TCPClient {
    let conn: NWConnection
    var buffer = Data()
    var subs = Set<String>()
    init(conn: NWConnection) { self.conn = conn }
}
