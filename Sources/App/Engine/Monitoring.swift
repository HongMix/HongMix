import Foundation
import CoreImage
import CoreVideo
import ImageIO
import UniformTypeIdentifiers

// MARK: - SRT link monitor

/// Per-link SRT history (last 2 minutes) + advice, sampled once a second.
final class SRTMonitor: ObservableObject {
    struct Link: Identifiable {
        let id: String              // "in:<uuid>" / "out:<uuid>"
        var name: String
        var sending: Bool
        var stats: SRTStats
        var rtt: [Double] = []
        var loss: [Double] = []
        var rate: [Double] = []
        var events: [String] = []
        var worstLoss: Double = 0

        /// Suggested latency: ≥ 4×RTT (SRT guideline), more when the line loses packets.
        var recommendedLatency: Int {
            let rttMax = rtt.suffix(30).max() ?? stats.rttMs
            let lossMax = loss.suffix(30).max() ?? stats.lossPercent
            var l = max(120, rttMax * 4)
            if lossMax > 0.5 { l = max(l, rttMax * 6) }
            if lossMax > 3 { l = max(l, rttMax * 10) }
            return Int((l / 10).rounded(.up) * 10)
        }
        var level: Int {   // 0 good, 1 warn, 2 bad
            if !stats.connected { return 2 }
            if stats.lossPercent > 1 || (stats.dropped > 0 && stats.lossPercent > 0.3) { return 2 }
            if stats.latencyMs > 0 && Double(stats.latencyMs) < Double(recommendedLatency) * 0.8 { return 1 }
            if stats.lossPercent > 0.2 { return 1 }
            return 0
        }
    }

    @Published private(set) var links: [Link] = []
    private var lastDropped: [String: Int64] = [:]

    func sample(_ e: SwitcherEngine, blackbox: Blackbox) {
        var now: [Link] = []
        func upd(_ id: String, _ name: String, _ s: SRTStats, sending: Bool) {
            var l = links.first { $0.id == id } ?? Link(id: id, name: name, sending: sending, stats: s)
            l.name = name; l.stats = s
            l.rtt.append(s.rttMs); l.loss.append(s.lossPercent); l.rate.append(s.rateMbps)
            if l.rtt.count > 120 { l.rtt.removeFirst(); l.loss.removeFirst(); l.rate.removeFirst() }
            let f = DateFormatter(); f.dateFormat = "HH:mm:ss"
            if s.lossPercent > 1 && l.worstLoss <= 1 {
                l.events.insert("\(f.string(from: Date()))  " + String(format: L("손실 %.2f%%"), s.lossPercent), at: 0)
                blackbox.record(.srtLoss, Lf("SRT %@: 손실 %@%%", name, String(format: "%.2f", s.lossPercent)))
            }
            let d = s.dropped - (lastDropped[id] ?? s.dropped)
            if d > 0 {
                l.events.insert("\(f.string(from: Date()))  " + Lf("드롭 %@ 패킷 (화면 깨짐 가능)", "\(d)"), at: 0)
                blackbox.record(.srtLoss, Lf("SRT %@: 드롭 %@ 패킷", name, "\(d)"))
            }
            lastDropped[id] = s.dropped
            l.worstLoss = s.lossPercent
            if l.events.count > 50 { l.events.removeLast(l.events.count - 50) }
            now.append(l)
        }
        for case let f as FFmpegInput in e.inputs { if let s = f.srtStats() { upd("in:\(f.id)", f.name, s, sending: false) } }
        for o in e.outputs where o.running { if let s = o.srtStats() { upd("out:\(o.id)", o.config.name, s, sending: true) } }
        links = now
    }
}

// MARK: - Blackbox (incident recorder)

/// When something goes wrong on air (signal loss, frame drops, silence, SRT loss, output error) this keeps a
/// record with the Output pictures from ~10 s before to ~10 s after, in ~/Movies/HongMix/Incidents.
final class Blackbox: ObservableObject {
    enum Kind: String { case signalLost, frameDrop, silence, srtLoss, outputError }
    struct Incident: Identifiable {
        let id = UUID()
        let time: Date
        let kind: Kind
        let detail: String
        var folder: String
    }

