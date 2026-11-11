import AppKit
import SwiftUI

/// A physical monitor, remembered by what it is (vendor, model, serial) rather than by the number macOS
/// gives it — that number changes when a cable or dock is replugged. Two identical monitors without a
/// serial are told apart by their order on the desk (left to right).
struct MonitorIdentity: Hashable {
    let key: String
    let name: String

    static func of(_ screen: NSScreen) -> MonitorIdentity {
        let id = FullscreenOutput.displayID(of: screen)
        let v = CGDisplayVendorNumber(id), m = CGDisplayModelNumber(id), s = CGDisplaySerialNumber(id)
        var key = "\(v)-\(m)-\(s)"
        if s == 0 {
            let twins = NSScreen.screens.filter {
                let o = FullscreenOutput.displayID(of: $0)
                return CGDisplayVendorNumber(o) == v && CGDisplayModelNumber(o) == m && CGDisplaySerialNumber(o) == 0
            }.sorted { $0.frame.minX < $1.frame.minX }
            if twins.count > 1, let k = twins.firstIndex(of: screen) { key += "#\(k + 1)" }
        }
        return MonitorIdentity(key: key, name: screen.localizedName)
    }

    static func screen(forKey key: String) -> NSScreen? {
        NSScreen.screens.first { of($0).key == key }
    }
}

/// How an output window lives on macOS desktops (Spaces).
enum DesktopPin: String, Codable, CaseIterable {
    /// On every desktop of its monitor, above other windows — switching desktops never changes it.
    case allDesktops
    /// Only on the desktop it was opened on; other desktops show their own apps on that monitor.
    case thisDesktop

    var title: String { self == .allDesktops ? L("이 모니터에 항상 고정") : L("지금 데스크탑에서만 보기") }
    static var help: String {
        L("항상 고정: 데스크탑을 넘겨도 이 모니터에는 출력만 보입니다. 지금 데스크탑에서만 보기: 다른 데스크탑으로 넘기면 그 데스크탑의 앱이 보입니다.")
    }
}

/// Monitor outputs: each connected monitor (other than the switcher's) can show its own source,
/// full screen. Assignments are remembered per monitor and come back by themselves when that monitor is
/// plugged in again (and at the next launch, if they were on).
final class DisplayMap: ObservableObject {
    static let shared = DisplayMap()

    struct Assignment: Codable, Equatable {
        var key: String
        var name: String
        var source: BusSource
        var pin: DesktopPin = .allDesktops
        var on = true
    }

    @Published private(set) var assignments: [String: Assignment] = [:]
    private var windows: [String: (window: NSWindow, slot: Int)] = [:]
    private weak var engine: SwitcherEngine?
    private var screenObserver: NSObjectProtocol?
    private static let defaultsKey = "displayMap"

    private init() {
        if let d = UserDefaults.standard.data(forKey: Self.defaultsKey),
           let a = try? JSONDecoder().decode([String: Assignment].self, from: d) { assignments = a }
    }

    private func save() {
        if let d = try? JSONEncoder().encode(assignments) { UserDefaults.standard.set(d, forKey: Self.defaultsKey) }
    }

    /// After launch: open the outputs that were on, and follow monitors being plugged in or out.
    func start(engine: SwitcherEngine) {
        self.engine = engine
        if screenObserver == nil {
            screenObserver = NotificationCenter.default.addObserver(
                forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
                // macOS reports a replug in several steps; settle first
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { self?.reconcile() }
            }
        }
        reconcile()
    }

    // MARK: - Editing

    func assignment(for screen: NSScreen) -> Assignment? { assignments[MonitorIdentity.of(screen).key] }

    /// nil source = this monitor shows nothing.
    func set(source: BusSource?, for screen: NSScreen) {
        let id = MonitorIdentity.of(screen)
        if let s = source {
            var a = assignments[id.key] ?? Assignment(key: id.key, name: id.name, source: s)
            a.source = s
            a.name = id.name
            a.on = true
            assignments[id.key] = a
        } else {
            assignments[id.key]?.on = false
        }
        save()
        reconcile(reopen: id.key)
    }

    func set(pin: DesktopPin, for screen: NSScreen) {
        let key = MonitorIdentity.of(screen).key
        guard assignments[key] != nil else { return }
        assignments[key]?.pin = pin
        save()
        reconcile(reopen: key)
    }

