import AppKit
import SwiftUI

/// Extra output windows ("Window 2", "Window 3", …): each a normal resizable window with its own source.
/// Window 1 is the Display output (FullscreenOutput), so the bottom-bar Display button and the API keep working.
/// Remembered across launches (source, on/off, place and size).
final class OutputWindows: NSObject, ObservableObject, NSWindowDelegate {
    static let shared = OutputWindows()

    struct Item: Codable, Identifiable, Equatable {
        var id = UUID()
        var number: Int
        var source: BusSource = .program
        var on = true
        var alwaysOnTop = false
        var lockAspect = true
        var frame: CGRect? = nil
        /// The operator's own name ("" = "Window N").
        var name = ""

        enum CodingKeys: String, CodingKey { case id, number, source, on, alwaysOnTop, lockAspect, frame, name }
        init(number: Int) { self.number = number }
        init(from d: Decoder) throws {
            let c = try d.container(keyedBy: CodingKeys.self)
            id = try c.decode(UUID.self, forKey: .id)
            number = try c.decode(Int.self, forKey: .number)
            source = try c.decodeIfPresent(BusSource.self, forKey: .source) ?? .program
            on = try c.decodeIfPresent(Bool.self, forKey: .on) ?? true
            alwaysOnTop = try c.decodeIfPresent(Bool.self, forKey: .alwaysOnTop) ?? false
            lockAspect = try c.decodeIfPresent(Bool.self, forKey: .lockAspect) ?? true
            frame = try c.decodeIfPresent(CGRect.self, forKey: .frame)
            name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
        }

        var defaultName: String { Lf("출력 창 %@", "\(number)") }
        var displayName: String { name.isEmpty ? defaultName : name }
    }

    /// Own name of window 1 (the Display output).
    static var windowOneName: String {
        get { UserDefaults.standard.string(forKey: "outputWindow1Name") ?? "" }
        set { UserDefaults.standard.set(newValue, forKey: "outputWindow1Name") }
    }

    @Published private(set) var items: [Item] = []
    private var open: [UUID: (window: OutputWindow, slot: Int)] = [:]
    private weak var engine: SwitcherEngine?
    private static let defaultsKey = "outputWindows"

    static func isOutputWindow(_ w: NSWindow) -> Bool { w is OutputWindow }

    private override init() {
        super.init()
        if let d = UserDefaults.standard.data(forKey: Self.defaultsKey),
           let a = try? JSONDecoder().decode([Item].self, from: d) { items = a }
    }

    private func save() {
        if let d = try? JSONEncoder().encode(items) { UserDefaults.standard.set(d, forKey: Self.defaultsKey) }
    }

    var openCount: Int { open.count }

    func start(engine: SwitcherEngine) {
        self.engine = engine
        reconcile()
    }

    func add(engine: SwitcherEngine) {
        self.engine = engine
        items.append(Item(number: (items.map(\.number).max() ?? 1) + 1))
        save()
        reconcile()
    }

    func remove(_ id: UUID) {
        items.removeAll { $0.id == id }
        save()
        reconcile()
    }

    func update(_ id: UUID, _ change: (inout Item) -> Void) {
        guard let k = items.firstIndex(where: { $0.id == id }) else { return }
        let old = items[k]
        change(&items[k])
        let new = items[k]
        save()
        if let w = open[id] {
            if (old.source == .talent) != (new.source == .talent) {
                close(id)                           // other kind of content: rebuilt by reconcile
            } else {
                if old.source != new.source { engine?.setDisplaySource(w.slot, new.source) }
                w.window.level = new.alwaysOnTop ? .floating : .normal
                w.window.contentAspectRatio = new.lockAspect ? NSSize(width: 16, height: 9) : .zero
                w.window.title = title(new)
            }
        }
        reconcile()
    }

    /// Opens/closes windows to match the items.
    func reconcile() {
        guard let engine else { return }
        for id in open.keys where items.first(where: { $0.id == id })?.on != true { close(id) }
        for item in items where item.on && open[item.id] == nil {
            guard let slot = engine.claimDisplaySlot() else { engine.lastMessage = L("출력이 너무 많습니다"); break }
            openWindow(item, slot: slot, engine: engine)
        }
        objectWillChange.send()
    }

    /// App quit: close without turning them off, so they come back at the next launch.
    func closeAll() {
        for id in Array(open.keys) { close(id) }
    }

