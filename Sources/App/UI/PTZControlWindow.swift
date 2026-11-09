import SwiftUI
import AppKit

/// Tool window (bottom bar › PTZ): pan/tilt/zoom/focus/presets for one PTZ camera, with keyboard control
/// while the window is in front — WASD move, Q/E zoom in/out, Z/X focus near/far, F auto focus,
/// 1–9 select a PTZ camera (shown as live pictures on top), U I O / J K L / M , . recall presets 1–9,
/// Tab next camera, Shift = fast. Releasing a key stops; leaving the window stops everything.
struct PTZControlWindow: View {
    @EnvironmentObject var engine: SwitcherEngine
    @AppStorage("ptzControlInput") private var selectedID = ""
    @AppStorage("ptzControlFollowPreview") private var followPreview = true

    /// Live inputs (where a PTZ camera can be), configured ones first.
    private var cameras: [InputSource] {
        let live = engine.inputs.filter { $0.isLiveSource }
        return live.filter { $0.config.ptz != nil || $0.kind == .ndi } + live.filter { $0.config.ptz == nil && $0.kind != .ndi }
    }

    /// Inputs with a PTZ camera connected (VISCA address set, or NDI) — the numbered live pictures, max 9.
    private var ptzCameras: [InputSource] {
        Array(engine.inputs.filter { i in
            if let c = i.config.ptz { return c.transport == .ndi || !c.host.isEmpty }
            return i.kind == .ndi
        }.prefix(9))
    }

    private var current: InputSource? {
        cameras.first { $0.id.uuidString == selectedID } ?? ptzCameras.first ?? cameras.first
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("PTZ Control").font(.headline)
                Spacer()
                Picker("", selection: Binding(get: { current?.id.uuidString ?? "" }, set: { selectedID = $0 })) {
                    if cameras.isEmpty { Text(L("PTZ로 쓸 수 있는 입력 없음")).tag("") }
                    ForEach(cameras) { i in Text("\(engine.number(of: i)) \(i.name)").tag(i.id.uuidString) }
                }
                .labelsHidden()
                .frame(width: 240)
                Toggle(L("Preview 따라가기"), isOn: $followPreview)
            }
            if !ptzCameras.isEmpty {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 150, maximum: 240), spacing: 8)], spacing: 8) {
                    ForEach(Array(ptzCameras.enumerated()), id: \.element.id) { k, i in
                        cameraTile(i, number: k + 1)
                    }
                }
            }
            if let input = current {
                PTZControlBody(ptz: PTZManager.shared.controller(for: input), inputName: input.name,
                               nextCamera: { nextCamera() }, selectCamera: { selectCamera($0) })
                    .id(input.id)
            } else {
                Text(L("Camera·NDI·SRT·캡처카드 입력을 추가한 뒤, 입력 ⚙ › PTZ에서 카메라를 연결하세요."))
                    .foregroundColor(.secondary)
                Spacer()
            }
        }
        .padding(16)
        .frame(minWidth: 680, minHeight: ptzCameras.isEmpty ? 470 : 640)
        .onAppear { PTZManager.shared.attach(engine: engine) }
        .onChange(of: engine.previewID) { _, id in
            guard followPreview, let id, let i = engine.input(withID: id), i.isLiveSource else { return }
            selectedID = id.uuidString
        }
    }

    /// Live picture of a PTZ camera input: number = its 1–9 key, red/green border = Program/Preview.
    private func cameraTile(_ i: InputSource, number: Int) -> some View {
        let selected = current?.id == i.id
        let tally: Color? = engine.programID == i.id ? .red : (engine.previewID == i.id ? .green : nil)
        return ZStack(alignment: .topLeading) {
            MonitorView(fps: 15) { i.monitorFrame() }
                .aspectRatio(16 / 9, contentMode: .fit)
                .background(Color.black)
            HStack(spacing: 4) {
                Text("\(number)").font(.system(size: 11, weight: .bold)).padding(.horizontal, 5)
                    .background(RoundedRectangle(cornerRadius: 3).fill(selected ? Color.accentColor : Color.black.opacity(0.7)))
                Text(i.name).font(.system(size: 11)).lineLimit(1)
                    .padding(.horizontal, 4).background(Color.black.opacity(0.55))
            }
            .foregroundColor(.white)
            .padding(5)
        }
        .overlay(RoundedRectangle(cornerRadius: 4)
            .stroke(selected ? Color.accentColor : (tally ?? Color.secondary.opacity(0.35)), lineWidth: selected || tally != nil ? 2 : 0.5))
        .clipShape(RoundedRectangle(cornerRadius: 4))
        .contentShape(Rectangle())
        .onTapGesture { selectedID = i.id.uuidString }
        .help(Lf("%@번 키로 선택", "\(number)"))
    }

    /// 1–9 keys: the numbered PTZ camera.
    private func selectCamera(_ n: Int) {
        let list = ptzCameras
        guard list.indices.contains(n - 1) else { return }
        selectedID = list[n - 1].id.uuidString
    }

    private func nextCamera() {
        let list = ptzCameras.isEmpty ? cameras : ptzCameras
        guard !list.isEmpty else { return }
        let k = list.firstIndex { $0.id.uuidString == (current?.id.uuidString ?? "") } ?? -1
        selectedID = list[(k + 1) % list.count].id.uuidString
    }
}

