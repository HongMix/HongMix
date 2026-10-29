import Foundation

/// Pre-flight check before going on air (stream / record): signal, backups, SRT, destinations,
/// disk, audio, renderer. Each item is OK / warning / problem with a one-line explanation.
struct PreflightItem: Identifiable {
    enum Level: Int { case ok = 0, warn = 1, fail = 2 }
    let id = UUID()
    var level: Level
    var title: String
    var detail: String
}

extension SwitcherEngine {
    func preflight() -> [PreflightItem] {
        var out: [PreflightItem] = []
        func add(_ l: PreflightItem.Level, _ t: String, _ d: String) { out.append(PreflightItem(level: l, title: t, detail: d)) }

        // 1. something on air
        if let p = input(withID: programID) {
            let st = p.video.stats
            if p.isLiveSource && (p.signalLost || st.fps == 0) {
                add(.fail, L("Output 화면"), Lf("%@ 신호 없음", "\(p.name)"))
            } else {
                add(.ok, L("Output 화면"), Lf("%@ 송출 준비", "\(p.name)"))
            }
        } else {
            add(.fail, L("Output 화면"), L("Output에 입력이 없습니다"))
        }

        // 2. live inputs
        let live = inputs.filter { $0.isLiveSource }
        let lost = live.filter { $0.signalLost }
        if !lost.isEmpty {
            add(.fail, L("라이브 입력 신호"), Lf("끊김: %@", lost.map { $0.name }.joined(separator: ", ")))
        } else if !live.isEmpty {
            add(.ok, L("라이브 입력 신호"), Lf("%@개 모두 정상", "\(live.count)"))
        }
        // 3. backup on the programme input
        if let p = input(withID: programID), p.isLiveSource, p.backupInputID == nil {
            add(.warn, L("백업 입력"), Lf("%@에 백업이 지정되지 않음 (속성 › 신호 끊김 / 페일오버)", "\(p.name)"))
        }

        // 4. SRT links
        for case let f as FFmpegInput in inputs {
            guard let s = f.srtStats() else { continue }
            if s.lossPercent > 1 || s.dropped > 0 && s.lossPercent > 0.3 {
                add(.fail, Lf("SRT · %@", "\(f.name)"), String(format: L("손실 %.2f%% · RTT %.0f ms — 회선 확인 필요"), s.lossPercent, s.rttMs))
            } else if s.latencyMs > 0 && s.rttMs * 4 > Double(s.latencyMs) {
                add(.warn, Lf("SRT · %@", "\(f.name)"), String(format: L("지연 %d ms < RTT×4 (%.0f ms) — Latency를 올리세요"), s.latencyMs, s.rttMs * 4))
            } else {
                add(.ok, Lf("SRT · %@", "\(f.name)"), String(format: L("RTT %.0f ms · 손실 %.2f%%"), s.rttMs, s.lossPercent))
            }
        }

        // 5. destinations
        let streams = outputs.filter { $0.config.kind == .stream }
        if streams.isEmpty {
            add(.warn, L("송출 대상"), L("Stream 출력이 설정되지 않았습니다"))
        }
        for o in streams {
            let c = o.config
            let empty = c.proto == .rtmp ? (c.rtmpServer.isEmpty || c.streamKey.isEmpty) : (c.proto == .custom ? c.customURL.isEmpty : c.srtHost.isEmpty && c.srtMode == "caller")
            add(empty ? .fail : .ok, Lf("송출 · %@", "\(c.name)"), empty ? L("서버 주소 또는 스트림 키가 비어 있음") : Lf("%@ kbps · %@", "\(c.videoKbps)", c.delaySeconds > 0 ? Lf("딜레이 %@초", "\(c.delaySeconds)") : L("실시간")))
        }

        // 6. recording disk
        let recs = outputs.filter { $0.config.kind == .record }
        let folder = ((recs.first?.config.recordFolder ?? "~/Movies") as NSString).expandingTildeInPath
        if let free = DiskSpace.freeBytes(at: folder) {
            let kbps = max(1, recs.map { $0.config.videoKbps + $0.config.audioKbps }.reduce(0, +))
            let hours = Double(free) * 8 / 1000 / Double(kbps) / 3600
            let gb = Double(free) / 1e9
            let lvl: PreflightItem.Level = gb < 5 || (!recs.isEmpty && hours < 0.25) ? .fail : (!recs.isEmpty && hours < 1 ? .warn : .ok)
            add(lvl, L("녹화 디스크"), recs.isEmpty ? String(format: L("남은 공간 %.0f GB"), gb)
                                              : String(format: L("남은 공간 %.0f GB · 약 %.1f시간 녹화 가능"), gb, hours))
        }

        // 7. audio
        let m = audioMixer.master
        let peak = max(m.0, m.1)
        let lr = audioMixer.loudness.current
        if peak < 0.003 {
            add(.warn, L("오디오"), L("Master에 소리가 없습니다 (마이크/입력 확인)"))
        } else if peak > 0.99 {
            add(.warn, L("오디오"), L("Master가 0 dBFS에 닿습니다 (클리핑)"))
        } else {
            let t = LoudnessTarget.saved.rawValue
            if lr.shortTerm.isFinite && abs(lr.shortTerm - t) > 6 {
                add(.warn, L("오디오"), String(format: L("숏텀 %.1f LUFS — 목표 %.0f에서 %.0f LU 차이"), lr.shortTerm, t, lr.shortTerm - t))
            } else {
                add(.ok, L("오디오"), lr.shortTerm.isFinite ? String(format: L("숏텀 %.1f LUFS"), lr.shortTerm) : L("소리 있음"))
            }
        }

        // 8. renderer
        let budget = 1000 / max(1, format.fps)
        if droppedTicks > 0 || renderMsPeak > budget {
            add(.warn, L("렌더러"), String(format: L("최대 %.1f ms / 예산 %.1f ms · 드롭 %d"), renderMsPeak, budget, droppedTicks))
        } else {
            add(.ok, L("렌더러"), String(format: L("평균 %.1f ms · 최대 %.1f ms"), renderMs, renderMsPeak))
        }
        if ftbOn { add(.warn, L("FTB"), L("Fade To Black이 켜져 있습니다")) }
        return out
    }
}

enum DiskSpace {
    static func freeBytes(at path: String) -> Int64? {
        var p = path
        let fm = FileManager.default
        while !fm.fileExists(atPath: p) && p != "/" { p = (p as NSString).deletingLastPathComponent }
        let url = URL(fileURLWithPath: p)
        if let v = try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]),
           let c = v.volumeAvailableCapacityForImportantUsage { return c }
        return (try? fm.attributesOfFileSystem(forPath: p)[.systemFreeSize] as? NSNumber)?.int64Value
    }
}
