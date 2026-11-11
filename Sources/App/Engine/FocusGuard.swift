import AppKit

/// Do Not Disturb while HongMix runs, so a call, message or notification can't take the keyboard,
/// mouse or Companion control away from the operator (or appear over an output).
///
/// macOS has no public API that lets an app switch a Focus on or off, and an app can't read the Focus
/// state without a restricted entitlement. A Shortcuts shortcut can do both, so HongMix ships one
/// ("HongMix Focus", Resources/HongMix Focus.shortcut, built by scripts/make-focus-shortcut.py) and
/// runs it with `shortcuts run`:
///   input "on" → Do Not Disturb on · "off" → off · anything else → no change; output = current Focus name.
/// The user approves the shortcut once (Shortcuts › Add). Until then HongMix asks at every launch.
final class FocusGuard: ObservableObject {
    static let shared = FocusGuard()
    static let shortcutName = "HongMix Focus"

    /// The approved shortcut is in the user's library.
    @Published private(set) var installed = false
    /// Current Focus name ("" = no Focus), nil = not known yet.
    @Published private(set) var focusName: String?
    @Published private(set) var busy = false
    var isOn: Bool { !(focusName ?? "").isEmpty }

    /// HongMix turned Do Not Disturb on (and so turns it off when it quits).
    private var turnedOnByHongMix = false
    private let queue = DispatchQueue(label: "hongmix.focus")
    private var pollTimer: Timer?
    private var installWatch: Timer?

