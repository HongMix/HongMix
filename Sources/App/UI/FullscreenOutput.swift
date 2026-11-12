import AppKit
import SwiftUI

/// Borderless output window that can still receive keys (Esc to leave when it covers the app's own screen).
private final class FullscreenWindow: NSWindow {
    var onExit: (() -> Void)?
    var exitOnEscape = true
    override var canBecomeKey: Bool { true }
    override func keyDown(with event: NSEvent) {
        if exitOnEscape && event.keyCode == 53 { onExit?() } else { super.keyDown(with: event) }   // Esc
    }
    override func mouseDown(with event: NSEvent) {
        if exitOnEscape && event.clickCount == 2 { onExit?() } else { super.mouseDown(with: event) }
    }
    override func rightMouseDown(with event: NSEvent) {
        if exitOnEscape { onExit?() } else { super.rightMouseDown(with: event) }
    }
    override func close() { onExit?() }
    /// Really closes the window (close() is the user's "exit" gesture).
    func forceClose() { super.close() }
}

enum DisplayOutputMode: String, CaseIterable {
    case window, fullscreen
    var title: String { self == .window ? L("출력 창") : L("디스플레이 전체화면") }
}

/// Program (or another source) on a display — the "Fullscreen" output.
/// • Default display: a screen other than the one the switcher is on (like vMix's secondary monitor).
/// • If it has to use the switcher's own screen: menu bar/Dock hidden, Esc / double-click / right-click exits.
/// • Displays plugged/unplugged while showing: follows the chosen display or closes cleanly.
final class FullscreenOutput: NSObject {
    static let shared = FullscreenOutput()
    private var window: FullscreenWindow?
    private weak var engine: SwitcherEngine?
    private var screenObserver: NSObjectProtocol?
    private var hintTimer: Timer?
    private var coversAppScreen = false
    /// Mode of the window currently on screen. It can differ from the saved mode while a normal
    /// Output Window temporarily fills its display.
    private var activeMode: DisplayOutputMode = .window
    /// Output window temporarily filling its display (green button). Exit returns to this frame.
    private var fillReturnFrame: NSRect?
    /// Display the output window is filling (green button), followed on screen changes.
    private var fillDisplayID: CGDirectDisplayID?

    /// The Display output window (on air — never closed by ⌘W).
    static func isOutputWindow(_ w: NSWindow) -> Bool { w is FullscreenWindow }

