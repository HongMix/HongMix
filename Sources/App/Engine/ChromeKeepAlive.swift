import Foundation
import AppKit
import Darwin

/// Chromium browsers stop painting windows they consider occluded (another Space, minimised,
/// fully covered), so a Desktop Capture of such a window freezes. Launching the browser with the
/// switches below keeps it drawing. Switches only apply when the browser process starts, hence the
/// graceful quit + relaunch (tabs come back via --restore-last-session).
enum ChromeKeepAlive {
    struct Browser: Equatable {
        let bundleID: String
        let name: String
    }

    /// Chromium-based browsers we know how to relaunch, in priority order.
    static let browsers = [
        Browser(bundleID: "com.google.Chrome", name: "Google Chrome"),
        Browser(bundleID: "com.microsoft.edgemac", name: "Microsoft Edge"),
        Browser(bundleID: "com.brave.Browser", name: "Brave Browser"),
    ]

    /// The switches that keep hidden windows painting.
    static let keepDrawingFlags = [
        "--disable-backgrounding-occluded-windows",
        "--disable-renderer-backgrounding",
        "--disable-background-timer-throttling",
    ]

    enum Result: Equatable {
        case alreadyKeepsDrawing(String)      // browser name
        case relaunched(String)
        case launched(String)                 // wasn't running: started with the switches
        case notInstalled
        case quitTimedOut(String)
        case launchFailed(String, String)     // name, reason
        case flagsNotApplied(String)

        var succeeded: Bool {
            switch self {
            case .alreadyKeepsDrawing, .relaunched, .launched: return true
            default: return false
            }
        }

        /// Localised, user-facing.
        var message: String {
            switch self {
            case .alreadyKeepsDrawing(let n): return Lf("%@: 이미 가려진 창도 계속 그리도록 실행 중입니다", n)
            case .relaunched(let n): return Lf("%@: 가려진 창도 계속 그리도록 다시 실행했습니다 (탭은 복원됨)", n)
            case .launched(let n): return Lf("%@: 가려진 창도 계속 그리도록 실행했습니다", n)
            case .notInstalled: return L("Chrome, Edge, Brave가 설치되어 있지 않습니다")
            case .quitTimedOut(let n): return Lf("%@: 10초 안에 종료되지 않았습니다 — 브라우저에 확인 창이 열려 있으면 닫고 다시 시도하세요", n)
            case .launchFailed(let n, let why): return Lf("%@ 다시 실행 실패: %@", n, why)
            case .flagsNotApplied(let n): return Lf("%@: 다시 실행됐지만 옵션이 적용되지 않았습니다 — 브라우저를 완전히 종료한 뒤 다시 시도하세요", n)
            }
        }
    }

    // MARK: Detection

    static func browser(bundleID: String) -> Browser? { browsers.first { $0.bundleID == bundleID } }

    /// True when every keep-drawing switch is present. Chromium accepts "--x", "-x" and "--x=value".
    static func hasKeepDrawingFlags(_ args: [String]) -> Bool {
        let present = Set(args.map { a -> String in
            var s = Substring(a)
            while s.hasPrefix("-") { s = s.dropFirst() }
            if let eq = s.firstIndex(of: "=") { s = s[..<eq] }
            return String(s).lowercased()
        })
        return keepDrawingFlags.allSatisfy { present.contains(String($0.drop(while: { $0 == "-" }))) }
    }

    /// The main browser process (helpers have their own bundle IDs) of a supported browser.
    static func runningApp(_ b: Browser) -> NSRunningApplication? {
        NSRunningApplication.runningApplications(withBundleIdentifier: b.bundleID).first { !$0.isTerminated }
    }

    /// A supported browser is running without the keep-drawing switches (UI: show "Relaunch Chrome").
    static func isRunningWithoutFlags() -> Bool {
        browsers.contains { needsRelaunch(bundleID: $0.bundleID) }
    }

    /// This browser is running and its main process lacks the switches. Unknown arguments
    /// (process not readable) count as "needs relaunch" so the operator still gets the fix.
    static func needsRelaunch(bundleID: String) -> Bool {
        guard let b = browser(bundleID: bundleID), let app = runningApp(b) else { return false }
        guard let args = arguments(pid: app.processIdentifier) else { return true }
        return !hasKeepDrawingFlags(args)
    }

