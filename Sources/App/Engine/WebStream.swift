import Foundation
import Network
import CoreImage
import CoreVideo
import QuartzCore

/// Live PREVIEW / PROGRAM pictures for the web remote: `GET /stream.mjpg?source=program|preview&fps=&w=`
/// (multipart/x-mixed-replace — plays in an <img> on iPhone/iPad Safari, Chrome, Edge, Android).
///
/// One encoder per (source, fps, width): a frame is grabbed and JPEG-encoded once and sent to every
/// viewer of that feed. Encoders exist only while someone watches. A viewer that hasn't received the
/// previous frame yet (slow Wi-Fi) skips frames instead of queueing them, so latency stays low and
/// HongMix never buffers for a slow phone. Encoding runs on its own queue, never on the main thread.
final class WebStreamHub {
    static let shared = WebStreamHub()
    weak var engine: SwitcherEngine?

    private let queue = DispatchQueue(label: "HongMix.webstream", qos: .utility)
    private let ci = CIContext(options: [.cacheIntermediates: false])
    private static let boundary = "hmframe"

    private final class Viewer {
        let conn: NWConnection
        var busy = false
        var busySince: CFTimeInterval = 0        // a phone that left Wi-Fi without closing: dropped after 8 s
        init(_ c: NWConnection) { conn = c }
    }
    private final class Feed {
        let source: String, fps: Int, width: Int
        var viewers: [ObjectIdentifier: Viewer] = [:]
        var timer: DispatchSourceTimer?
        var encoding = false
        init(source: String, fps: Int, width: Int) { self.source = source; self.fps = fps; self.width = width }
        var key: String { "\(source)|\(fps)|\(width)" }
    }
    private var feeds: [String: Feed] = [:]       // queue

    /// Viewers right now (for the stats line / tests).
    var viewerCount: Int { queue.sync { feeds.values.reduce(0) { $0 + $1.viewers.count } } }

    /// Takes over an accepted HTTP connection and streams to it until the viewer goes away.
    /// The page's presets only (any other value is snapped to the nearest), so a LAN client can't create
    /// thousands of distinct encoders; at most `maxViewers` streams at once.
    static let fpsSteps = [2, 8, 15], widthSteps = [320, 400, 480, 640, 854]
    static let maxViewers = 16
    private static func snap(_ v: Int, _ steps: [Int]) -> Int { steps.min { abs($0 - v) < abs($1 - v) } ?? steps[0] }

    func attach(_ conn: NWConnection, query q: [String: String]) {
        let source = (q["source"] ?? "program").lowercased() == "preview" ? "preview" : "program"
        let fps = Self.snap(Int(q["fps"] ?? "") ?? 8, Self.fpsSteps)
        let width = Self.snap(Int(q["w"] ?? q["width"] ?? "") ?? 640, Self.widthSteps)
        let head = "HTTP/1.1 200 OK\r\nContent-Type: multipart/x-mixed-replace; boundary=\(Self.boundary)\r\n"
            + "Cache-Control: no-store, no-cache\r\nPragma: no-cache\r\nConnection: close\r\n\r\n"
        queue.async {
            let total = self.feeds.values.reduce(0) { $0 + $1.viewers.count }
            guard self.engine != nil, total < Self.maxViewers else {
                let body = "too many viewers"
                conn.send(content: Data("HTTP/1.1 503 Service Unavailable\r\nContent-Type: text/plain\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n\(body)".utf8),
                          completion: .contentProcessed { _ in conn.cancel() })
                return
            }
            let key = "\(source)|\(fps)|\(width)"
            let feed = self.feeds[key] ?? Feed(source: source, fps: fps, width: width)
            self.feeds[key] = feed
            let v = Viewer(conn)
            feed.viewers[ObjectIdentifier(v)] = v
            conn.stateUpdateHandler = { [weak self] st in
                switch st {
                case .failed, .cancelled: self?.queue.async { self?.drop(v, from: key) }
                default: break
                }
            }
            conn.send(content: Data(head.utf8), completion: .contentProcessed { [weak self] err in
                if err != nil { conn.cancel(); self?.queue.async { self?.drop(v, from: key) } }
            })
            self.watchClose(v, key)
            self.start(feed)
        }
    }

    /// The browser closing the tab or switching the picture off ends the TCP connection: notice it.
    private func watchClose(_ v: Viewer, _ key: String) {
        v.conn.receive(minimumIncompleteLength: 1, maximumLength: 1024) { [weak self] _, _, done, err in
            if done || err != nil { v.conn.cancel(); self?.queue.async { self?.drop(v, from: key) } }
            else { self?.watchClose(v, key) }
        }
    }

    private func drop(_ v: Viewer, from key: String) {
        guard let f = feeds[key], f.viewers.removeValue(forKey: ObjectIdentifier(v)) != nil else { return }
        if f.viewers.isEmpty {
            f.timer?.cancel(); f.timer = nil
            feeds[key] = nil
        }
    }

    private func start(_ f: Feed) {
        guard f.timer == nil else { return }
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now(), repeating: .milliseconds(1000 / f.fps), leeway: .milliseconds(5))
        t.setEventHandler { [weak self] in self?.tick(f) }
        f.timer = t
        t.resume()
    }

    private func tick(_ f: Feed) {
        let now = CACurrentMediaTime()
        for v in f.viewers.values where v.busy && now - v.busySince > 8 {
            v.conn.forceCancel(); drop(v, from: f.key)     // stuck: gone without closing — close now, don't wait to flush
        }
        guard !f.encoding, !f.viewers.isEmpty, engine != nil else { return }
        // nobody ready for a new frame (all still receiving the last one) → skip this tick
        guard f.viewers.values.contains(where: { !$0.busy }) else { return }
        f.encoding = true
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            let pb = self.engine.flatMap { WebRemote.thumbBuffer(["source": f.source], $0) }
            self.queue.async {
                defer { f.encoding = false }
                guard let pb = pb, let jpg = self.jpeg(pb, width: f.width) else { return }
                var part = Data("--\(Self.boundary)\r\nContent-Type: image/jpeg\r\nContent-Length: \(jpg.count)\r\n\r\n".utf8)
                part.append(jpg)
                part.append(Data("\r\n".utf8))
                for v in f.viewers.values where !v.busy {
                    v.busy = true
                    v.busySince = CACurrentMediaTime()
                    v.conn.send(content: part, completion: .contentProcessed { [weak self] err in
                        self?.queue.async {
                            v.busy = false
                            if err != nil { v.conn.forceCancel(); self?.drop(v, from: f.key) }
                        }
                    })
                }
            }
        }
    }

    private func jpeg(_ pb: CVPixelBuffer, width: Int) -> Data? {
        let img = CIImage(cvPixelBuffer: pb)
        let scale = min(1, CGFloat(width) / max(1, img.extent.width))
        let small = scale < 1 ? img.transformed(by: CGAffineTransform(scaleX: scale, y: scale)) : img
        guard let cs = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        let quality: CGFloat = width >= 900 ? 0.62 : width >= 600 ? 0.58 : 0.5
        return ci.jpegRepresentation(of: small, colorSpace: cs,
                                     options: [kCGImageDestinationLossyCompressionQuality as CIImageRepresentationOption: quality])
    }
}
