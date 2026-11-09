import SwiftUI

/// Input ⚙ › PTZ: camera address, joystick, zoom rocker, speed, presets, "move to preset when put in Preview".
struct PTZPanel: View {
    @ObservedObject var ptz: PTZController
    @ViewState private var newName = ""

    var body: some View {
        Form {
            Section(L("카메라")) {
                Picker(L("연결 방식"), selection: $ptz.config.transport) {
                    ForEach(PTZTransport.allCases) { Text($0.label).tag($0) }
                }
                .onChange(of: ptz.config.transport) { _, t in ptz.config.port = t.defaultPort }
                if ptz.config.transport != .ndi {
                    // one setting per row, fields right-aligned like the rest of the grouped form
                    LabeledContent(L("IP 주소")) {
                        TextField("", text: $ptz.config.host, prompt: Text("192.168.0.40"))
                            .labelsHidden().multilineTextAlignment(.trailing).frame(width: 200)
                    }
                    LabeledContent(L("포트")) {
                        TextField("", value: $ptz.config.port, format: .number.grouping(.never))
                            .labelsHidden().multilineTextAlignment(.trailing).frame(width: 90)
                    }
                    LabeledContent(L("VISCA 주소")) {
                        Picker("", selection: $ptz.config.address) {
                            ForEach(1...7, id: \.self) { Text("\($0)").tag($0) }
                        }
                        .labelsHidden().frame(width: 90)
                    }
                    Toggle(L("프리셋 번호 0부터 (Sony)"), isOn: $ptz.config.presetZeroBased)
                } else {
                    Text(L("이 입력의 NDI 연결로 제어합니다 (NDI PTZ를 지원하는 카메라만).")).font(.caption).foregroundColor(.secondary)
                }
                HStack {
                    Circle().fill(ptz.isConnected ? Color.green : (ptz.cameraError != nil ? Color.orange : Color.secondary))
                        .frame(width: 8, height: 8)
                    Text(ptz.statusText).font(.caption)
                    Spacer()
                    Button(L("연결하기")) { ptz.reconnect() }
                }
            }

            Section(L("조작")) {
                HStack(alignment: .center, spacing: 24) {
                    PTZJoystick(ptz: ptz).frame(width: 140, height: 140)
                    VStack(alignment: .leading, spacing: 10) {
                        Text(L("줌")).font(.caption).foregroundColor(.secondary)
                        PTZZoomRocker(ptz: ptz).frame(width: 220, height: 28)
                        Text(L("속도")).font(.caption).foregroundColor(.secondary)
                        Slider(value: $ptz.config.panTiltSpeed, in: 0.05...1).labelsHidden().frame(width: 220)
                        HStack {
                            Button(L("홈")) { ptz.home() }
                            Button(L("자동 초점")) { ptz.focusAuto() }
                        }
                    }
                }
                .frame(maxWidth: .infinity)
            }

            Section(L("프리셋")) {
                if ptz.config.presets.isEmpty {
                    Text(L("저장된 프리셋이 없습니다. 카메라를 원하는 위치로 옮긴 뒤 이름을 넣고 ‘현재 위치 저장’을 누르세요."))
                        .font(.caption).foregroundColor(.secondary)
                } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack {
                        ForEach(ptz.config.presets) { p in
                            Button("\(p.number) \(p.name)") { ptz.recallPreset(p.number) }
                                .buttonStyle(.borderedProminent)
                                .tint(ptz.activePreset == p.number ? .accentColor : .gray)
                                .contextMenu {
                                    Button(L("현재 위치로 다시 저장")) { ptz.storePreset(p.number, name: p.name) }
                                    Button(L("삭제"), role: .destructive) { ptz.deletePreset(p.number) }
                                }
                        }
                    }
                }
                }
                HStack {
                    TextField("", text: $newName, prompt: Text(L("새 프리셋 이름"))).labelsHidden()
                    Button(L("+ 현재 위치 저장")) {
                        _ = ptz.saveNewPreset(name: newName.isEmpty ? nil : newName)
                        newName = ""
                    }
                }
                Toggle(L("Preview에 올리면 프리셋으로 이동"), isOn: $ptz.config.recallOnPreview)
                if ptz.config.recallOnPreview, !ptz.config.presets.isEmpty {
                    Picker(L("이동할 프리셋"), selection: Binding(get: { ptz.config.previewPreset ?? ptz.config.presets[0].number },
                                                             set: { ptz.config.previewPreset = $0 })) {
                        ForEach(ptz.config.presets) { Text("\($0.number) \($0.name)").tag($0.number) }
                    }
                }
                Text(L("Program에 나가 있는 카메라는 움직이지 않습니다. 프리셋은 우클릭으로 다시 저장·삭제합니다."))
                    .font(.caption).foregroundColor(.secondary)
            }
        }
        .formStyle(.grouped)
        .textFieldStyle(.roundedBorder)
        .onDisappear { ptz.stopMove(); ptz.zoomStop() }
    }
}

