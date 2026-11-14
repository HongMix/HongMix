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
        /// packets dropped (not recovered in time) per sample, last 2 minutes
        var drops: [Int64] = []
        /// libsrt receive / send buffer (ms) and, for inputs, the frames HongMix took per second
        var buffer: [Int] = []
        var latency: [Int] = []
        /// cumulative retransmitted packets per sample (deltas tell whether the sender resends)
        var retrans: [Int64] = []
        var fps: [Double] = []
        var times: [Date] = []
        /// last figures while connected (a disconnect zeroes the live ones)
        var lastGood: SRTStats?
        var events: [String] = []
        var worstLoss: Double = 0

        /// Suggested latency: ≥ 4×RTT (SRT guideline), more when the line loses packets.
        var recommendedLatency: Int {
            let rttMax = rtt.suffix(30).max() ?? stats.rttMs
            let lossMax = loss.suffix(30).max() ?? stats.lossPercent
            var l = max(120, rttMax * 4)
            if lossMax > 0.5 { l = max(l, rttMax * 6) }
            if lossMax > 3 { l = max(l, rttMax * 10) }
            // packets were dropped at the current latency: it is too short for this link, whatever the
            // RTT says (the sender may be further away than the address we reach, or lose in bursts)
            if recentDrops > 0 { l = max(l, Double(stats.latencyMs) * 2, rttMax * 8) }
            return min(8000, Int((l / 10).rounded(.up) * 10))
        }
        /// dropped packets in the last 30 s
        var recentDrops: Int64 { drops.suffix(30).reduce(0, +) }
        /// retransmitted packets in the last 30 s
        var recentRetrans: Int64 {
            guard let last = retrans.last, let first = retrans.suffix(31).first else { return 0 }
            return max(0, last - first)
        }

        /// Likely cause from the numbers at this moment (written into the blackbox with every SRT incident).
        var verdict: String {
            let lat = stats.latencyMs
            if !stats.connected { return L("연결 끊김 — 보내는 쪽이나 네트워크가 연결을 닫음") }
            if stats.rateMbps < 0.05 { return L("데이터가 안 들어옴 — 보내는 쪽이 멈췄거나 경로가 막힘") }
            if !sending, lat > 0, stats.bufferMs > lat + max(1000, lat) {
                return L("HongMix가 늦게 읽음 — 수신 버퍼가 Latency보다 크게 쌓임 (HongMix 문제)")
            }
            let rttMax = rtt.suffix(30).max() ?? stats.rttMs
            // RTT too long for the latency: retransmissions can't arrive in time
            if lat > 0, rttMax * 4 > Double(lat) {
                return L("회선 문제 — RTT·손실에 비해 Latency가 짧음 (Latency를 올리세요)")
            }
            // Packets missing although there was time to resend them: the sender didn't (it dropped them —
            // bandwidth limit, overload, its own buffer) — retransmissions stayed at 0 or far below the loss.
            if recentDrops > 0 && recentRetrans * 4 < recentDrops {
                return L("보내는 쪽 드롭 — 재전송 없이 패킷이 빠짐 (송신기 대역폭 제한·과부하·설정 확인)")
            }
            if recentDrops > 0 {
                return L("회선 손실 — 재전송으로도 다 못 살림 (회선 상태 확인, Latency를 올리면 도움)")
            }
            if stats.lossPercent > 1 { return L("회선 손실 — 재전송으로 복구 중 (아직 화면 영향 없음)") }
            return L("뚜렷한 원인 없음 — 첨부된 기록 참조")
        }

        /// One line with the numbers that matter (just before a disconnect, if it is one).
        var snapshot: String {
            let st = stats.connected ? stats : (lastGood ?? stats)
            return (stats.connected ? "" : L("끊기기 직전") + ": ")
                + String(format: "buffer %d ms / latency %d ms · RTT %.1f ms · loss %.2f%% · drops %lld (30 s) · %.2f Mbps",
                         st.bufferMs, st.latencyMs, st.rttMs, st.lossPercent, recentDrops, st.rateMbps)
                + (fps.last.map { String(format: " · %.1f fps", $0) } ?? "")
        }

        /// Per-second history (last 30 s) for the incident folder.
        var historyText: String {
            let f = DateFormatter(); f.dateFormat = "HH:mm:ss"
            var t = "\(sending ? "SEND" : "RECEIVE") \(name) · mode \(stats.mode)\n\(L("판정")): \(verdict)\n\(snapshot)\n\n"
            t += "time      buffer_ms latency_ms rtt_ms loss_% drops retrans mbps fps\n"
            let n = min(30, times.count)
            for k in (times.count - n)..<times.count {
                let fv = k < fps.count ? String(format: "%.1f", fps[k]) : "-"
                let rt = k > 0 && k < retrans.count ? max(0, retrans[k] - retrans[k - 1]) : 0
                t += String(format: "%@ %9d %10d %6.1f %6.2f %5lld %7lld %5.2f %@\n", f.string(from: times[k]),
                            k < buffer.count ? buffer[k] : 0, k < latency.count ? latency[k] : 0, rtt[k], loss[k], drops[k], rt, rate[k], fv)
            }
            return t
        }
        var level: Int {   // 0 good, 1 warn, 2 bad
            if !stats.connected { return 2 }
            if stats.lossPercent > 1 || (stats.dropped > 0 && stats.lossPercent > 0.3) || recentDrops > 0 { return 2 }
            if stats.latencyMs > 0 && Double(stats.latencyMs) < Double(recommendedLatency) * 0.8 { return 1 }
            if stats.lossPercent > 0.2 { return 1 }
            return 0
        }
    }

    @Published private(set) var links: [Link] = []
    private var lastDropped: [String: Int64] = [:]

    func sample(_ e: SwitcherEngine, blackbox: Blackbox) {
        var now: [Link] = []
        func upd(_ id: String, _ name: String, _ s: SRTStats, sending: Bool, fps: Double? = nil) {
            var l = links.first { $0.id == id } ?? Link(id: id, name: name, sending: sending, stats: s)
            l.name = name; l.stats = s
            l.rtt.append(s.rttMs); l.loss.append(s.lossPercent); l.rate.append(s.rateMbps)
            if l.rtt.count > 120 { l.rtt.removeFirst(); l.loss.removeFirst(); l.rate.removeFirst() }
            l.drops.append(max(0, s.dropped - (lastDropped[id] ?? s.dropped)))
            if l.drops.count > 120 { l.drops.removeFirst() }
            l.buffer.append(s.bufferMs); l.latency.append(s.latencyMs); l.retrans.append(s.retransmitted); l.times.append(Date())
            if l.retrans.count > 120 { l.retrans.removeFirst() }
            if s.connected { l.lastGood = s }
            if l.latency.count > 120 { l.latency.removeFirst() }
            if let fps { l.fps.append(fps) }
            if l.buffer.count > 120 { l.buffer.removeFirst(); l.times.removeFirst() }
            if l.fps.count > 120 { l.fps.removeFirst() }
            let f = DateFormatter(); f.dateFormat = "HH:mm:ss"
            if s.lossPercent > 1 && l.worstLoss <= 1 {
                l.events.insert("\(f.string(from: Date()))  " + String(format: L("손실 %.2f%%"), s.lossPercent), at: 0)
                blackbox.record(.srtLoss, Lf("SRT %@: 손실 %@%%", name, String(format: "%.2f", s.lossPercent))
                                + " · " + l.snapshot + " · " + l.verdict, attachment: ("srt.txt", l.historyText))
            }
            let d = s.dropped - (lastDropped[id] ?? s.dropped)
            if d > 0 {
                l.events.insert("\(f.string(from: Date()))  " + Lf("드롭 %@ 패킷 (화면 깨짐 가능)", "\(d)"), at: 0)
                l.drops[l.drops.count - 1] = d     // make this sample's drops visible in the snapshot
                blackbox.record(.srtLoss, Lf("SRT %@: 드롭 %@ 패킷", name, "\(d)")
                                + " · " + l.snapshot + " · " + l.verdict, attachment: ("srt.txt", l.historyText))
            }
            lastDropped[id] = s.dropped
            l.worstLoss = s.lossPercent
            if l.events.count > 50 { l.events.removeLast(l.events.count - 50) }
            now.append(l)
        }
        for case let f as FFmpegInput in e.inputs {
            if let s = f.srtStats() { upd("in:\(f.id)", f.name, s, sending: false, fps: f.video.stats.updateFPS) }
        }
        for o in e.outputs where o.running { if let s = o.srtStats() { upd("out:\(o.id)", o.config.name, s, sending: true) } }
        links = now
    }
}

