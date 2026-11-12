import SwiftUI
import AppKit
import UniformTypeIdentifiers

@main
struct HongMixApp: App {
    /// Must run before anything reads UserDefaults (first stored property).
    private let migrated: Bool = {
        let r = DefaultsMigration.run()
        DefaultsMigration.migrateFolders()
        return r
    }()
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var engine = SwitcherEngine()
    /// Changing the language rebuilds the window contents (engine and inputs keep running).
    @AppStorage(AppLanguage.defaultsKey) private var language = AppLanguage.current.rawValue
    /// Changing the skin rebuilds every window too, so Replay/Scopes/Statistics/Settings repaint.
    @AppStorage(AppSkin.defaultsKey) private var skin = AppSkin.current.rawValue

    var body: some Scene {
        let _ = AppSkin.sync(skin)
        Window("HongMix", id: "main") {
            ZStack {
                ContentView().id(language + skin)
                LaunchOverlay()
            }
                .environmentObject(engine)
                .frame(minWidth: 1280, minHeight: 780)
                .preferredColorScheme(.dark)
                .onAppear {
                    appDelegate.engine = engine
                    ProjectIO.engineRef = engine
                    mc_ndi_set_extra_ips(UserDefaults.standard.string(forKey: "ndiExtraIPs") ?? "")
                    engine.startEngine()
                    ProjectIO.restoreLastSession(into: engine)
                    ProjectIO.startAutosave(engine)
                    LaunchModel.shared.onFinished = { [engine] in AfterLaunch.run(engine) }
                    LaunchModel.shared.run(engine: engine)
                }
        }
        .commands {
            CommandGroup(replacing: .newItem) {
                Button(L("새 프로젝트")) { ProjectIO.newProject(engine) }
                    .keyboardShortcut("n")
                Button(L("프로젝트 열기…")) { ProjectIO.open(into: engine) }
                    .keyboardShortcut("o")
            }
            CommandGroup(replacing: .saveItem) {
                Button(L("프로젝트 저장…")) { ProjectIO.save(engine) }
                    .keyboardShortcut("s")
                Divider()
                // ⌘W itself is handled in AppDelegate's key monitor (also reaches sheets with a focused text field).
                Button(L("창 닫기")) { WindowCloser.closeFront() }
                    .keyboardShortcut("w")
            }
            CommandGroup(after: .appInfo) {
                Button(L("시작 전 점검…")) { StartupCheckWindow.show(engine: engine) }
            }
            CommandGroup(replacing: .appTermination) {
                Button(L("HongMix 종료")) { ProjectIO.requestQuit() }
                    .keyboardShortcut("q")
            }
        }

        Window("Rundown", id: "rundown") {
            RundownView(rundown: engine.rundown)
                .id(language + skin)
                .environmentObject(engine)
                .preferredColorScheme(.dark)
        }
        .defaultSize(width: 1120, height: 680)
        Window("Replay", id: "replay") {
            ReplayView()
                .id(language + skin)
                .environmentObject(engine)
                .preferredColorScheme(.dark)
        }
        .defaultSize(width: 1200, height: 860)
        Window("Scopes", id: "scopes") {
            ScopesView()
                .id(language + skin)
                .environmentObject(engine)
                .preferredColorScheme(.dark)
        }
        .defaultSize(width: 960, height: 560)
        Window("PTZ Control", id: "ptz") {
            PTZControlWindow()
                .id(language + skin)
                .environmentObject(engine)
                .preferredColorScheme(.dark)
        }
        .defaultSize(width: 680, height: 520)
        Window(L("통계 및 모니터링"), id: "statistics") {
            StatisticsSheet(engine: engine)
                .id(language + skin)
                .preferredColorScheme(.dark)
        }
        .defaultSize(width: 1440, height: 900)

        Settings {
            SettingsView()
                .id(language + skin)
                .environmentObject(engine)
                .preferredColorScheme(.dark)
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    weak var engine: SwitcherEngine?

    func applicationWillFinishLaunching(_ notification: Notification) {
        let me = ProcessInfo.processInfo.processIdentifier
        if let existing = NSRunningApplication.runningApplications(withBundleIdentifier: "com.hongseunghoon.HongMix")
            .first(where: { $0.processIdentifier != me && !$0.isTerminated }) {
            existing.activate(options: [.activateAllWindows])
            NSApp.terminate(nil)
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSAppleEventManager.shared().setEventHandler(self, andSelector: #selector(handleQuitEvent(_:withReplyEvent:)),
                                                     forEventClass: AEEventClass(kCoreEventClass),
                                                     andEventID: AEEventID(kAEQuitApplication))
        // ⌘Q while a sheet has a focused text field never reaches the menu — catch it here.
        quitKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { e in
            let mods = e.modifierFlags.intersection(.deviceIndependentFlagsMask)
            if mods == .command, e.charactersIgnoringModifiers?.lowercased() == "w" {
                WindowCloser.closeFront()
                return nil
            }
            if mods == .command, e.charactersIgnoringModifiers?.lowercased() == "q",
               NSApp.windows.contains(where: { $0.attachedSheet != nil }) {
                ProjectIO.requestQuit()
                return nil
            }
            return e
        }
    }
    private var quitKeyMonitor: Any?

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    /// Quit Apple Event (Dock › Quit, scripts, logout): close open sheets first, then quit normally
    /// (still asks when outputs are running).
    @objc func handleQuitEvent(_ event: NSAppleEventDescriptor, withReplyEvent reply: NSAppleEventDescriptor) {
        ProjectIO.requestQuit()
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let engine = engine, !ProjectIO.terminatingFromSignal else { return .terminateNow }
        let live = engine.outputs.filter { $0.running }
        if !live.isEmpty {
            let alert = NSAlert()
            alert.messageText = L("송출/녹화가 진행 중입니다")
            alert.informativeText = L("종료하면 모든 출력이 중지되고 녹화 파일이 마무리됩니다.")
            alert.addButton(withTitle: L("종료"))
            alert.addButton(withTitle: L("취소"))
            if alert.runModal() != .alertFirstButtonReturn { return .terminateCancel }
        }
        return .terminateNow
    }

    func applicationWillTerminate(_ notification: Notification) {
        guard let engine = engine else { return }
        ProjectIO.autosave(engine)
        DisplayMap.shared.closeAll()
        engine.shutdown()
        mc_web_shutdown()       // embedded Chromium: close browsers and stop its helper processes
        FocusGuard.shared.appWillQuit()
    }
}

/// After the launch screen: monitor outputs come back, Do Not Disturb (or its approval request),
/// then the pre-show check.
enum AfterLaunch {
    static func run(_ engine: SwitcherEngine) {
        DisplayMap.shared.start(engine: engine)
        FocusGuard.shared.launch {
            if SystemCheck.showAtLaunch { StartupCheckWindow.show(engine: engine) }
        }
    }
}

enum ProjectIO {
    static let fileType = UTType(filenameExtension: "bmix") ?? .json

    static func encode(_ engine: SwitcherEngine) -> Data? {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try? enc.encode(engine.makeProject())
    }

    static func autosave(_ engine: SwitcherEngine) {
        if let data = encode(engine) { try? data.write(to: ProjectFile.autosaveURL, options: .atomic) }
    }

    private static var autosaveTimer: Timer?
    private static var lastSaved: Data?
    private static var termSource: DispatchSourceSignal?
    /// SIGTERM (e.g. a script restarting the app): quit cleanly without the "outputs running" prompt.
    static var terminatingFromSignal = false

    /// Saves the session every few seconds (only when it changed) and on SIGTERM / kill,
    /// so a crash or forced quit never loses the input list.
    static func startAutosave(_ engine: SwitcherEngine) {
        autosaveTimer?.invalidate()
        autosaveTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak engine] _ in
            guard let engine = engine, let data = encode(engine), data != lastSaved else { return }
            try? data.write(to: ProjectFile.autosaveURL, options: .atomic)
            lastSaved = data
        }
        signal(SIGTERM, SIG_IGN)
        let src = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        src.setEventHandler {
            terminatingFromSignal = true
            requestQuit()
        }
        src.resume()
        termSource = src
    }

    /// An open sheet (settings, captions …) blocks NSApp.terminate — close them first so Quit always works.
    static func closeSheets() {
        for w in NSApp.windows {
            while let sheet = w.attachedSheet { w.endSheet(sheet); sheet.orderOut(nil) }
        }
    }

    weak static var engineRef: SwitcherEngine?

    /// Quit (menu ⌘Q, Dock, AppleScript, SIGTERM). A SwiftUI sheet that is open makes AppKit ignore
    /// NSApp.terminate, so with a sheet open the app saves and shuts down itself, the same way
    /// applicationWillTerminate does, after the usual "outputs running" question.
    static func requestQuit() {
        let hasSheet = NSApp.windows.contains { $0.attachedSheet != nil } || NSApp.modalWindow != nil
        guard hasSheet, let engine = engineRef else { NSApp.terminate(nil); return }
        if !terminatingFromSignal && engine.outputs.contains(where: { $0.running }) {
            let alert = NSAlert()
            alert.messageText = L("송출/녹화가 진행 중입니다")
            alert.informativeText = L("종료하면 모든 출력이 중지되고 녹화 파일이 마무리됩니다.")
            alert.addButton(withTitle: L("종료"))
            alert.addButton(withTitle: L("취소"))
            if alert.runModal() != .alertFirstButtonReturn { return }
        }
        autosave(engine)
        DisplayMap.shared.closeAll()
        engine.shutdown()
        mc_web_shutdown()
        FocusGuard.shared.appWillQuit()
        exit(0)
    }

    static func restoreLastSession(into engine: SwitcherEngine) {
        guard engine.inputs.isEmpty,
              let data = try? Data(contentsOf: ProjectFile.autosaveURL),
              let project = try? JSONDecoder().decode(ProjectFile.self, from: data) else { return }
        engine.load(project: project)
    }

    static func newProject(_ engine: SwitcherEngine) {
        let empty = ProjectFile(formatID: engine.format.id, inputs: [], outputs: [], programIndex: nil,
                                previewIndex: nil, transitions: nil, masterVolume: 1)
        engine.load(project: empty)
    }

    static func save(_ engine: SwitcherEngine) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [fileType]
        panel.nameFieldStringValue = L("HongMix 프로젝트.bmix")
        guard panel.runModal() == .OK, let url = panel.url, let data = encode(engine) else { return }
        do {
            try data.write(to: url)
        } catch {
            NSAlert(error: error).runModal()
        }
    }