private struct PTZControlBody: View {
    @ObservedObject var ptz: PTZController
    let inputName: String
    let nextCamera: () -> Void
    let selectCamera: (Int) -> Void
    @ViewState private var newName = ""
    @StateObject private var keys = PTZKeyboard()

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 6) {
                Circle().fill(ptz.isConnected ? Color.green : (ptz.cameraError != nil ? Color.orange : Color.secondary))
                    .frame(width: 8, height: 8)
                Text(ptz.statusText).font(.caption)
                if ptz.config.transport != .ndi && ptz.config.host.isEmpty {
                    Text(L("· 입력 ⚙ › PTZ에서 카메라 IP를 넣으세요")).font(.caption).foregroundColor(.orange)
                }
                Spacer()
                Button(L("연결하기")) { ptz.reconnect() }
            }
            HStack(alignment: .top, spacing: 26) {
                VStack(spacing: 6) {
                    PTZJoystick(ptz: ptz).frame(width: 170, height: 170)
                    Text(L("팬 / 틸트 · W A S D · Shift = 빠르게")).font(.caption).foregroundColor(.secondary)
                }
                VStack(alignment: .leading, spacing: 14) {
                    row(L("줌"), hint: L("Q 인 · E 아웃")) { PTZZoomRocker(ptz: ptz).frame(width: 260, height: 28) }
                    row(L("포커스"), hint: L("Z 가까이 · X 멀리 · F 자동")) {
                        HStack {
                            HoldButton(title: L("◀ 가까이"), press: { ptz.focusNear() }, release: { ptz.focusStop() })
                            Button(L("자동")) { ptz.focusAuto() }
                            HoldButton(title: L("멀리 ▶"), press: { ptz.focusFar() }, release: { ptz.focusStop() })
                        }
                    }
                    row(L("속도"), hint: "\(Int(ptz.config.panTiltSpeed * 100))%") {
                        Slider(value: $ptz.config.panTiltSpeed, in: 0.05...1).labelsHidden().frame(width: 260)
                    }
                    Button(L("홈")) { ptz.home() }
                }
            }
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text(L("프리셋")).fontWeight(.semibold)
                    Spacer()
                    Text(L("U I O · J K L · M , . = 프리셋 1~9")).font(.caption).foregroundColor(.secondary)
                }
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack {
                        ForEach(ptz.config.presets) { p in
                            Button((PTZKeyboard.presetKeyLabel(p.number).map { "[\($0)] " } ?? "") + "\(p.number) \(p.name)") { ptz.recallPreset(p.number) }
                                .buttonStyle(.borderedProminent)
                                .tint(ptz.activePreset == p.number ? .accentColor : .gray)
                                .contextMenu {
                                    Button(L("현재 위치로 다시 저장")) { ptz.storePreset(p.number, name: p.name) }
                                    Button(L("삭제"), role: .destructive) { ptz.deletePreset(p.number) }
                                }
                        }
                    }
                }
                HStack {
                    TextField("", text: $newName, prompt: Text(L("새 프리셋 이름"))).labelsHidden().frame(width: 200)
                    Button(L("+ 현재 위치 저장")) {
                        _ = ptz.saveNewPreset(name: newName.isEmpty ? nil : newName)
                        newName = ""
                    }
                }
            }
            Text(L("이 창이 앞에 있을 때만 키가 동작합니다 · 키를 떼면 멈춤 · 창을 벗어나면 모든 움직임 정지"))
                .font(.caption).foregroundColor(.secondary)
        }
        .background(PTZKeyCatcher(keys: keys))
        .contentShape(Rectangle())
        .onTapGesture { NSApp.keyWindow?.makeFirstResponder(nil) }
        .onAppear { keys.bind(ptz: ptz, nextCamera: nextCamera, selectCamera: selectCamera) }
        .onDisappear { keys.stopAll() }
    }

    private func row<C: View>(_ title: String, hint: String, @ViewBuilder _ content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title)
                Spacer()
                Text(hint).font(.caption).foregroundColor(.secondary)
            }
            .frame(width: 260)
            content()
        }
    }
}