    static let autoOnKey = "focusAutoOn"
    static let offOnQuitKey = "focusOffOnQuit"
    static let infoShownKey = "focusInfoShown"
    /// Turn Do Not Disturb on when HongMix opens (default on).
    var autoOn: Bool {
        get { UserDefaults.standard.object(forKey: Self.autoOnKey) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: Self.autoOnKey); objectWillChange.send() }
    }
    /// Turn it off again when HongMix quits — only if HongMix was the one that turned it on (default on).
    var offOnQuit: Bool {
        get { UserDefaults.standard.object(forKey: Self.offOnQuitKey) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: Self.offOnQuitKey); objectWillChange.send() }
    }

    // MARK: - Launch

    /// After the launch screen: approved → Do Not Disturb on; not approved → ask (every launch).
    func launch(done: @escaping () -> Void) {
        queue.async {
            let ok = Self.shortcutInstalled()
            let current = ok ? Self.runShortcut("status") : nil
            DispatchQueue.main.async {
                self.installed = ok
                self.focusName = current ?? (ok ? nil : "")
                self.startPolling()
                if !ok {
                    self.askApproval(done: done)
                    return
                }
                if self.autoOn && !self.isOn {
                    self.set(on: true) {
                        self.showInfoOnce()
                        // the pre-show check waits until the info sheet is answered (it is shown once ever)
                        if let w = FullscreenOutput.switcherWindow, w.attachedSheet != nil {
                            var token: NSObjectProtocol?
                            token = NotificationCenter.default.addObserver(forName: NSWindow.didEndSheetNotification, object: w, queue: .main) { _ in
                                if let t = token { NotificationCenter.default.removeObserver(t) }
                                token = nil
                                done()
                            }
                        } else { done() }
                    }
                } else {
                    done()
                }
            }
        }
    }

    /// Approval request: why HongMix needs the shortcut, and what "Approve" does.
    func askApproval(done: (() -> Void)? = nil) {
        Self.present(Self.approvalAlert()) { r in
            if r == .alertFirstButtonReturn { self.installShortcut() }
            done?()
        }
    }

    /// As a sheet on the switcher window: an app-modal alert (runModal) would stop the main queue, and with it
    /// the HTTP/TCP control API (Companion) for as long as nobody answers.
    static func present(_ a: NSAlert, done: @escaping (NSApplication.ModalResponse) -> Void) {
        if let w = FullscreenOutput.switcherWindow, w.attachedSheet == nil {
            a.beginSheetModal(for: w, completionHandler: done)
        } else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { present(a, done: done) }   // another sheet is open: wait
        }
    }

    static func approvalAlert() -> NSAlert {
        let a = NSAlert()
        a.alertStyle = .warning
        a.messageText = L("방해 금지 단축어 승인이 필요합니다")
        a.informativeText = L("방송 중에 전화, 문자, 알림 창이 뜨면 키보드, 마우스, Companion 제어가 그 창으로 넘어가 컷이나 전환이 안 될 수 있습니다. 이를 막기 위해 HongMix는 실행될 때 맥의 방해 금지를 켭니다.\n\nmacOS는 개인정보 보호를 위해 앱이 방해 금지를 직접 켜지 못하게 합니다. 그래서 처음 한 번 단축어를 승인해 주셔야 합니다. [승인]을 누른 뒤 단축어 앱에서 \"단축어 추가\"를 눌러 주세요.\n\n승인하지 않으면 HongMix를 켤 때마다 이 창이 다시 나타납니다.")
        a.addButton(withTitle: L("승인"))
        a.addButton(withTitle: L("나중에"))
        return a
    }

    /// Shown once, the first time HongMix turned Do Not Disturb on.
    private func showInfoOnce() {
        guard !UserDefaults.standard.bool(forKey: Self.infoShownKey) else { return }
        UserDefaults.standard.set(true, forKey: Self.infoShownKey)
        Self.present(Self.infoAlert()) { _ in }
    }

    static func infoAlert() -> NSAlert {
        let a = NSAlert()
        a.messageText = L("방해 금지를 켰습니다")
        a.informativeText = L("방송 중 키보드, 마우스, Companion 제어를 다른 창에 뺏기지 않도록 HongMix를 켤 때마다 방해 금지를 켭니다. HongMix를 끄면 다시 꺼지고, 오른쪽 위 '방해 금지' 버튼으로 언제든 켜고 끌 수 있습니다.\n\n반복해서 걸려 온 전화나 즐겨찾기 연락처의 전화는 방해 금지 중에도 울릴 수 있습니다. 시스템 설정 › 집중 모드 › 방해 금지에서 꺼 두거나, FaceTime › 설정에서 'iPhone에서 통화'를 꺼 두세요.")
        a.addButton(withTitle: L("확인"))
        return a
    }

    /// Opens the bundled shortcut in Shortcuts (its Add dialog), then watches for it to appear.
    func installShortcut() {
        guard let src = Bundle.main.url(forResource: Self.shortcutName, withExtension: "shortcut") else {
            NSSound.beep(); return
        }
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("\(Self.shortcutName).shortcut")
        try? FileManager.default.removeItem(at: tmp)
        try? FileManager.default.copyItem(at: src, to: tmp)
        NSWorkspace.shared.open(tmp)
        installWatch?.invalidate()
        var tries = 0
        installWatch = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] t in
            tries += 1
            guard let self = self, tries < 90 else { t.invalidate(); return }
            self.queue.async {
                guard Self.shortcutInstalled() else { return }
                DispatchQueue.main.async {
                    t.invalidate()
                    self.installed = true
                    if self.autoOn { self.set(on: true) { self.showInfoOnce() } } else { self.refresh() }
                }
            }
        }
    }

    // MARK: - On / off / state

    /// Top bar button: not approved → ask; otherwise toggle.
    func toggle() {
        guard installed else { askApproval(); return }
        set(on: !isOn)
    }

    func set(on: Bool, done: (() -> Void)? = nil) {
        guard installed else { done?(); return }
        busy = true
        queue.async {
            let name = Self.runShortcut(on ? "on" : "off")
            DispatchQueue.main.async {
                self.busy = false
                if let name = name { self.focusName = name }
                if on { self.turnedOnByHongMix = self.isOn } else { self.turnedOnByHongMix = false }
                done?()
            }
        }
    }

    func refresh() {
        guard installed, !busy else { return }
        queue.async {
            let name = Self.runShortcut("status")
            DispatchQueue.main.async { if let name = name { self.focusName = name } }
        }
    }

    private func startPolling() {
        pollTimer?.invalidate()
        // The user can switch Focus in Control Center at any time; keep the lamp honest.
        pollTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in self?.refresh() }
    }

    /// Quit: turn Do Not Disturb off again if HongMix turned it on (synchronous, max ~4 s).
    func appWillQuit() {
        pollTimer?.invalidate()
        guard installed, offOnQuit, turnedOnByHongMix else { return }
        turnedOnByHongMix = false
        _ = Self.runShortcut("off", timeout: 4)
    }

    // MARK: - shortcuts CLI

    static func shortcutInstalled() -> Bool {
        guard let out = run(["list"], timeout: 6) else { return false }
        return out.split(separator: "\n").contains { $0.trimmingCharacters(in: .whitespaces) == shortcutName }
    }

    /// Runs the shortcut with a text command; returns the current Focus name ("" = none), nil on failure.
    static func runShortcut(_ command: String, timeout: Double = 10) -> String? {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("hongmix-focus-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let input = dir.appendingPathComponent("command.txt")
        let output = dir.appendingPathComponent("focus.txt")
        guard (try? command.write(to: input, atomically: true, encoding: .utf8)) != nil else { return nil }
        guard run(["run", shortcutName, "--input-path", input.path, "--output-path", output.path], timeout: timeout) != nil else { return nil }
        let text = (try? String(contentsOf: output, encoding: .utf8)) ?? ""
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// `/usr/bin/shortcuts` with a timeout; stdout on success, nil on failure.
    @discardableResult
    private static func run(_ args: [String], timeout: Double) -> String? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/shortcuts")
        p.arguments = args
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return nil }
        // Read while it runs: a long `shortcuts list` would otherwise fill the pipe and stall.
        var data = Data()
        let reader = DispatchGroup()
        reader.enter()
        DispatchQueue.global().async {
            data = pipe.fileHandleForReading.readDataToEndOfFile()
            reader.leave()
        }
        let deadline = Date().addingTimeInterval(timeout)
        while p.isRunning && Date() < deadline { usleep(50_000) }
        if p.isRunning { p.terminate(); return nil }
        _ = reader.wait(timeout: .now() + 1)
        guard p.terminationStatus == 0 else { return nil }
        return String(data: data, encoding: .utf8) ?? ""
    }
}
