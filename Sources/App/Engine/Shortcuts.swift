import AppKit
import Combine

/// vMix "Shortcuts": any key (with modifiers) → any API function, with optional Input and Value.
struct UserShortcut: Codable, Identifiable, Equatable {
    var id = UUID()
    var key: String              // single character ("a", "1", "F") or a special name ("F1", "Space", "Left" …)
    var command = false
    var shift = false
    var option = false
    var control = false
    var function: String         // e.g. "Cut", "OverlayInput1In", "StartStopRecording"
    var input = ""               // number, name or key; empty = none
    var value = ""

    var label: String {
        var s = ""
        if control { s += "⌃" }
        if option { s += "⌥" }
        if shift { s += "⇧" }
        if command { s += "⌘" }
        return s + (key.count == 1 ? key.uppercased() : key)
    }
}

final class ShortcutManager: ObservableObject {
    static let shared = ShortcutManager()
    @Published var items: [UserShortcut] = [] { didSet { save() } }
    /// When set, the next key press is captured for the shortcut editor instead of being executed.
    var capture: ((NSEvent) -> Void)?
    private var monitor: Any?
    private weak var engine: SwitcherEngine?

    static let commonFunctions = [
        "Cut", "Fade", "Merge", "Wipe", "Slide", "Fly", "CrossZoom", "Zoom", "Stinger1", "Stinger2",
        "QuickPlay", "PreviewInput", "CutDirect", "PreviewInputNext", "PreviewInputPrevious",
        "OverlayInput1", "OverlayInput1In", "OverlayInput1Out", "OverlayInput2", "OverlayInput2In", "OverlayInput2Out",
        "OverlayInput3", "OverlayInput4", "OverlayInputAllOff", "FadeToBlack",
        "StartStopRecording", "StartStopStreaming", "StartStopExternal", "StartStopMultiCorder", "Fullscreen",
        "Snapshot", "AudioOn", "AudioOff", "Audio", "MasterAudio", "SetVolumeFade",
        "Play", "Pause", "PlayPause", "Restart", "SetText", "StartCountdown", "StopCountdown",
        "DataSourceNextRow", "DataSourcePreviousRow", "DataSourceSelectRow",
    ]

    private static let specialKeys: [UInt16: String] = [
        49: "Space", 36: "Return", 76: "Enter", 48: "Tab", 51: "Backspace", 117: "Delete", 53: "Esc",
        123: "Left", 124: "Right", 125: "Down", 126: "Up", 115: "Home", 119: "End", 116: "PageUp", 121: "PageDown",
        122: "F1", 120: "F2", 99: "F3", 118: "F4", 96: "F5", 97: "F6", 98: "F7", 100: "F8", 101: "F9", 109: "F10",
        103: "F11", 111: "F12", 82: "Num0", 83: "Num1", 84: "Num2", 85: "Num3", 86: "Num4", 87: "Num5",
        88: "Num6", 89: "Num7", 91: "Num8", 92: "Num9",
    ]

    static func keyName(_ e: NSEvent) -> String {
        if let s = specialKeys[e.keyCode] { return s }
        return (e.charactersIgnoringModifiers ?? "").lowercased()
    }

    private init() {
        if let d = UserDefaults.standard.data(forKey: "userShortcuts"),
           let v = try? JSONDecoder().decode([UserShortcut].self, from: d) { items = v }
    }

    private func save() {
        if let d = try? JSONEncoder().encode(items) { UserDefaults.standard.set(d, forKey: "userShortcuts") }
    }

    func install(engine: SwitcherEngine) {
        self.engine = engine
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] ev in
            guard let self = self else { return ev }
            if let cap = self.capture {
                cap(ev)
                return nil
            }
            // never steal keys from text fields or the web page being typed into
            if let r = ev.window?.firstResponder, r is NSText || r is BrowserEventView { return ev }
            guard let sc = self.match(ev), let engine = self.engine else { return ev }
            var q: [String: String] = [:]
            if !sc.input.isEmpty { q["input"] = sc.input }
            if !sc.value.isEmpty { q["value"] = sc.value }
            if let err = APIProcessor.perform(sc.function, q, engine) { engine.lastMessage = Lf("단축키 %@: %@", "\(sc.label)", "\(err)") }
            return nil
        }
    }

    private func match(_ e: NSEvent) -> UserShortcut? {
        let f = e.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let k = ShortcutManager.keyName(e)
        return items.first {
            $0.key.lowercased() == k && $0.command == f.contains(.command) && $0.shift == f.contains(.shift) &&
                $0.option == f.contains(.option) && $0.control == f.contains(.control)
        }
    }
}