/// Button that acts while held (focus near/far).
private struct HoldButton: View {
    let title: String
    let press: () -> Void
    let release: () -> Void
    @ViewState private var down = false

    var body: some View {
        Text(title)
            .padding(.horizontal, 10).padding(.vertical, 4)
            .background(RoundedRectangle(cornerRadius: 5).fill(down ? Color.accentColor.opacity(0.6) : Color.secondary.opacity(0.2)))
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { _ in if !down { down = true; press() } }
                .onEnded { _ in down = false; release() })
    }
}

/// Keyboard state → PTZ commands. Keys are matched by physical key code, so they also work with a
/// Korean (or any) input source active.
final class PTZKeyboard: ObservableObject {
    private weak var ptz: PTZController?
    private var nextCamera: (() -> Void)?
    private var selectCamera: ((Int) -> Void)?
    private var held = Set<UInt16>()
    private var shift = false
    private var keepAlive: Timer?
    /// Axes the keyboard is currently driving — stops are sent only for these (no stop spam on idle axes).
    private var panTiltActive = false
    private var zoomActive = false

    static let w: UInt16 = 13, a: UInt16 = 0, s: UInt16 = 1, d: UInt16 = 2
    static let q: UInt16 = 12, e: UInt16 = 14, z: UInt16 = 6, x: UInt16 = 7, f: UInt16 = 3, tab: UInt16 = 48
    /// 1–9 (number row): select camera 1–9.
    static let digits: [UInt16: Int] = [18: 1, 19: 2, 20: 3, 21: 4, 23: 5, 22: 6, 26: 7, 28: 8, 25: 9]
    /// Right-hand 3×3 block → presets 1–9: U I O / J K L / M , .
    static let presetKeys: [UInt16: Int] = [32: 1, 34: 2, 31: 3, 38: 4, 40: 5, 37: 6, 46: 7, 43: 8, 47: 9]
    static let handled: Set<UInt16> = Set([w, a, s, d, q, e, z, x, f, tab]).union(digits.keys).union(presetKeys.keys)

    static func presetKeyLabel(_ n: Int) -> String? {
        ["U", "I", "O", "J", "K", "L", "M", ",", "."].indices.contains(n - 1) ? ["U", "I", "O", "J", "K", "L", "M", ",", "."][n - 1] : nil
    }

    func bind(ptz: PTZController, nextCamera: @escaping () -> Void, selectCamera: @escaping (Int) -> Void) {
        stopAll()
        self.ptz = ptz
        self.nextCamera = nextCamera
        self.selectCamera = selectCamera
    }

    /// Returns true when the key was used (the event is then swallowed).
    func keyDown(_ code: UInt16, isRepeat: Bool, shift: Bool) -> Bool {
        guard Self.handled.contains(code) else { return false }
        self.shift = shift
        if isRepeat { return true }   // held keys are tracked, OS auto-repeat is ignored
        if let n = Self.presetKeys[code] { ptz?.recallPreset(n); return true }
        if let n = Self.digits[code] { stopAll(); selectCamera?(n); return true }
        switch code {
        case Self.f: ptz?.focusAuto()
        case Self.tab: stopAll(); nextCamera?()
        case Self.z: held.insert(code); ptz?.focusNear()
        case Self.x: held.insert(code); ptz?.focusFar()
        default: held.insert(code); apply()
        }
        return true
    }

    func keyUp(_ code: UInt16) -> Bool {
        guard Self.handled.contains(code) else { return false }
        guard held.remove(code) != nil else { return true }
        if code == Self.z || code == Self.x { ptz?.focusStop() } else { apply() }
        return true
    }

