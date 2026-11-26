import AppKit
import SwiftUI

/// Crash safety net (Settings › General). "Backstage" is this same program in its own little bundle
/// (Contents/Helpers/HongMix Backstage.app, own bundle id — so macOS never mistakes it for HongMix and a click
/// on the HongMix icon still opens HongMix), started with `--backstage`: no engine, no Dock icon. It draws the Talent Display on the monitors that show it (in a window just above HongMix's
/// own), serves the moderator link on port 8089, and restarts HongMix when it goes away without quitting.
/// Talent state is shared through TalentCue's live file, so if HongMix crashes the presenter sees nothing
/// change: the timer keeps running and the moderator can keep sending messages.
enum Backstage {
    static let flag = "--backstage"
    static let port: UInt16 = 8089
    static let enabledKey = "backstageEnabled"
    static var enabled: Bool { UserDefaults.standard.object(forKey: enabledKey) as? Bool ?? true }

    static let bundleID = "com.hongseunghoon.HongMix.backstage"
    static let mainBundleID = "com.hongseunghoon.HongMix"

    private static var dir: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("HongMix")
    }
    static var pidURL: URL { dir.appendingPathComponent("backstage.pid") }
    /// Written only by HongMix: its pid and the monitors showing the Talent Display.
    static var mainURL: URL { dir.appendingPathComponent("backstage-main.json") }
    struct MainInfo: Codable, Equatable { var pid: Int32; var screens: [String] }

    /// The helper bundle inside HongMix.app (nil when not built, e.g. an Xcode build).
    static var helperExecutable: URL? {
        let u = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/HongMix Backstage.app/Contents/MacOS/HongMix Backstage")
        return FileManager.default.isExecutableFile(atPath: u.path) ? u : nil
    }

    private static var controller: BackstageController?

    /// Entry point of the Backstage process.
    static func run() {
        UserDefaults.standard.addSuite(named: mainBundleID)    // read HongMix's settings (language, remote control, token)
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let c = BackstageController()
        controller = c
        c.start()
        app.run()
    }
}

/// Backstage process: Talent windows, moderator link, HongMix watchdog.
private final class BackstageController {
    private let cue = TalentCue.shared
    private var main = Backstage.MainInfo(pid: 0, screens: [])
    private let http = HTTPAPIServer()          // engine nil: only the Talent paths answer
    private var windows: [String: NSWindow] = [:]
    private var watchedPID: Int32 = 0
    private var exitSource: DispatchSourceProcess?
    private var budget = RelaunchBudget()
    private var tick: Timer?

    func start() {
        try? "\(getpid())".write(to: Backstage.pidURL, atomically: true, encoding: .utf8)
        signal(SIGTERM, SIG_DFL)
        let t = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in self?.reconcile() }
        RunLoop.main.add(t, forMode: .common)
        tick = t
        reconcile()
    }

    private func reconcile() {
        // moderator link (follows Settings › Network › Remote control)
        if APIAccess.enabled && !http.isRunning { _ = http.start(port: Backstage.port) }
        if !APIAccess.enabled && http.isRunning { http.stop() }
        if let d = try? Data(contentsOf: Backstage.mainURL), let m = try? JSONDecoder().decode(Backstage.MainInfo.self, from: d) { main = m }
        // Talent windows on the monitors HongMix says show the Talent Display
        let wanted = Set(main.screens)
        for (k, w) in windows where !wanted.contains(k) || MonitorIdentity.screen(forKey: k) == nil {
            w.orderOut(nil); w.close(); windows[k] = nil
        }
        for k in wanted where windows[k] == nil {
            guard let s = MonitorIdentity.screen(forKey: k) else { continue }
            let w = NSWindow(contentRect: s.frame, styleMask: [.borderless], backing: .buffered, defer: false, screen: s)
            w.level = NSWindow.Level(rawValue: NSWindow.Level.screenSaver.rawValue + 1)   // just above HongMix's own
            w.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
            w.isOpaque = true
            w.backgroundColor = .black
            w.ignoresMouseEvents = true
            w.isReleasedWhenClosed = false
            w.contentView = NSHostingView(rootView: TalentDisplayView(cue: cue).ignoresSafeArea())
            w.setFrame(s.frame, display: true)
            w.orderFrontRegardless()
            windows[k] = w
        }
        for (k, w) in windows { if let s = MonitorIdentity.screen(forKey: k), w.frame != s.frame { w.setFrame(s.frame, display: true) } }
        // watch the HongMix that wrote its pid last
        if main.pid != 0 && main.pid != watchedPID { watch(main.pid) }
    }

    private func watch(_ pid: Int32) {
        watchedPID = pid
        exitSource?.cancel()
        guard kill(pid, 0) == 0 else { mainGone(); return }
        let src = DispatchSource.makeProcessSource(identifier: pid_t(pid), eventMask: .exit, queue: .main)
        src.setEventHandler { [weak self] in self?.mainGone() }
        src.resume()
        exitSource = src
    }

    /// HongMix quits normally by stopping Backstage first (SIGTERM), so reaching this means it crashed or was killed.
    private func mainGone() {
        exitSource?.cancel()
        exitSource = nil
        guard budget.allow(at: Date()) else { return }       // keep the Talent screen; stop restarting
        // HongMix.app is three folders up: …/HongMix.app/Contents/Helpers/HongMix Backstage.app
        let app = Bundle.main.bundleURL.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
            let c = NSWorkspace.OpenConfiguration()
            c.activates = true
            NSWorkspace.shared.openApplication(at: app, configuration: c)
        }
    }
}

/// HongMix side: start (or adopt) Backstage, tell it who to watch, stop it on a normal quit.
enum BackstageLink {
    private static var pid: Int32 = 0

    static var running: Bool { pid != 0 && kill(pid, 0) == 0 }

    /// Main thread, after launch and when the setting changes.
    private static var info = Backstage.MainInfo(pid: getpid(), screens: [])

    /// DisplayMap: the monitors showing the Talent Display.
    static func setScreens(_ keys: [String]) {
        guard keys != info.screens else { return }
        info.screens = keys
        writeInfo()
    }

    private static func writeInfo() {
        if let d = try? JSONEncoder().encode(info) { try? d.write(to: Backstage.mainURL, options: .atomic) }
    }

    static func start() {
        _ = TalentCue.shared        // starts sharing the Talent state
        info.pid = getpid()
        writeInfo()
        guard Backstage.enabled else { stop(); return }
        if let s = try? String(contentsOf: Backstage.pidURL, encoding: .utf8), let p = Int32(s.trimmingCharacters(in: .whitespacesAndNewlines)),
           kill(p, 0) == 0, NSRunningApplication(processIdentifier: p)?.bundleIdentifier == Backstage.bundleID {
            pid = p                // still running from before a crash: keep it (the Talent screen never went away)
            return
        }
        guard let exe = Backstage.helperExecutable else { return }
        let proc = Process()
        proc.executableURL = exe
        proc.arguments = [Backstage.flag]
        proc.standardOutput = FileHandle.nullDevice
        proc.standardError = FileHandle.nullDevice
        do { try proc.run(); pid = proc.processIdentifier } catch { pid = 0 }
    }

    /// Normal quit or setting off.
    static func stop() {
        if running { kill(pid, SIGTERM) }
        pid = 0
        try? FileManager.default.removeItem(at: Backstage.pidURL)
    }
}
