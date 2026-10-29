import SwiftUI
import AppKit

/// Settings → 단축키: vMix-style shortcut list. "키 입력" captures the next key press.
struct ShortcutsEditor: View {
    @EnvironmentObject var engine: SwitcherEngine
    @ObservedObject var manager = ShortcutManager.shared
    @ViewState private var recordingID: UUID? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(L("키(조합)에 vMix 함수를 지정합니다. 입력란·웹페이지에 타이핑 중일 때는 동작하지 않습니다. 기본 단축키(Space=Cut, Return=Quick Play, 1~9=Preview, ⌘1~9=Cut)보다 우선합니다."))
                .font(.caption).foregroundColor(.secondary)
            List {
                ForEach($manager.items) { $sc in
                    HStack(spacing: 8) {
                        Button(recordingID == sc.id ? L("키를 누르세요…") : sc.label) { record(sc.id) }
                            .frame(width: 130)
                            .foregroundColor(recordingID == sc.id ? .orange : .primary)
                        Picker("", selection: $sc.function) {
                            ForEach(functionChoices(sc.function), id: \.self) { Text($0).tag($0) }
                        }
                        .labelsHidden()
                        .frame(width: 210)
                        Picker("", selection: $sc.input) {
                            Text(L("입력 없음")).tag("")
                            ForEach(engine.inputs) { i in
                                Text("\(engine.number(of: i)). \(i.name)").tag(i.id.uuidString)
                            }
                        }
                        .labelsHidden()
                        .frame(width: 200)
                        TextField("Value", text: $sc.value).textFieldStyle(.roundedBorder).frame(width: 120)
                        Spacer()
                        Button(role: .destructive) { manager.items.removeAll { $0.id == sc.id } } label: {
                            Image(systemName: "trash")
                        }
                        .buttonStyle(.borderless)
                    }
                }
            }
            HStack {
                Button(L("단축키 추가")) {
                    let sc = UserShortcut(key: "", function: "Cut")
                    manager.items.append(sc)
                    record(sc.id)
                }
                Button(L("vMix 기본 세트 추가 (F1~F4 오버레이, F5 녹화, F6 송출, F12 FTB)")) { addDefaults() }
                Spacer()
            }
        }
        .padding()
        .onDisappear { manager.capture = nil }
    }

    private func functionChoices(_ current: String) -> [String] {
        var l = ShortcutManager.commonFunctions
        if !current.isEmpty && !l.contains(current) { l.insert(current, at: 0) }
        return l
    }

    private func record(_ id: UUID) {
        recordingID = id
        manager.capture = { ev in
            let f = ev.modifierFlags.intersection(.deviceIndependentFlagsMask)
            if let i = manager.items.firstIndex(where: { $0.id == id }) {
                manager.items[i].key = ShortcutManager.keyName(ev)
                manager.items[i].command = f.contains(.command)
                manager.items[i].shift = f.contains(.shift)
                manager.items[i].option = f.contains(.option)
                manager.items[i].control = f.contains(.control)
            }
            manager.capture = nil
            recordingID = nil
        }
    }

    private func addDefaults() {
        let d: [UserShortcut] = [
            UserShortcut(key: "F1", function: "OverlayInput1"), UserShortcut(key: "F2", function: "OverlayInput2"),
            UserShortcut(key: "F3", function: "OverlayInput3"), UserShortcut(key: "F4", function: "OverlayInput4"),
            UserShortcut(key: "F5", function: "StartStopRecording"), UserShortcut(key: "F6", function: "StartStopStreaming"),
            UserShortcut(key: "F12", function: "FadeToBlack"),
        ]
        for s in d where !manager.items.contains(where: { $0.key == s.key && !$0.command && !$0.shift }) {
            manager.items.append(s)
        }
    }
}