    @Published private(set) var incidents: [Incident] = []
    private var thumbs: [(Date, Data)] = []          // last ~12 s of Output thumbnails (JPEG, 1/s)
    private var pendingAfter: [(UUID, Int)] = []     // incidents still collecting "after" frames
    private let ci = CIContext()
    private let queue = DispatchQueue(label: "HongMix.blackbox", qos: .utility)
    private var lastOf: [Kind: Date] = [:]
    static var folder: String { ("~/Movies/HongMix/Incidents" as NSString).expandingTildeInPath }

    var kindLabel: (Kind) -> String = { k in
        switch k {
        case .signalLost: return L("신호 끊김")
        case .frameDrop: return L("프레임 드롭")
        case .silence: return L("무음")
        case .srtLoss: return L("SRT 손실")
        case .outputError: return L("출력 오류")
        }
    }

    /// Called every second with the current Output frame (main thread; encoding happens off-thread).
    func tick(program pb: CVPixelBuffer?) {
        guard let pb = pb else { return }
        queue.async { [weak self] in
            guard let self = self else { return }
            let img = CIImage(cvPixelBuffer: pb)
            let scale = 480 / max(1, img.extent.width)
            let small = img.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
            guard let cg = self.ci.createCGImage(small, from: small.extent) else { return }
            let data = NSMutableData()
            guard let dst = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil) else { return }
            CGImageDestinationAddImage(dst, cg, [kCGImageDestinationLossyCompressionQuality: 0.6] as CFDictionary)
            CGImageDestinationFinalize(dst)
            let now = Date()
            DispatchQueue.main.async {
                self.thumbs.append((now, data as Data))
                if self.thumbs.count > 12 { self.thumbs.removeFirst(self.thumbs.count - 12) }
                // incidents waiting for "after" pictures
                for k in self.pendingAfter.indices.reversed() {
                    let (id, left) = self.pendingAfter[k]
                    if let inc = self.incidents.first(where: { $0.id == id }) {
                        self.write(data as Data, to: inc.folder, name: String(format: "after_%02d.jpg", 11 - left))
                    }
                    if left <= 1 { self.pendingAfter.remove(at: k) } else { self.pendingAfter[k].1 = left - 1 }
                }
            }
        }
    }

    func record(_ kind: Kind, _ detail: String) {
        // the same kind of problem at most once every 10 s
        if let t = lastOf[kind], Date().timeIntervalSince(t) < 10 { return }
        let now = Date()
        lastOf[kind] = now
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        let folder = (Blackbox.folder as NSString).appendingPathComponent("\(f.string(from: now))_\(kind.rawValue)")
        try? FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        for (k, t) in thumbs.enumerated() { write(t.1, to: folder, name: String(format: "before_%02d.jpg", k + 1)) }
        let inc = Incident(time: now, kind: kind, detail: detail, folder: folder)
        incidents.insert(inc, at: 0)
        if incidents.count > 200 { incidents.removeLast() }
        pendingAfter.append((inc.id, 10))
        appendLog(inc)
    }

    private func write(_ data: Data, to folder: String, name: String) {
        try? data.write(to: URL(fileURLWithPath: (folder as NSString).appendingPathComponent(name)))
    }

    private func appendLog(_ i: Incident) {
        let path = (Blackbox.folder as NSString).appendingPathComponent("incidents.txt")
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        let line = "\(f.string(from: i.time))\t\(kindLabel(i.kind))\t\(i.detail)\t\((i.folder as NSString).lastPathComponent)\n"
        if let fh = FileHandle(forWritingAtPath: path) {
            fh.seekToEndOfFile(); fh.write(line.data(using: .utf8)!); try? fh.close()
        } else {
            try? line.write(toFile: path, atomically: true, encoding: .utf8)
        }
    }

    /// Plain-text report of this session's incidents.
    func report() -> String {
        let f = DateFormatter(); f.dateFormat = "HH:mm:ss"
        var s = L("HongMix 사고 기록") + "\n" + String(repeating: "=", count: 40) + "\n"
        if incidents.isEmpty { s += L("기록된 문제가 없습니다.") + "\n" }
        for i in incidents.reversed() {
            s += "\(f.string(from: i.time))  [\(kindLabel(i.kind))]  \(i.detail)\n    → \(i.folder)\n"
        }
        return s
    }
}