    /// Source by monitor number (1-based, System Settings order) — API.
    func set(source: BusSource?, monitor n: Int) -> Bool {
        let screens = NSScreen.screens
        guard screens.indices.contains(n - 1) else { return false }
        let s = screens[n - 1]
        guard s != FullscreenOutput.switcherWindow?.screen else { return false }
        set(source: source, for: s)
        return true
    }

    func isShowing(_ screen: NSScreen) -> Bool { windows[MonitorIdentity.of(screen).key] != nil }

    var showingCount: Int { windows.count }

    /// Assigned and on, but the monitor is not connected right now.
    var waiting: [Assignment] {
        assignments.values.filter { a in a.on && MonitorIdentity.screen(forKey: a.key) == nil }.sorted { $0.name < $1.name }
    }

    // MARK: - Windows

    /// Opens/closes windows so they match the assignments and the connected monitors.
    func reconcile(reopen key: String? = nil) {
        guard let engine = engine else { return }
        if let key = key, let w = windows[key] { close(key, w) }
        let switcherScreen = FullscreenOutput.switcherWindow?.screen
        // close: off, unplugged, or now the switcher's own screen
        for (k, w) in windows {
            let a = assignments[k]
            let screen = MonitorIdentity.screen(forKey: k)
            if a?.on != true || screen == nil || screen == switcherScreen { close(k, w) }
            else if let s = screen, w.window.frame != s.frame { w.window.setFrame(s.frame, display: true) }
        }
        // open
        for a in assignments.values where a.on && windows[a.key] == nil {
            guard let s = MonitorIdentity.screen(forKey: a.key), s != switcherScreen,
                  let slot = freeSlot() else { continue }
            open(a, on: s, slot: slot, engine: engine)
        }
        objectWillChange.send()
        engine.objectWillChange.send()
    }

    private func freeSlot() -> Int? {
        let used = Set(windows.values.map { $0.slot })
        return (0..<SwitcherEngine.displaySlotCount).first { !used.contains($0) }
    }

    private func open(_ a: Assignment, on screen: NSScreen, slot: Int, engine: SwitcherEngine) {
        let w = DisplayOutputWindow(contentRect: screen.frame, styleMask: [.borderless], backing: .buffered, defer: false, screen: screen)
        w.title = Lf("모니터 출력 — %@", a.name)
        w.backgroundColor = .black
        w.isOpaque = true
        w.hasShadow = false
        w.isReleasedWhenClosed = false
        switch a.pin {
        case .allDesktops:
            w.level = .screenSaver
            w.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        case .thisDesktop:
            w.level = .screenSaver      // above that monitor's menu bar; only this Space via the collection behaviour
            w.collectionBehavior = [.managed, .fullScreenAuxiliary, .ignoresCycle]
        }
        engine.setDisplaySource(slot, a.source)
        let src = engine.displaySlots[slot]
        w.contentView = NSHostingView(rootView: ZStack {
            Color.black
            MonitorView(fps: 120, source: { src.latest() })
        }.ignoresSafeArea())
        w.setFrame(screen.frame, display: true)
        w.orderFrontRegardless()
        windows[a.key] = (w, slot)
    }

    private func close(_ key: String, _ w: (window: NSWindow, slot: Int)) {
        w.window.orderOut(nil)
        w.window.contentView = nil
        w.window.close()
        engine?.setDisplaySource(w.slot, nil)
        windows[key] = nil
    }

    func closeAll() {
        for (k, w) in windows { close(k, w) }
    }

    // MARK: - Identify

    private var identifyWindows: [NSWindow] = []