    static func open(into engine: SwitcherEngine) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [fileType, .json]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let data = try Data(contentsOf: url)
            let project = try JSONDecoder().decode(ProjectFile.self, from: data)
            engine.load(project: project)
        } catch {
            NSAlert(error: error).runModal()
        }
    }
}


/// 1.2: the bundle ID moved from the pre-release (internal) ID to com.hongseunghoon.HongMix.
/// Copy the old settings (language, shortcuts, NDI IPs, …) once so nothing is lost.
enum DefaultsMigration {
    /// The internal pre-release name (only needed to find old settings/folders).
    static let legacyName = ["Brace", "let", "Mix"].joined()
    static let oldDomain = "com." + ["brace", "let", "studio"].joined() + "." + legacyName

    static func run() -> Bool {
        let d = UserDefaults.standard
        guard Bundle.main.bundleIdentifier != oldDomain, !d.bool(forKey: "migratedLegacyDefaults") else { return false }
        if let old = UserDefaults.standard.persistentDomain(forName: oldDomain) {
            for (k, v) in old where d.object(forKey: k) == nil { d.set(v, forKey: k) }
        }
        d.set(true, forKey: "migratedLegacyDefaults")
        return true
    }

    /// Moves ~/Library/Application Support/<old name> (autosave, titles, browser cache) to …/HongMix once.
    static func migrateFolders() {
        let fm = FileManager.default
        guard let support = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { return }
        let old = support.appendingPathComponent(legacyName, isDirectory: true)
        let new = support.appendingPathComponent("HongMix", isDirectory: true)
        guard fm.fileExists(atPath: old.path) else { return }
        if !fm.fileExists(atPath: new.path) {
            try? fm.moveItem(at: old, to: new)
        } else if let items = try? fm.contentsOfDirectory(atPath: old.path) {
            for it in items where !fm.fileExists(atPath: new.appendingPathComponent(it).path) {
                try? fm.moveItem(at: old.appendingPathComponent(it), to: new.appendingPathComponent(it))
            }
        }
    }

