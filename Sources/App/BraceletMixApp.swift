import SwiftUI
import AppKit
import UniformTypeIdentifiers

@main
struct BraceletMixApp: App {
    /// Must run before anything reads UserDefaults (first stored property).
    private let migrated: Bool = DefaultsMigration.run()
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var engine = SwitcherEngine()
    /// Changing the language rebuilds the window contents (engine and inputs keep running).
    @AppStorage(AppLanguage.defaultsKey) private var language = AppLanguage.current.rawValue

    var body: some Scene {
        Window("HongMix", id: "main") {
            ZStack { ContentView().id(language) }
                .environmentObject(engine)
                .frame(minWidth: 1280, minHeight: 780)
                .preferredColorScheme(.dark)
                .onAppear {
                    appDelegate.engine = engine
                    mc_ndi_set_extra_ips(UserDefaults.standard.string(forKey: "ndiExtraIPs") ?? "")
                    engine.startEngine()
                    ProjectIO.restoreLastSession(into: engine)
                    ProjectIO.startAutosave(engine)
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
            }
        }

        Window("Rundown", id: "rundown") {
            RundownView(rundown: engine.rundown)
                .id(language)
                .environmentObject(engine)
                .preferredColorScheme(.dark)
        }
        .defaultSize(width: 980, height: 620)
        Window("Scopes", id: "scopes") {
            ScopesView()
                .id(language)
                .environmentObject(engine)
                .preferredColorScheme(.dark)
        }
        .defaultSize(width: 900, height: 560)

        Settings {
            SettingsView()
                .id(language)
                .environmentObject(engine)
                .preferredColorScheme(.dark)
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    weak var engine: SwitcherEngine?

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

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
        engine.shutdown()
        mc_web_shutdown()       // embedded Chromium: close browsers and stop its helper processes
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
            NSApp.terminate(nil)
        }
        src.resume()
        termSource = src
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


/// 1.2: the bundle ID moved from com.braceletstudio.BraceletMix to com.hongseunghoon.HongMix.
/// Copy the old settings (language, shortcuts, NDI IPs, …) once so nothing is lost.
enum DefaultsMigration {
    static let oldDomain = "com.braceletstudio.BraceletMix"

    static func run() -> Bool {
        let d = UserDefaults.standard
        guard Bundle.main.bundleIdentifier != oldDomain, !d.bool(forKey: "migratedFromBraceletStudio") else { return false }
        if let old = UserDefaults.standard.persistentDomain(forName: oldDomain) {
            for (k, v) in old where d.object(forKey: k) == nil { d.set(v, forKey: k) }
        }
        d.set(true, forKey: "migratedFromBraceletStudio")
        return true
    }
}