    func shiftChanged(_ on: Bool) {
        guard shift != on else { return }
        shift = on
        apply()
    }

    /// Recompute pan/tilt and zoom from the held keys; keep the camera's dead-man fed while moving.
    private func apply() {
        guard let ptz else { return }
        let k = shift ? 1.0 : 0.6
        let pan = Double((held.contains(Self.d) ? 1 : 0) - (held.contains(Self.a) ? 1 : 0)) * k
        let tilt = Double((held.contains(Self.w) ? 1 : 0) - (held.contains(Self.s) ? 1 : 0)) * k
        let zoom = Double((held.contains(Self.q) ? 1 : 0) - (held.contains(Self.e) ? 1 : 0)) * k
        if pan == 0 && tilt == 0 {
            if panTiltActive { ptz.stopMove(); panTiltActive = false }
        } else { ptz.move(panSpeed: pan, tiltSpeed: tilt); panTiltActive = true }
        if zoom == 0 {
            if zoomActive { ptz.zoomStop(); zoomActive = false }
        } else { ptz.zoom(zoom); zoomActive = true }
        let moving = pan != 0 || tilt != 0 || zoom != 0
        if moving && keepAlive == nil {
            keepAlive = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in self?.apply() }
        } else if !moving {
            keepAlive?.invalidate()
            keepAlive = nil
        }
    }

    func stopAll() {
        let hadFocus = held.contains(Self.z) || held.contains(Self.x)
        held.removeAll()
        keepAlive?.invalidate()
        keepAlive = nil
        if panTiltActive { ptz?.stopMove() }
        if zoomActive { ptz?.zoomStop() }
        panTiltActive = false
        zoomActive = false
        if hadFocus { ptz?.focusStop() }
    }
}

/// Installs a local key monitor while its window is key; stops everything when the window loses focus.
private struct PTZKeyCatcher: NSViewRepresentable {
    let keys: PTZKeyboard

    func makeNSView(context: Context) -> CatcherView {
        let v = CatcherView()
        v.keys = keys
        return v
    }

    func updateNSView(_ v: CatcherView, context: Context) { v.keys = keys }

    final class CatcherView: NSView {
        var keys: PTZKeyboard?
        private var monitor: Any?
        private var resign: NSObjectProtocol?

        // The catcher holds keyboard focus so the preset-name field never grabs it when the window opens
        // (typing hotkeys into a text field — with a Korean input source they even turn into Hangul).
        override var acceptsFirstResponder: Bool { true }
        override func mouseDown(with event: NSEvent) { window?.makeFirstResponder(self) }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            teardown()
            guard let w = window else { return }
            DispatchQueue.main.async { [weak self] in
                guard let self, let w = self.window else { return }
                if !(w.firstResponder is NSText) || w.firstResponder === w { w.makeFirstResponder(self) }
            }
            monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp, .flagsChanged]) { [weak self] ev in
                guard let self, let keys = self.keys, ev.window === self.window, w.isKeyWindow else { return ev }
                // typing in a text field (preset name) keeps its keys; Esc / Return leave the field
                if w.firstResponder is NSText {
                    if ev.type == .keyDown && (ev.keyCode == 53 || ev.keyCode == 36) { w.makeFirstResponder(self); return ev.keyCode == 53 ? nil : ev }
                    return ev
                }
                if ev.modifierFlags.intersection([.command, .control, .option]).isEmpty == false { return ev }
                switch ev.type {
                case .keyDown: return keys.keyDown(ev.keyCode, isRepeat: ev.isARepeat, shift: ev.modifierFlags.contains(.shift)) ? nil : ev
                case .keyUp: return keys.keyUp(ev.keyCode) ? nil : ev
                case .flagsChanged: keys.shiftChanged(ev.modifierFlags.contains(.shift)); return ev
                default: return ev
                }
            }
            resign = NotificationCenter.default.addObserver(forName: NSWindow.didResignKeyNotification, object: w,
                                                            queue: .main) { [weak self] _ in self?.keys?.stopAll() }
        }

        private func teardown() {
            if let m = monitor { NSEvent.removeMonitor(m) }
            monitor = nil
            if let r = resign { NotificationCenter.default.removeObserver(r) }
            resign = nil
        }

        override func removeFromSuperview() {
            keys?.stopAll()
            teardown()
            super.removeFromSuperview()
        }

        deinit { teardown() }
    }
}