    private func title(_ item: Item) -> String {
        item.displayName + " — " + (engine?.multiViewName(item.source) ?? item.source.label)
    }

    private func openWindow(_ item: Item, slot: Int, engine: SwitcherEngine) {
        let screen = NSScreen.main ?? NSScreen.screens[0]
        let v = screen.visibleFrame
        let frame = item.frame.flatMap { f in NSScreen.screens.contains { $0.visibleFrame.intersects(f) } ? f : nil }
            ?? NSRect(x: v.midX - 480 + CGFloat(item.number * 24), y: v.midY - 270 - CGFloat(item.number * 24), width: 960, height: 540)
        let w = OutputWindow(contentRect: frame, styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                             backing: .buffered, defer: false)
        w.title = title(item)
        w.titlebarAppearsTransparent = true
        w.backgroundColor = .black
        w.isReleasedWhenClosed = false
        w.level = item.alwaysOnTop ? .floating : .normal
        // never a macOS full-screen Space (hiding one leaves an empty black desktop); green button = zoom
        w.collectionBehavior = [.fullScreenAuxiliary, .moveToActiveSpace, .fullScreenNone]
        w.minSize = NSSize(width: 320, height: 180)
        w.contentAspectRatio = item.lockAspect ? NSSize(width: 16, height: 9) : .zero
        w.identifier = NSUserInterfaceItemIdentifier("output-\(item.id.uuidString)")
        if item.source == .talent {
            engine.setDisplaySource(slot, nil)
            w.contentView = NSHostingView(rootView: TalentDisplayView(cue: TalentCue.shared).ignoresSafeArea())
        } else {
            engine.setDisplaySource(slot, item.source)
            let src = engine.displaySlots[slot]
            w.contentView = NSHostingView(rootView: ZStack { Color.black; MonitorView(fps: 120, source: { src.latest() }) }.ignoresSafeArea())
        }
        w.setFrame(frame, display: true)
        w.delegate = self
        w.orderFront(nil)
        open[item.id] = (w, slot)
    }

    private func close(_ id: UUID) {
        guard let w = open[id] else { return }
        open[id] = nil
        w.window.delegate = nil
        w.window.orderOut(nil)
        w.window.contentView = nil
        w.window.close()
        engine?.releaseDisplaySlot(w.slot)
    }

    private func id(of window: NSWindow) -> UUID? { open.first { $0.value.window === window }?.key }

    private func remember(_ n: Notification) {
        guard let w = n.object as? NSWindow, let id = id(of: w), let k = items.firstIndex(where: { $0.id == id }) else { return }
        items[k].frame = w.frame
        save()
    }

    func windowDidMove(_ n: Notification) { remember(n) }
    func windowDidEndLiveResize(_ n: Notification) { remember(n) }

    /// The red button: the window is turned off (stays in the list).
    func windowWillClose(_ n: Notification) {
        guard let w = n.object as? NSWindow, let id = id(of: w) else { return }
        remember(n)
        DispatchQueue.main.async { self.update(id) { $0.on = false } }
    }
}

final class OutputWindow: NSWindow {}

// MARK: - Output panel (bottom bar Display ⚙)

/// One place for every output: each connected monitor (on/off + what it shows) and the output windows.
struct DisplaySettingsPanel: View {
    @ObservedObject private var displayOutput = FullscreenOutput.shared   // display output state (not via engine refresh)
    @Environment(SwitcherEngine.self) var engine
    @ObservedObject private var map = DisplayMap.shared
    @ObservedObject private var windows = OutputWindows.shared

    private var sources: [BusSource] {
        [.program, .clean, .preview] + engine.multiViewSources + [.talent] + engine.inputs.map { .input($0.id) }
    }