// MARK: - Blackbox (incident recorder)

/// When something goes wrong on air (signal loss, frame drops, silence, SRT loss, output error) this keeps a
/// record with the Output pictures from ~10 s before to ~10 s after, in ~/Movies/HongMix/Incidents.
final class Blackbox: ObservableObject {
    enum Kind: String { case signalLost, frameDrop, silence, srtLoss, outputError, systemSleep, systemCleanup }
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
        case .systemSleep: return L("맥 잠자기")
        case .systemCleanup: return L("맥 정리")
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

    /// `attachment`: a text file written into the incident folder (e.g. "srt.txt" — the link's last 30 s).
    func record(_ kind: Kind, _ detail: String, attachment: (String, String)? = nil) {
        // the same kind of problem at most once every 10 s
        if let t = lastOf[kind], Date().timeIntervalSince(t) < 10 { return }
        let now = Date()
        lastOf[kind] = now
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        let folder = (Blackbox.folder as NSString).appendingPathComponent("\(f.string(from: now))_\(kind.rawValue)")
        try? FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        for (k, t) in thumbs.enumerated() { write(t.1, to: folder, name: String(format: "before_%02d.jpg", k + 1)) }
        if let (name, text) = attachment, let d = text.data(using: .utf8) { write(d, to: folder, name: name) }
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