    /// argv of a process via sysctl KERN_PROCARGS2 (same user only), `ps` as fallback.
    static func arguments(pid: pid_t) -> [String]? {
        var mib: [Int32] = [CTL_KERN, KERN_ARGMAX]
        var argmax: Int32 = 0
        var size = MemoryLayout<Int32>.size
        if sysctl(&mib, 2, &argmax, &size, nil, 0) == 0, argmax > 0 {
            var buf = [UInt8](repeating: 0, count: Int(argmax))
            mib = [CTL_KERN, KERN_PROCARGS2, pid]
            size = buf.count
            if sysctl(&mib, 3, &buf, &size, nil, 0) == 0, let a = parseProcArgs2(Array(buf[0..<size])) {
                return a
            }
        }
        return psArguments(pid: pid)
    }

    /// KERN_PROCARGS2 layout: int32 argc, exec path, NUL padding, argc NUL-terminated args, env…
    static func parseProcArgs2(_ bytes: [UInt8]) -> [String]? {
        guard bytes.count > 4 else { return nil }
        let argc = Int(bytes.withUnsafeBytes { $0.loadUnaligned(as: Int32.self) })
        guard argc > 0 else { return nil }
        var i = 4
        while i < bytes.count, bytes[i] != 0 { i += 1 }        // exec path
        while i < bytes.count, bytes[i] == 0 { i += 1 }        // padding
        var args: [String] = []
        while args.count < argc, i < bytes.count {
            let start = i
            while i < bytes.count, bytes[i] != 0 { i += 1 }
            args.append(String(decoding: bytes[start..<i], as: UTF8.self))
            i += 1
        }
        return args.count == argc ? args : nil
    }

    /// `ps` joins argv with spaces; enough to look for the switches.
    private static func psArguments(pid: pid_t) -> [String]? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/ps")
        p.arguments = ["-o", "args=", "-p", "\(pid)"]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        guard p.terminationStatus == 0, let s = String(data: data, encoding: .utf8) else { return nil }
        let parts = s.split(whereSeparator: { $0 == " " || $0 == "\n" }).map(String.init)
        return parts.isEmpty ? nil : parts
    }

    // MARK: Relaunch

    /// Quits the browser gracefully and starts it again with the keep-drawing switches.
    /// `bundleID` nil = the first supported browser that is running without them (else the first
    /// installed one). Never force-quits: if the browser doesn't quit within ~10 s (e.g. it asks
    /// to confirm), it stays open and `.quitTimedOut` is returned. Completion runs on main.
    static func relaunch(bundleID: String? = nil, completion: @escaping (Result) -> Void) {
        DispatchQueue.main.async {
            let installed = browsers.filter { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0.bundleID) != nil }
            let target: Browser?
            if let id = bundleID {
                target = installed.first { $0.bundleID == id }
            } else {
                target = installed.first { needsRelaunch(bundleID: $0.bundleID) }
                    ?? installed.first { runningApp($0) != nil }
                    ?? installed.first
            }
            guard let b = target, let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: b.bundleID) else {
                completion(.notInstalled)
                return
            }
            guard let app = runningApp(b) else {
                launch(b, url: url, restore: false, completion: completion)
                return
            }
            if let args = arguments(pid: app.processIdentifier), hasKeepDrawingFlags(args) {
                completion(.alreadyKeepsDrawing(b.name))
                return
            }
            _ = app.terminate()
            waitForQuit(app, deadline: Date().addingTimeInterval(10)) { quit in
                guard quit else { completion(.quitTimedOut(b.name)); return }
                // Give the old process a moment to release its profile lock, or the new one
                // would hand our switches to the dying instance and exit.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) {
                    launch(b, url: url, restore: true, completion: completion)
                }
            }
        }
    }

    private static func waitForQuit(_ app: NSRunningApplication, deadline: Date, _ done: @escaping (Bool) -> Void) {
        if app.isTerminated { done(true); return }
        if Date() >= deadline { done(false); return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { waitForQuit(app, deadline: deadline, done) }
    }

    private static func launch(_ b: Browser, url: URL, restore: Bool, completion: @escaping (Result) -> Void) {
        let cfg = NSWorkspace.OpenConfiguration()
        cfg.arguments = keepDrawingFlags + (restore ? ["--restore-last-session"] : [])
        cfg.activates = false                 // keep HongMix in front during a show
        cfg.createsNewApplicationInstance = false
        NSWorkspace.shared.openApplication(at: url, configuration: cfg) { app, error in
            DispatchQueue.main.async {
                if let error = error {
                    completion(.launchFailed(b.name, error.localizedDescription))
                    return
                }
                // Arguments are ignored when an instance was still running; check the new process.
                if let app = app, let args = arguments(pid: app.processIdentifier), !hasKeepDrawingFlags(args) {
                    completion(.flagsNotApplied(b.name))
                    return
                }
                completion(restore ? .relaunched(b.name) : .launched(b.name))
            }
        }
    }
}