    /// The switcher's own window — not the output window, which can also become "main".
    static var switcherWindow: NSWindow? {
        let candidates = NSApp.windows.filter { !($0 is FullscreenWindow) && $0.isVisible && $0.styleMask.contains(.titled) }
        return candidates.first(where: { $0.identifier?.rawValue.hasPrefix("main") ?? false })
            ?? candidates.max(by: { $0.frame.width * $0.frame.height < $1.frame.width * $1.frame.height })
    }
    private(set) var source: BusSource = .program
    private(set) var mode: DisplayOutputMode {
        get { DisplayOutputMode(rawValue: UserDefaults.standard.string(forKey: "displayOutputMode") ?? "window") ?? .window }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: "displayOutputMode") }
    }
    var alwaysOnTop: Bool {
        get { UserDefaults.standard.bool(forKey: "outputWindowAlwaysOnTop") }
        set {
            UserDefaults.standard.set(newValue, forKey: "outputWindowAlwaysOnTop")
            if activeMode == .window { window?.level = newValue ? .floating : .normal }
        }
    }
    var lockAspect: Bool {
        get { UserDefaults.standard.object(forKey: "outputWindowLockAspect") as? Bool ?? true }
        set {
            UserDefaults.standard.set(newValue, forKey: "outputWindowLockAspect")
            window?.contentAspectRatio = newValue ? NSSize(width: 16, height: 9) : .zero
        }
    }

    /// Chosen display (CGDirectDisplayID), 0 = automatic. Persisted.
    private(set) var displayID: CGDirectDisplayID {
        get { CGDirectDisplayID(UserDefaults.standard.integer(forKey: "fullscreenDisplayID")) }
        set { UserDefaults.standard.set(Int(newValue), forKey: "fullscreenDisplayID") }
    }

    var isShowing: Bool { window != nil }
    /// Monitor the output is on right now.
    var currentScreen: NSScreen? { window?.screen }

    /// Fullscreen on a monitor other than the switcher's: every desktop (default) or only the current one.
    var pin: DesktopPin {
        get { DesktopPin(rawValue: UserDefaults.standard.string(forKey: "fullscreenPin") ?? "") ?? .allDesktops }
        set {
            UserDefaults.standard.set(newValue.rawValue, forKey: "fullscreenPin")
            if let e = engine, isShowing, activeMode == .fullscreen { hide(); show(engine: e) }
        }
    }
    /// The chosen monitor by what it is (MonitorIdentity) — survives replugging, unlike displayID.
    private var displayKey: String {
        get { UserDefaults.standard.string(forKey: "fullscreenDisplayKey") ?? "" }
        set { UserDefaults.standard.set(newValue, forKey: "fullscreenDisplayKey") }
    }
    /// The chosen monitor was unplugged while showing: reopen when it comes back.
    private var reopenWhenBack = false
    private var reconnectObserver: NSObjectProtocol?

    static func displayID(of s: NSScreen) -> CGDirectDisplayID {
        (s.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0
    }

    struct ScreenItem { let id: CGDirectDisplayID; let name: String }

    static func screens() -> [ScreenItem] {
        NSScreen.screens.enumerated().map { item in
            let s = item.element
            let main = s == switcherWindow?.screen ? L(" · 스위처 화면") : ""
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
        if displayID != 0 {
            if !displayKey.isEmpty, let s = MonitorIdentity.screen(forKey: displayKey) {
                // replugged monitors get a new display ID: follow it, so the Display picker shows the monitor again
                let id = FullscreenOutput.displayID(of: s)
                if id != displayID { displayID = id }
                return s
            }
            if let s = screens.first(where: { FullscreenOutput.displayID(of: $0) == displayID }) { return s }
        }
        // automatic: any screen that is not the switcher's
        let appScreen = FullscreenOutput.switcherWindow?.screen
        return screens.first(where: { $0 != appScreen }) ?? screens[0]
    }

    func setDisplay(_ id: CGDirectDisplayID, engine: SwitcherEngine) {
        displayID = id
        displayKey = NSScreen.screens.first { FullscreenOutput.displayID(of: $0) == id }.map { MonitorIdentity.of($0).key } ?? ""
        reopenWhenBack = false
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

    func setMode(_ newMode: DisplayOutputMode, engine: SwitcherEngine) {
        guard mode != newMode else { return }
        let reopen = isShowing
        if reopen { hide() }
        mode = newMode
        if reopen { show(engine: engine) }
        engine.objectWillChange.send()
    }

    /// Select a mode and make it visible. The old picker only changed a preference, which made
    /// selecting Fullscreen appear to do nothing while the output was closed.
    func open(_ newMode: DisplayOutputMode, engine: SwitcherEngine) {
        if isShowing { hide() }
        mode = newMode
        show(engine: engine)
        engine.objectWillChange.send()
    }

    func toggle(engine: SwitcherEngine) {
        fillReturnFrame = nil
        if isShowing { hide() } else { show(engine: engine) }
    }

    func show(engine: SwitcherEngine) { show(engine: engine, fill: nil, windowFrame: nil) }

    /// - fill: cover this display borderless (green button on the output window), whatever `mode` says.
    /// - windowFrame: restore the output window here (coming back from fill).
    private func show(engine: SwitcherEngine, fill: NSScreen?, windowFrame: NSRect?) {
        guard window == nil, let screen = fill ?? targetScreen() else { return }
        self.engine = engine
        let mode: DisplayOutputMode = fill != nil ? .fullscreen : self.mode
        activeMode = mode
        let appScreen = FullscreenOutput.switcherWindow?.screen
        coversAppScreen = mode == .fullscreen && (screen == appScreen || NSScreen.screens.count == 1)
        fillDisplayID = fill.map { FullscreenOutput.displayID(of: $0) }

        let initial = mode == .window
            ? (windowFrame ?? NSRect(x: screen.visibleFrame.midX - 480, y: screen.visibleFrame.midY - 270, width: 960, height: 540))
            : screen.frame
        let style: NSWindow.StyleMask = mode == .window
            ? [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
            : [.borderless]
        let w = FullscreenWindow(contentRect: initial, styleMask: style, backing: .buffered,
                                 defer: false, screen: screen)
        w.title = L("출력 창")
        w.titlebarAppearsTransparent = mode == .window
        w.exitOnEscape = mode == .fullscreen
        let pinned = pin == .allDesktops
        // Another monitor: above its menu bar and Dock for both desktop options — "this desktop only" is set by the
        // collection behaviour below (which Spaces), not by the level (at .normal that monitor's menu bar covered the top).
        w.level = mode == .window ? (alwaysOnTop ? .floating : .normal) : (coversAppScreen ? .normal : .screenSaver)
        w.backgroundColor = .black
        w.isOpaque = true
        w.hasShadow = mode == .window
        w.isReleasedWhenClosed = false
        // Never a macOS full-screen Space: hiding a window that owns one left an empty black
        // "Full Screen" desktop behind. The green button fills the display borderless instead.
        // Open on the operator's current desktop — also when the switcher itself is in a macOS
        // full-screen Space (otherwise macOS jumped to another desktop and the switcher vanished).
        // A display other than the switcher's keeps the picture on every Space.
        if mode == .window {
            w.collectionBehavior = [.fullScreenAuxiliary, .moveToActiveSpace, .fullScreenNone]
        } else if coversAppScreen {
            w.collectionBehavior = [.fullScreenAuxiliary, .moveToActiveSpace, .ignoresCycle]
        } else if pinned {
            w.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        } else {
            w.collectionBehavior = [.managed, .fullScreenAuxiliary, .ignoresCycle]
        }
        let switcherInFullScreen = NSApp.windows.contains { $0.isVisible && $0.styleMask.contains(.fullScreen) }
        if mode == .window {
            w.minSize = NSSize(width: 480, height: 270)
            w.contentAspectRatio = lockAspect ? NSSize(width: 16, height: 9) : .zero
        }
        if mode == .window, let zoom = w.standardWindowButton(.zoomButton) {
            zoom.isEnabled = true
            zoom.target = self
            zoom.action = #selector(fillDisplay(_:))
            zoom.toolTip = L("이 창이 있는 디스플레이 전체를 채우기 (Esc · 더블클릭으로 돌아오기)")
        }
        w.onExit = { [weak self] in self?.exitPressed() }
        let slot = engine.fullscreenSlot
        engine.setFullscreenSource(source)
        let root = ZStack(alignment: .top) {
            Color.black
            MonitorView(fps: 120, source: { slot.latest() })
            FullscreenHint(visible: coversAppScreen)
        }
        .ignoresSafeArea()
        w.contentView = NSHostingView(rootView: root)
        w.setFrame(initial, display: true)
        if mode == .window {
            w.makeKeyAndOrderFront(nil)
        } else if coversAppScreen {
            // the switcher is underneath: hide menu bar + Dock, take the keyboard so Esc works
            // In a full-screen Space the menu bar and Dock are already hidden; changing the
            // options there is not allowed.
            if !switcherInFullScreen { NSApp.presentationOptions = [.autoHideMenuBar, .autoHideDock] }
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
        reopenWhenBack = false
        if displayKey.isEmpty, displayID != 0 { displayKey = MonitorIdentity.of(screen).key }
        if reconnectObserver == nil {
            reconnectObserver = NotificationCenter.default.addObserver(
                forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { self?.reopenIfBack() }
            }
        }
        engine.objectWillChange.send()
    }

    /// The unplugged monitor is back (same vendor/model/serial): show the output on it again.
    private func reopenIfBack() {
        guard reopenWhenBack, window == nil, let engine = engine, !displayKey.isEmpty,
              MonitorIdentity.screen(forKey: displayKey) != nil else { return }
        reopenWhenBack = false
        show(engine: engine)
        engine.lastMessage = L("풀스크린 디스플레이가 다시 연결되어 출력을 다시 열었습니다")
    }

    private func screensChanged() {
        guard let w = window, let engine = engine else { return }
        let chosenGone = !displayKey.isEmpty ? MonitorIdentity.screen(forKey: displayKey) == nil
            : !NSScreen.screens.contains(where: { FullscreenOutput.displayID(of: $0) == displayID })
        if displayID != 0, chosenGone {
            let reopen = activeMode == .fullscreen && fillDisplayID == nil
            hide()          // the chosen display was unplugged
            reopenWhenBack = reopen
            engine.lastMessage = reopen ? L("풀스크린 디스플레이가 분리되었습니다 — 다시 연결되면 자동으로 다시 엽니다")
                                        : L("풀스크린 디스플레이가 분리되어 풀스크린을 닫았습니다")
            return
        }
        if let s = targetScreen(), activeMode == .fullscreen, fillDisplayID == nil, s != w.screen {
            w.setFrame(s.frame, display: true)
        }
        let fillScreen = fillDisplayID.flatMap { id in NSScreen.screens.first { FullscreenOutput.displayID(of: $0) == id } }
        if fillDisplayID != nil && fillScreen == nil {
            exitPressed()   // the filled display was unplugged: back to the output window
            return
        }
        if activeMode == .fullscreen, let s = fillScreen ?? targetScreen() { w.setFrame(s.frame, display: true) }
    }

    /// Green button on the output window: fill that window's display, come back on exit.
    @objc private func fillDisplay(_ sender: Any?) {
        guard let w = window, let screen = w.screen, let engine = engine else { return }
        let frame = w.frame
        closeWindow()
        fillReturnFrame = frame
        show(engine: engine, fill: screen, windowFrame: nil)
    }

    /// Test hooks (HTTP API): same paths as the green button and Esc.
    func testFill() { fillDisplay(nil) }
    /// Clicks the real green (zoom) button, exactly as the operator does.
    func testClickZoomButton() -> Bool {
        guard let b = window?.standardWindowButton(.zoomButton) else { return false }
        b.performClick(nil)
        return true
    }
    /// Asks AppKit for macOS full screen (⌃⌘F / Window menu) on the output window.
    func testToggleSystemFullScreen() { window?.toggleFullScreen(nil) }
    func testExit() { exitPressed() }

    private func exitPressed() {
        if let frame = fillReturnFrame, let engine = engine {
            fillReturnFrame = nil
            closeWindow()
            show(engine: engine, fill: nil, windowFrame: frame)
        } else {
            hide()
        }
    }

    /// Closes the display output completely (also forgets a pending return-from-fill).
    func hide() {
        fillReturnFrame = nil
        reopenWhenBack = false
        closeWindow()
    }

    /// Output windows never enter a macOS full-screen Space (.fullScreenNone / borderless),
    /// so closing is always immediate — no Space can be left behind.
    private func closeWindow() {
        guard let w = window else { return }
        teardown(w)
    }

    private func teardown(_ w: FullscreenWindow) {
        w.orderOut(nil)
        w.contentView = nil
        w.forceClose()
        if window === w { window = nil }
        if coversAppScreen && !NSApp.windows.contains(where: { $0.isVisible && $0.styleMask.contains(.fullScreen) }) {
            NSApp.presentationOptions = []
        }
        coversAppScreen = false
        activeMode = .window
        fillDisplayID = nil
        if let o = screenObserver { NotificationCenter.default.removeObserver(o) }
        screenObserver = nil
        engine?.setFullscreenSource(nil)
        engine?.fullscreenSlot.clear()
        engine?.objectWillChange.send()
        FullscreenOutput.switcherWindow?.makeKeyAndOrderFront(nil)
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