    /// Saved projects may still point at the old default folders → use the HongMix ones.
    static func modernize(_ path: String) -> String {
        let legacy = "~/Movies/" + legacyName
        return path.hasPrefix(legacy) ? "~/Movies/HongMix" + path.dropFirst(legacy.count) : path
    }
}

/// ⌘W: closes the front helper window (Scopes, Rundown, Replay, PTZ, Statistics, input monitor, pre-show
/// check, Settings …) or the open sheet (same as its Cancel / Close). Never the switcher window — closing
/// it would quit HongMix mid-show — and never the Display output window: those only beep.
enum WindowCloser {
    static func closeFront() {
        guard let w = NSApp.keyWindow else { NSSound.beep(); return }
        if let parent = w.sheetParent {             // a sheet (input editor, scheduler, outputs …)
            // Only HongMix's own SwiftUI sheets (= Cancel/Close). A question (NSAlert "Stop the stream?")
            // must be answered with a button: ending it here could count as an answer.
            // (alerts, open/save panels are NSPanels).
            let question = w is NSPanel || String(describing: type(of: w)).contains("Alert")
            if question { NSSound.beep() } else { parent.endSheet(w) }
            return
        }
        if w.attachedSheet != nil { NSSound.beep(); return }     // its sheet is waiting for an answer
        let isSwitcher = w === FullscreenOutput.switcherWindow || (w.identifier?.rawValue.hasPrefix("main") ?? false)
        guard !isSwitcher, !FullscreenOutput.isOutputWindow(w), w.styleMask.contains(.closable) else {
            NSSound.beep(); return
        }
        w.performClose(nil)
    }
}