    /// Big monitor numbers on every screen for 3 s (which cable is which).
    func identify() {
        identifyWindows.forEach { $0.close() }
        identifyWindows = NSScreen.screens.enumerated().map { (k, s) in
            let size = NSSize(width: 360, height: 240)
            let r = NSRect(x: s.frame.midX - size.width / 2, y: s.frame.midY - size.height / 2, width: size.width, height: size.height)
            let w = NSWindow(contentRect: r, styleMask: [.borderless], backing: .buffered, defer: false)
            w.level = NSWindow.Level(rawValue: NSWindow.Level.screenSaver.rawValue + 1)
            w.backgroundColor = .clear
            w.isOpaque = false
            w.isReleasedWhenClosed = false
            w.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
            w.contentView = NSHostingView(rootView: VStack(spacing: 6) {
                Text("\(k + 1)").font(.system(size: 120, weight: .heavy)).foregroundColor(.white)
                Text(s.localizedName).font(.system(size: 18, weight: .semibold)).foregroundColor(.white.opacity(0.85))
                    .lineLimit(1).padding(.horizontal, 12)
            }
            .frame(width: size.width, height: size.height)
            .background(RoundedRectangle(cornerRadius: 24).fill(Color.black.opacity(0.78)))
            .overlay(RoundedRectangle(cornerRadius: 24).stroke(Color.orange, lineWidth: 3)))
            w.orderFrontRegardless()
            return w
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
            self?.identifyWindows.forEach { $0.orderOut(nil); $0.close() }
            self?.identifyWindows = []
        }
    }
}

/// Borderless output window; never takes keyboard focus away from the switcher.
private final class DisplayOutputWindow: NSWindow {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// Display ⚙ › "Monitor outputs": one row per connected monitor.
struct MonitorOutputsSection: View {
    @EnvironmentObject var engine: SwitcherEngine
    @ObservedObject var map = DisplayMap.shared
    let sources: [BusSource]
    let title: (BusSource) -> String

    var body: some View {
        let switcher = FullscreenOutput.switcherWindow?.screen
        let primary = FullscreenOutput.shared.isShowing ? FullscreenOutput.shared.currentScreen : nil
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(L("모니터별 출력")).font(.headline)
                Spacer()
                Button(L("모니터 번호 표시")) { map.identify() }
                    .help(L("각 모니터에 번호를 3초 동안 크게 띄웁니다"))
            }
            Text(L("연결된 모니터마다 다른 화면을 전체화면으로 내보냅니다. 케이블을 다시 꽂으면 같은 모니터를 찾아 자동으로 다시 켭니다."))
                .font(.caption).foregroundColor(.secondary).fixedSize(horizontal: false, vertical: true)
            ForEach(Array(NSScreen.screens.enumerated()), id: \.offset) { (k, s) in
                let a = map.assignment(for: s)
                let isSwitcher = s == switcher
                let isPrimary = s == primary
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Circle().fill(map.isShowing(s) ? Color.green : Color.gray.opacity(0.5)).frame(width: 7, height: 7)
                        Text("\(k + 1): \(s.localizedName)").font(.system(size: 12, weight: .semibold)).lineLimit(1)
                        Text("\(Int(s.frame.width))×\(Int(s.frame.height))").font(.caption).foregroundColor(.secondary)
                        Spacer(minLength: 0)
                    }
                    if isSwitcher {
                        Text(L("스위처 화면 — 위의 출력 창을 쓰세요")).font(.caption).foregroundColor(.secondary)
                    } else if isPrimary {
                        Text(L("위의 디스플레이 출력이 사용 중")).font(.caption).foregroundColor(.secondary)
                    } else {
                        HStack(spacing: 8) {
                            Picker("", selection: Binding<BusSource?>(
                                get: { (a?.on ?? false) ? a?.source : nil },
                                set: { map.set(source: $0, for: s) })) {
                                Text(L("끔")).tag(BusSource?.none)
                                ForEach(sources, id: \.self) { Text(title($0)).tag(BusSource?.some($0)) }
                            }
                            .labelsHidden()
                            .frame(minWidth: 160)
                            Picker("", selection: Binding<DesktopPin>(
                                get: { a?.pin ?? .allDesktops },
                                set: { map.set(pin: $0, for: s) })) {
                                ForEach(DesktopPin.allCases, id: \.self) { Text($0.title).tag($0) }
                            }
                            .labelsHidden()
                            .frame(minWidth: 150)
                            .disabled(a?.on != true)
                            .help(DesktopPin.help)
                        }
                    }
                }
                .padding(8)
                .background(RoundedRectangle(cornerRadius: 6).fill(Color.white.opacity(0.04)))
            }
            ForEach(map.waiting, id: \.key) { a in
                HStack(spacing: 6) {
                    Circle().fill(Color.orange).frame(width: 7, height: 7)
                    Text(Lf("%@ — 연결 안 됨 (다시 연결되면 %@ 자동 출력)", a.name, title(a.source)))
                        .font(.caption).foregroundColor(.orange).fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }
}