    private func sourceTitle(_ src: BusSource) -> String {
        if case .input(let id) = src, let i = engine.input(withID: id) { return "\(engine.number(of: i)). \(i.name)" }
        if let n = engine.multiViewName(src) { return n }
        return src.label
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text(L("출력")).font(.headline)
                Spacer()
                Button(L("모니터 번호 표시")) { map.identify() }
                    .help(L("각 모니터에 번호를 3초 동안 크게 띄웁니다"))
            }
            section(L("연결된 모니터")) {
                ForEach(Array(NSScreen.screens.enumerated()), id: \.offset) { k, s in monitorRow(k + 1, s) }
                ForEach(map.waiting, id: \.key) { a in
                    row(icon: AnyView(MonitorBadge(number: nil, on: false)), name: Text(a.name),
                        detail: Lf("연결 안 됨 — 다시 연결되면 %@ 자동 출력", sourceTitle(a.source)), detailColor: .orange) {
                        Button(L("잊기")) { map.forget(a.key) }.controlSize(.small)
                    }
                }
            }
            section(L("출력 창 목록")) {
                windowOneRow
                ForEach(windows.items) { item in extraWindowRow(item) }
                Button { windows.add(engine: engine) } label: {
                    Label(L("새 출력 창"), systemImage: "plus")
                }
                .buttonStyle(.borderless)
                .padding(.horizontal, 10).padding(.vertical, 8)
            }
            Text(L("모니터를 켜면 그 화면 전체에 출력됩니다. 케이블을 다시 꽂으면 같은 모니터를 찾아 다시 켭니다. 출력 창 1의 초록 버튼은 창이 있는 화면을 채웁니다 (Esc로 돌아오기)."))
                .font(.caption).foregroundColor(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        .padding(16)
        .frame(width: 520)
    }

    // MARK: Monitors

    @ViewBuilder
    private func monitorRow(_ number: Int, _ s: NSScreen) -> some View {
        let fo = FullscreenOutput.shared
        let isSwitcher = s == FullscreenOutput.switcherWindow?.screen
        let foHere = fo.fillsScreen && fo.currentScreen == s          // Display output covers this monitor
        let a = map.assignment(for: s)
        let on = foHere || (!isSwitcher && map.isShowing(s))
        let source = foHere ? fo.source : (a?.source ?? .program)
        let custom = map.customName(s)
        let detail = (custom.isEmpty ? "" : s.localizedName + " · ")
            + "\(Int(s.frame.width))×\(Int(s.frame.height))"
            + (isSwitcher ? " · " + L("스위처 화면") : "")
            + (foHere ? " · " + L("출력 창 1") : "")
        row(icon: AnyView(MonitorBadge(number: number, on: on)),
            name: NameField(text: custom, placeholder: s.localizedName) { map.setCustomName($0, for: s) }, detail: detail) {
            if isSwitcher && !foHere {
                Text(L("스위처가 있는 화면")).font(.caption).foregroundColor(.secondary)
                    .help(L("스위처를 가리지 않도록 이 화면은 꺼져 있습니다. 출력 창 1의 초록 버튼으로 이 화면을 채울 수 있습니다."))
            } else {
                sourcePicker(source) { new in
                    if foHere { fo.setSource(new, engine: engine) } else { map.set(source: new, for: s, turnOn: on) }
                }
                if !foHere {
                    Menu {
                        Picker(L("데스크탑"), selection: Binding(get: { a?.pin ?? .allDesktops }, set: { map.set(pin: $0, for: s) })) {
                            ForEach(DesktopPin.allCases, id: \.self) { Text($0.title).tag($0) }
                        }
                        .pickerStyle(.inline)
                    } label: { Image(systemName: "ellipsis.circle") }
                    .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                    .disabled(a == nil)
                    .help(DesktopPin.help)
                }
                Toggle("", isOn: Binding(get: { on }, set: { want in
                    if foHere { if !want { fo.hide(); displayOutput.objectWillChange.send() } }
                    else { map.set(source: want ? source : nil, for: s) }
                }))
                .toggleStyle(.switch).labelsHidden().controlSize(.small)
            }
        }
    }

    // MARK: Windows

    private var windowOneRow: some View {
        let fo = FullscreenOutput.shared
        let custom = OutputWindows.windowOneName
        return row(icon: AnyView(WindowBadge(on: fo.showsWindow)),
                   name: NameField(text: custom, placeholder: L("출력 창 1")) { OutputWindows.windowOneName = $0; displayOutput.objectWillChange.send() },
                   detail: (custom.isEmpty ? "" : L("출력 창 1") + " · ") + L("하단 Display 버튼")) {
            sourcePicker(fo.source) { fo.setSource($0, engine: engine) }
            Menu {
                Toggle(L("항상 위에 표시"), isOn: Binding(get: { fo.alwaysOnTop }, set: { fo.alwaysOnTop = $0; displayOutput.objectWillChange.send() }))
                Toggle(L("16:9 비율 고정"), isOn: Binding(get: { fo.lockAspect }, set: { fo.lockAspect = $0; displayOutput.objectWillChange.send() }))
            } label: { Image(systemName: "ellipsis.circle") }
            .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
            Toggle("", isOn: Binding(get: { fo.showsWindow }, set: { want in
                if want { fo.open(.window, engine: engine) } else { fo.hide() }
                displayOutput.objectWillChange.send()
            }))
            .toggleStyle(.switch).labelsHidden().controlSize(.small)
        }
    }

