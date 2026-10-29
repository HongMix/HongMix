import AppKit
import SwiftUI

/// Borderless output window that can still receive keys (Esc to leave when it covers the app's own screen).
private final class FullscreenWindow: NSWindow {
    var onExit: (() -> Void)?
    override var canBecomeKey: Bool { true }
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { onExit?() } else { super.keyDown(with: event) }   // Esc
    }
    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 { onExit?() } else { super.mouseDown(with: event) }
    }
    override func rightMouseDown(with event: NSEvent) { onExit?() }
}

/// Program (or another source) on a display — the "Fullscreen" output.
/// • Default display: a screen other than the one the switcher is on (like vMix's secondary monitor).
/// • If it has to use the switcher's own screen: menu bar/Dock hidden, Esc / double-click / right-click exits.
/// • Displays plugged/unplugged while showing: follows the chosen display or closes cleanly.
final class FullscreenOutput {
    static let shared = FullscreenOutput()
    private var window: FullscreenWindow?
    private weak var engine: SwitcherEngine?
    private var screenObserver: NSObjectProtocol?
    private var hintTimer: Timer?
    private var coversAppScreen = false
    private(set) var source: BusSource = .program

    /// Chosen display (CGDirectDisplayID), 0 = automatic. Persisted.
    private(set) var displayID: CGDirectDisplayID {
        get { CGDirectDisplayID(UserDefaults.standard.integer(forKey: "fullscreenDisplayID")) }
        set { UserDefaults.standard.set(Int(newValue), forKey: "fullscreenDisplayID") }
    }

    var isShowing: Bool { window != nil }

    static func displayID(of s: NSScreen) -> CGDirectDisplayID {
        (s.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0
    }

    struct ScreenItem { let id: CGDirectDisplayID; let name: String }

    static func screens() -> [ScreenItem] {
        NSScreen.screens.enumerated().map { item in
            let s = item.element
            let main = s == NSApp.mainWindow?.screen ? L(" · 스위처 화면") : ""
            return ScreenItem(id: displayID(of: s),
                              name: "\(item.offset + 1): \(s.localizedName) (\(Int(s.frame.width))×\(Int(s.frame.height)))\(main)")
        }
    }

    /// Kept for older call sites.
    static func screenNames() -> [String] { screens().map { $0.name } }

    var displayLabel: String {
        if displayID == 0 { return L("자동") }
        return FullscreenOutput.screens().first { $0.id == displayID }?.name ?? L("연결 안 됨")
    }

    private func targetScreen() -> NSScreen? {
        let screens = NSScreen.screens
        guard !screens.isEmpty else { return nil }
        if displayID != 0, let s = screens.first(where: { FullscreenOutput.displayID(of: $0) == displayID }) { return s }
        // automatic: any screen that is not the switcher's
        let appScreen = NSApp.mainWindow?.screen ?? NSApp.windows.first(where: { $0.isVisible && $0.styleMask.contains(.titled) })?.screen
        return screens.first(where: { $0 != appScreen }) ?? screens[0]
    }

    func setDisplay(_ id: CGDirectDisplayID, engine: SwitcherEngine) {
        displayID = id
        if isShowing {
            hide()
            show(engine: engine)
        }
        engine.objectWillChange.send()
    }

    /// Older call sites (index into NSScreen.screens).
    func setScreen(_ index: Int, engine: SwitcherEngine) {
        let list = FullscreenOutput.screens()
        guard list.indices.contains(index) else { return }
        setDisplay(list[index].id, engine: engine)
    }

    func setSource(_ src: BusSource, engine: SwitcherEngine) {
        source = src
        if isShowing { engine.setFullscreenSource(src) }
        engine.objectWillChange.send()
    }

    func toggle(engine: SwitcherEngine) {
        if isShowing { hide() } else { show(engine: engine) }
    }

    func show(engine: SwitcherEngine) {
        guard window == nil, let screen = targetScreen() else { return }
        self.engine = engine
        let appScreen = NSApp.mainWindow?.screen
        coversAppScreen = screen == appScreen || NSScreen.screens.count == 1

        let w = FullscreenWindow(contentRect: screen.frame, styleMask: [.borderless], backing: .buffered,
                                 defer: false, screen: screen)
        w.level = coversAppScreen ? .normal : .screenSaver
        w.backgroundColor = .black
        w.isOpaque = true
        w.hasShadow = false
        w.isReleasedWhenClosed = false
        w.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        w.onExit = { [weak self] in self?.hide() }
        let slot = engine.fullscreenSlot
        engine.setFullscreenSource(source)
        let root = ZStack(alignment: .top) {
            Color.black
            MonitorView(fps: 120, source: { slot.latest() })
            FullscreenHint(visible: coversAppScreen)
        }
        .ignoresSafeArea()
        w.contentView = NSHostingView(rootView: root)
        w.setFrame(screen.frame, display: true)
        if coversAppScreen {
            // the switcher is underneath: hide menu bar + Dock, take the keyboard so Esc works
            NSApp.presentationOptions = [.autoHideMenuBar, .autoHideDock]
            w.makeKeyAndOrderFront(nil)
        } else {
            w.orderFrontRegardless()
        }
        NSCursor.setHiddenUntilMouseMoves(true)
        window = w

        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            self?.screensChanged()
        }
        engine.objectWillChange.send()
    }

    private func screensChanged() {
        guard let w = window, let engine = engine else { return }
        if displayID != 0, !NSScreen.screens.contains(where: { FullscreenOutput.displayID(of: $0) == displayID }) {
            hide()          // the chosen display was unplugged
            engine.lastMessage = L("풀스크린 디스플레이가 분리되어 풀스크린을 닫았습니다")
            return
        }
        if let s = targetScreen() { w.setFrame(s.frame, display: true) }
    }

    func hide() {
        window?.orderOut(nil)
        window?.contentView = nil
        window = nil
        if coversAppScreen { NSApp.presentationOptions = [] }
        coversAppScreen = false
        if let o = screenObserver { NotificationCenter.default.removeObserver(o) }
        screenObserver = nil
        engine?.setFullscreenSource(nil)
        engine?.fullscreenSlot.clear()
        engine?.objectWillChange.send()
        NSApp.mainWindow?.makeKeyAndOrderFront(nil)
    }
}

/// "Esc to exit" hint, shown for 3 s when Fullscreen covers the switcher's own screen.
private struct FullscreenHint: View {
    let visible: Bool
    @ViewState private var show = true

    var body: some View {
        if visible && show {
            Text(L("풀스크린 출력 중 — Esc · 더블클릭 · 우클릭으로 닫기"))
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(.white)
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .background(Color.black.opacity(0.7))
                .clipShape(Capsule())
                .padding(.top, 30)
                .onAppear { DispatchQueue.main.asyncAfter(deadline: .now() + 3) { withAnimation { show = false } } }
        }
    }
}
