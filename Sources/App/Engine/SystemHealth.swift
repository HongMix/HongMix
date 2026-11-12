import Foundation
import AppKit
import QuartzCore

/// Detects when macOS itself makes HongMix's window stall (a stuck system widget renderer hammering the
/// WindowServer, a background installer …) and can restart the safe system helpers.
///
/// - Symptom based: HongMix already measures its UI response delay every second. 3 stalls over 300 ms within
///   a minute → find the processes using the CPU and show the orange bar. A healthy Mac never sees it.
/// - Cleanup only restarts macOS widget helpers (launchd starts them again at once, no setting changes).
///   Other apps are listed, never closed.
/// - Optional auto cleanup for unattended 24 h shows: the same helper at most once per 30 min, logged in
///   the incident recorder. Output (stream / record / NDI) does not depend on any of this.
final class SystemHealth: ObservableObject {
    static let shared = SystemHealth()

    struct Culprit: Identifiable, Equatable {
        let pid: Int32
        let name: String
        let path: String
        let cpu: Double
        var id: Int32 { pid }
        /// macOS widget helpers: managed by launchd, restarted on demand, no state worth keeping.
        var restartable: Bool { SystemHealth.isRestartable(path: path) }
    }

    struct Alert: Equatable {
        let time: Date
        let culprits: [Culprit]
        var restartable: [Culprit] { culprits.filter { $0.restartable } }
    }

    @Published private(set) var alert: Alert?
    @Published var dismissed = false
    @Published private(set) var cleaning = false
    @Published private(set) var result: String?
    /// Latest scan for the pre-show check window.
    @Published private(set) var lastScan: [Culprit] = []

    static let autoKey = "systemAutoCleanup"
    @Published var autoCleanup = UserDefaults.standard.bool(forKey: SystemHealth.autoKey) {
        didSet { UserDefaults.standard.set(autoCleanup, forKey: Self.autoKey) }
    }

    weak var engine: SwitcherEngine?
    private let queue = DispatchQueue(label: "HongMix.systemHealth", qos: .utility)
    private var stalls: [CFTimeInterval] = []        // main thread
    private var lastScanTime: CFTimeInterval = 0
    private var lastRestart: [String: Date] = [:]
    private var measuring: (start: CFTimeInterval, stalls: Int)?

    static let stallThresholdMs = 300.0
    static let stallsPerMinute = 3

    static func isRestartable(path: String) -> Bool {
        guard path.hasPrefix("/System/") else { return false }
        let name = (path as NSString).lastPathComponent
        if name.hasPrefix("WidgetRenderer") || name == "chronod" { return true }
        return path.contains(".appex/") && name.lowercased().contains("widget")
    }

    // MARK: Symptom

    /// Main thread, once a second: the largest UI gap of the last second.
    func feed(stallMs: Double) {
        let now = CACurrentMediaTime()
        let stalled = stallMs > Self.stallThresholdMs
        if stalled { stalls.append(now) }
        stalls.removeAll { now - $0 > 60 }
        if var m = measuring {
            if stalled { m.stalls += 1 }
            measuring = m
            if now - m.start >= 10 { finishMeasure(m.stalls) }
        }
        guard stalls.count >= Self.stallsPerMinute, now - lastScanTime > 20, !cleaning else { return }
        lastScanTime = now
        scan { [weak self] culprits in
            guard let self else { return }
            self.alert = Alert(time: Date(), culprits: culprits)
            self.dismissed = false
            self.result = nil
            if self.autoCleanup { self.cleanup(auto: true) }
        }
    }

    // MARK: Processes

    /// Processes using ≥ `minCPU` % (ps, outside the main thread), heaviest first, HongMix excluded.
    func scan(minCPU: Double = 30, completion: @escaping ([Culprit]) -> Void) {
        queue.async {
            let list = Self.processes().filter { $0.cpu >= minCPU }.sorted { $0.cpu > $1.cpu }
            DispatchQueue.main.async {
                self.lastScan = list
                completion(Array(list.prefix(6)))
            }
        }
    }