    private func extraWindowRow(_ item: OutputWindows.Item) -> some View {
        row(icon: AnyView(WindowBadge(on: item.on)),
            name: NameField(text: item.name, placeholder: item.defaultName) { v in windows.update(item.id) { $0.name = v } },
            detail: item.name.isEmpty ? nil : item.defaultName) {
            sourcePicker(item.source) { s in windows.update(item.id) { $0.source = s } }
            Menu {
                Toggle(L("항상 위에 표시"), isOn: Binding(get: { item.alwaysOnTop }, set: { v in windows.update(item.id) { $0.alwaysOnTop = v } }))
                Toggle(L("16:9 비율 고정"), isOn: Binding(get: { item.lockAspect }, set: { v in windows.update(item.id) { $0.lockAspect = v } }))
                Divider()
                Button(L("삭제"), role: .destructive) { windows.remove(item.id) }
            } label: { Image(systemName: "ellipsis.circle") }
            .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
            Toggle("", isOn: Binding(get: { item.on }, set: { v in windows.update(item.id) { $0.on = v } }))
                .toggleStyle(.switch).labelsHidden().controlSize(.small)
        }
    }

    // MARK: Building blocks

    private func sourcePicker(_ current: BusSource, _ set: @escaping (BusSource) -> Void) -> some View {
        Picker("", selection: Binding(get: { current }, set: set)) {
            ForEach(sources, id: \.self) { Text(sourceTitle($0)).tag($0) }
        }
        .labelsHidden()
        .frame(width: 170)
    }

    private func section<C: View>(_ title: String, @ViewBuilder _ content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title.uppercased()).font(.system(size: 11, weight: .semibold)).foregroundColor(.secondary)
            VStack(spacing: 0) { content() }
                .background(RoundedRectangle(cornerRadius: 8).fill(Color.white.opacity(0.04)))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.white.opacity(0.08)))
        }
    }

    private func row<N: View, T: View>(icon: AnyView, name: N, detail: String?, detailColor: Color = .secondary,
                                       @ViewBuilder trailing: () -> T) -> some View {
        HStack(spacing: 10) {
            icon
            VStack(alignment: .leading, spacing: 1) {
                name.font(.system(size: 13, weight: .semibold)).lineLimit(1)
                if let detail { Text(detail).font(.caption).foregroundColor(detailColor).lineLimit(1) }
            }
            Spacer(minLength: 8)
            trailing()
        }
        .padding(.horizontal, 10).padding(.vertical, 8)
        .overlay(alignment: .bottom) { Rectangle().fill(Color.white.opacity(0.06)).frame(height: 1) }
    }
}

/// Click to rename; empty = the original name (shown greyed as the placeholder).
private struct NameField: View {
    let placeholder: String
    let commit: (String) -> Void
    @ViewState private var draft: String

    init(text: String, placeholder: String, commit: @escaping (String) -> Void) {
        self.placeholder = placeholder
        self.commit = commit
        _draft = ViewState(wrappedValue: text)
    }

    var body: some View {
        TextField("", text: $draft, prompt: Text(placeholder).foregroundColor(.primary))
            .textFieldStyle(.plain)
            .onSubmit { commit(draft) }
            .onChange(of: draft) { commit($0) }
            .help(L("클릭해서 이름 바꾸기 — 비우면 원래 이름"))
    }
}

/// Small monitor glyph with its macOS number; green when it is on air.
private struct MonitorBadge: View {
    let number: Int?
    let on: Bool
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 3).fill(on ? Theme.program.opacity(0.85) : Color.white.opacity(0.10))
                .frame(width: 30, height: 20)
            Text(number.map(String.init) ?? "–").font(.system(size: 11, weight: .bold)).foregroundColor(.white)
        }
        .frame(width: 30, height: 24, alignment: .top)
        .overlay(alignment: .bottom) { Rectangle().fill(Color.white.opacity(0.25)).frame(width: 10, height: 3) }
    }
}

private struct WindowBadge: View {
    let on: Bool
    var body: some View {
        Image(systemName: "macwindow").font(.system(size: 16))
            .foregroundColor(on ? Theme.program : .secondary)
            .frame(width: 30, height: 24)
    }
}