/// Round joystick: drag the knob, release to stop. Sends a keep-alive every 200 ms while held still
/// (the engine stops the camera by itself if no update arrives for 500 ms).
struct PTZJoystick: View {
    @ObservedObject var ptz: PTZController
    @ViewState private var offset: CGSize = .zero
    @ViewState private var dragging = false
    private let keepAlive = Timer.publish(every: 0.2, on: .main, in: .common).autoconnect()

    var body: some View {
        GeometryReader { g in
            let r = min(g.size.width, g.size.height) / 2
            ZStack {
                Circle().stroke(Color.secondary.opacity(0.5), lineWidth: 1)
                Circle().fill(Color.primary.opacity(0.85)).frame(width: r * 0.42, height: r * 0.42).offset(offset)
            }
            .contentShape(Circle())
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { v in
                    dragging = true
                    var d = CGSize(width: v.location.x - r, height: v.location.y - r)
                    let len = sqrt(d.width * d.width + d.height * d.height), maxLen = r * 0.75
                    if len > maxLen { d = CGSize(width: d.width / len * maxLen, height: d.height / len * maxLen) }
                    offset = d
                    send(maxLen)
                }
                .onEnded { _ in
                    dragging = false
                    offset = .zero
                    ptz.stopMove()
                })
            .onReceive(keepAlive) { _ in if dragging { send(r * 0.75) } }
        }
    }

    private func send(_ maxLen: CGFloat) {
        ptz.move(panSpeed: Double(offset.width / maxLen), tiltSpeed: Double(-offset.height / maxLen))
    }
}

/// Spring-back zoom rocker: left = wide, right = tele, speed by distance from the centre.
struct PTZZoomRocker: View {
    @ObservedObject var ptz: PTZController
    @ViewState private var x: CGFloat = 0
    @ViewState private var dragging = false
    private let keepAlive = Timer.publish(every: 0.2, on: .main, in: .common).autoconnect()

    var body: some View {
        GeometryReader { g in
            let half = g.size.width / 2
            ZStack {
                Capsule().fill(Color.secondary.opacity(0.25))
                HStack { Image(systemName: "minus.magnifyingglass"); Spacer(); Image(systemName: "plus.magnifyingglass") }
                    .font(.caption).foregroundColor(.secondary).padding(.horizontal, 8)
                Capsule().fill(Color.primary.opacity(0.85)).frame(width: 36, height: g.size.height - 6).offset(x: x)
            }
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { v in
                    dragging = true
                    x = max(-half + 18, min(half - 18, v.location.x - half))
                    ptz.zoom(Double(x / (half - 18)))
                }
                .onEnded { _ in
                    dragging = false
                    x = 0
                    ptz.zoomStop()
                })
            .onReceive(keepAlive) { _ in if dragging { ptz.zoom(Double(x / (half - 18))) } }
        }
    }
}