    private static func processes() -> [Culprit] {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/ps")
        p.arguments = ["-Ao", "pid=,pcpu=,comm="]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return [] }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        let me = ProcessInfo.processInfo.processIdentifier
        var out: [Culprit] = []
        for line in String(decoding: data, as: UTF8.self).split(separator: "\n") {
            let parts = line.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
            guard parts.count == 3, let pid = Int32(parts[0]), let cpu = Double(parts[1]), pid != me else { continue }
            let path = String(parts[2])
            if path.hasSuffix("/ps") { continue }
            // Always busy while anything draws; they are where the load lands, not its cause.
            let base = (path as NSString).lastPathComponent
            if ["WindowServer", "kernel_task", "coreaudiod", "VTDecoderXPCService", "VTEncoderXPCService"].contains(base) { continue }
            if path.contains("/HongMix") { continue }
            out.append(Culprit(pid: pid, name: displayName(path), path: path, cpu: cpu))
        }
        return out
    }

    /// "WidgetRenderer_Activities", "Adobe … Setup" — readable without the whole path.
    static func displayName(_ path: String) -> String {
        let name = (path as NSString).lastPathComponent
        if path.contains("/Adobe/") && !name.lowercased().contains("adobe") { return "Adobe \(name)" }
        return name
    }

    static func friendly(_ c: Culprit) -> String {
        if c.name == "WidgetRenderer_Activities" { return L("실시간 현황 위젯") }
        if c.name.hasPrefix("WidgetRenderer") || c.restartable { return Lf("위젯 (%@)", c.name) }
        if c.name == "corespotlightd" || c.name == "mds_stores" || c.name == "mdworker_shared" { return L("Spotlight 색인") }
        if c.name == "syspolicyd" { return L("macOS 보안 검사") }
        if c.name == "WindowServer" { return L("화면 합성 (WindowServer)") }
        return c.name
    }

    // MARK: Cleanup

    /// Restarts the restartable helpers (manual: every widget helper using CPU; auto: only the alert's,
    /// each at most once per 30 min). Then measures stalls for 10 s and reports.
    func cleanup(auto: Bool = false) {
        guard !cleaning else { return }
        cleaning = true
        result = nil
        let minCPU: Double = auto ? 30 : 5
        queue.async {
            let targets = Self.processes().filter { $0.restartable && ($0.cpu >= minCPU || $0.name == "WidgetRenderer_Activities") }
            DispatchQueue.main.async {
                var done: [Culprit] = []
                for t in targets {
                    if auto, let last = self.lastRestart[t.name], Date().timeIntervalSince(last) < 30 * 60 { continue }
                    if kill(t.pid, SIGTERM) == 0 {
                        done.append(t)
                        self.lastRestart[t.name] = Date()
                    }
                }
                if done.isEmpty {
                    self.cleaning = false
                    self.result = auto ? nil : L("정리할 맥 위젯이 없어요 — 다른 앱이 원인이면 목록을 확인하세요.")
                    return
                }
                let names = done.map { Self.friendly($0) }.joined(separator: ", ")
                let detail = auto ? Lf("자동 정리: %@ 재시작", names) : Lf("정리: %@ 재시작", names)
                self.engine?.blackbox.record(.systemCleanup, detail)
                self.result = Lf("%@ 재시작 — 10초 동안 확인 중…", names)
                self.measuring = (CACurrentMediaTime(), 0)
            }
        }
    }

    func clearResult() { if !cleaning { result = nil } }

    private func finishMeasure(_ stallCount: Int) {
        measuring = nil
        cleaning = false
        if stallCount == 0 {
            result = L("좋아졌어요 — 10초 동안 화면 멈춤 없음")
            alert = nil
            stalls.removeAll()
            let shown = result
            DispatchQueue.main.asyncAfter(deadline: .now() + 8) { [weak self] in
                if self?.result == shown { self?.result = nil }
            }
        } else {
            result = Lf("그대로예요 — 10초 동안 %@번 멈춤. 아래 목록의 다른 프로그램을 확인하세요.", "\(stallCount)")
        }
    }
}
