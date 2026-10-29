import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// Input Properties › Triggers (vMix Triggers): run functions on air / off air / at the end / at countdown 0.
struct TriggersEditor: View {
    @EnvironmentObject var engine: SwitcherEngine
    @ObservedObject var input: InputSource

    static let common = ["Fade", "Cut", "CutDirect", "PreviewInput", "OverlayInput1In", "OverlayInput1Out", "OverlayInput2In",
                         "OverlayInput2Out", "OverlayInputAllOff", "Play", "Pause", "Restart", "NextItem", "AudioOn", "AudioOff",
                         "SetVolume", "StartCountdown", "StopCountdown", "SetText", "StartRecording", "StopRecording",
                         "Stinger1", "FadeToBlack", "RundownNext"]

    var body: some View {
        Form {
            Section {
                Text(L("이 입력에 일이 생기면 기능을 자동으로 실행합니다. 예: 영상이 끝나면(OnCompletion) 카메라1로 Fade, 오버레이로 올라가면 BGM 볼륨 낮추기, 카운트다운이 0이 되면 본방송 영상으로 전환."))
                    .font(.caption).foregroundColor(.secondary)
            }
            ForEach(TriggerEvent.allCases) { ev in
                let idx = input.triggers.indices.filter { input.triggers[$0].event == ev }
                if !idx.isEmpty || relevant(ev) {
                    Section(ev.label) {
                        ForEach(idx, id: \.self) { i in row(i) }
                        Menu(L("기능 추가")) {
                            ForEach(Self.common, id: \.self) { f in
                                Button(f) {
                                    let inp = Self.selfFunctions.contains(f) ? InputTrigger.selfInput : ""
                                    input.triggers.append(InputTrigger(event: ev, action: RundownAction(function: f, input: inp)))
                                }
                            }
                        }
                        .fixedSize()
                    }
                }
            }
            Section {
                Text(L("입력에 '이 입력'을 고르면 트리거가 달린 입력 자신을 가리킵니다. 값·추가 매개변수는 vMix API와 같습니다 (예: Duration=1000)."))
                    .font(.caption).foregroundColor(.secondary)
            }
        }
        .formStyle(.grouped)
        .textFieldStyle(.roundedBorder)
    }

    static let selfFunctions: Set<String> = ["Play", "Pause", "Restart", "NextItem", "AudioOn", "AudioOff", "SetVolume",
                                             "StartCountdown", "StopCountdown", "SetText"]

    private func relevant(_ e: TriggerEvent) -> Bool {
        switch e {
        case .completion: return input.supportsTransport
        case .countdownCompleted: return (input as? TitleInput)?.document.fields.contains { $0.mode == .countdown } ?? false
        default: return true
        }
    }

    @ViewBuilder private func row(_ i: Int) -> some View {
        if input.triggers.indices.contains(i) {
            HStack(spacing: 6) {
                Toggle("", isOn: $input.triggers[i].enabled).labelsHidden()
                TextField(L("기능"), text: $input.triggers[i].action.function).frame(width: 140)
                Picker("", selection: $input.triggers[i].action.input) {
                    Text(L("입력 없음")).tag("")
                    Text(L("이 입력")).tag(InputTrigger.selfInput)
                    ForEach(engine.inputs) { inp in Text("\(engine.number(of: inp)). \(inp.name)").tag(inp.id.uuidString) }
                    let cur = input.triggers[i].action.input
                    if !cur.isEmpty && cur != InputTrigger.selfInput && !engine.inputs.contains(where: { $0.id.uuidString == cur }) {
                        Text(cur).tag(cur)
                    }
                }
                .labelsHidden().frame(width: 150)
                TextField(L("값"), text: $input.triggers[i].action.value).frame(width: 70)
                TextField(L("추가 (Duration=…)"), text: $input.triggers[i].action.extra).frame(width: 110)
                Stepper(Lf("%@ms 후", "\(input.triggers[i].delayMs)"), value: $input.triggers[i].delayMs, in: 0...600_000, step: 100)
                    .fixedSize()
                Button { test(i) } label: { Image(systemName: "play.circle") }
                    .buttonStyle(.borderless).help(L("지금 실행해 보기"))
                Button(role: .destructive) { input.triggers.remove(at: i) } label: { Image(systemName: "minus.circle") }
                    .buttonStyle(.borderless)
            }
        }
    }

    private func test(_ i: Int) {
        let t = input.triggers[i]
        var q = t.action.query
        if t.action.input == InputTrigger.selfInput { q["input"] = input.id.uuidString }
        if let e = APIProcessor.perform(t.action.function, q, engine) { engine.lastMessage = "\(t.action.function): \(e)" }
    }
}

/// Input Properties › List (vMix List input): files played one after another.
struct ListEditor: View {
    @ObservedObject var input: FFmpegInput
    @ViewState private var selection: Int? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Button { addFiles() } label: { Label(L("파일 추가…"), systemImage: "plus") }
                Button { if let s = selection { input.removeItem(s); selection = nil } } label: { Label(L("삭제"), systemImage: "minus") }
                    .disabled(selection == nil)
                Button { if let s = selection, s > 0 { input.moveItem(from: s, to: s - 1); selection = s - 1 } } label: { Image(systemName: "arrow.up") }
                    .disabled((selection ?? 0) == 0)
                Button { if let s = selection, s + 1 < input.playlist.count { input.moveItem(from: s, to: s + 2); selection = s + 1 } } label: { Image(systemName: "arrow.down") }
                    .disabled(selection == nil || selection! + 1 >= input.playlist.count)
                Button(L("섞기")) { input.shuffleList() }.disabled(!input.isList)
                Spacer()
                Button { input.previousItem() } label: { Image(systemName: "backward.end.fill") }.disabled(!input.isList)
                Button { input.nextItem() } label: { Image(systemName: "forward.end.fill") }.disabled(!input.isList)
            }
            List(selection: $selection) {
                if input.playlist.isEmpty {
                    Text(L("단일 파일 — [파일 추가]로 여러 파일을 넣으면 리스트 입력이 됩니다.")).foregroundColor(.secondary)
                }
                ForEach(Array(input.playlist.enumerated()), id: \.offset) { k, path in
                    HStack {
                        Image(systemName: k == input.playlistIndex ? "play.fill" : "film")
                            .foregroundColor(k == input.playlistIndex ? Theme.program : .secondary)
                            .frame(width: 16)
                        Text("\(k + 1). " + (path as NSString).lastPathComponent)
                            .fontWeight(k == input.playlistIndex ? .semibold : .regular)
                        Spacer()
                        Text((path as NSString).deletingLastPathComponent).font(.caption).foregroundColor(.secondary).lineLimit(1)
                    }
                    .tag(k)
                    .contentShape(Rectangle())
                    .onTapGesture(count: 2) { input.selectItem(k, play: true) }
                }
            }
            .frame(minHeight: 260)
            Toggle(L("리스트 반복 (마지막 다음에 처음으로)"), isOn: $input.looping)
            Text(L("더블클릭 = 그 항목 재생. 한 파일이 끝나면 다음 파일이 자동으로 이어집니다. 마지막 파일이 끝나면 OnCompletion 트리거가 실행됩니다. API: NextItem · PreviousItem · SelectIndex Value=n · ListAdd · ListRemove · ListShuffle"))
                .font(.caption).foregroundColor(.secondary)
        }
        .padding(.vertical, 6)
    }

    private func addFiles() {
        let p = NSOpenPanel()
        p.allowsMultipleSelection = true
        p.canChooseDirectories = false
        p.allowedContentTypes = [.movie, .audio, .mpeg4Movie, .quickTimeMovie, .mp3, .wav, .data]
        guard p.runModal() == .OK else { return }
        input.addItems(p.urls.map { $0.path })
    }
}

/// Colour tab: 3D LUT (.cube).
struct LUTSection: View {
    @ObservedObject var input: InputSource
    @ViewState private var error: String? = nil

    var body: some View {
        Section(L("LUT (3D .cube)")) {
            HStack {
                Text(input.lutPath.isEmpty ? L("없음") : (input.lutPath as NSString).lastPathComponent)
                    .lineLimit(1)
                Spacer()
                Button(L("LUT 파일 선택…")) { choose() }
                if !input.lutPath.isEmpty {
                    Button(L("다시 읽기")) { LUTCache.shared.reload(input.lutPath) { error = $0 } }
                    Button(L("끄기")) { input.lutPath = ""; error = nil }
                }
            }
            if !input.lutPath.isEmpty {
                HStack {
                    Text(L("강도"))
                    Slider(value: $input.lutStrength, in: 0...1)
                    Text(String(format: "%.0f%%", input.lutStrength * 100)).frame(width: 44).monospacedDigit()
                }
            }
            if let e = error ?? (input.lutPath.isEmpty ? nil : LUTCache.shared.error(input.lutPath)) {
                Text(e).font(.caption).foregroundColor(.orange)
            } else {
                Text(L("카메라 Log 영상(S-Log3, V-Log, C-Log …)을 Rec.709로 바꾸거나 룩을 입힐 때 사용합니다. GPU에서 처리되어 부하가 거의 없습니다."))
                    .font(.caption).foregroundColor(.secondary)
            }
        }
    }

    private func choose() {
        let p = NSOpenPanel()
        p.allowsMultipleSelection = false
        if let t = UTType(filenameExtension: "cube") { p.allowedContentTypes = [t] }
        guard p.runModal() == .OK, let u = p.url else { return }
        error = nil
        input.lutPath = u.path
        LUTCache.shared.reload(u.path) { error = $0 }
    }
}

/// Audio tab: auto ducking.
struct DuckingSection: View {
    @EnvironmentObject var engine: SwitcherEngine
    @ObservedObject var input: InputSource

    var body: some View {
        Section(L("자동 더킹 (Ducking)")) {
            Toggle(L("이 입력이 말하면 다른 소리를 줄임 (진행자 마이크)"), isOn: $input.audioFX.duckTrigger)
            Toggle(L("다른 입력이 말할 때 이 입력을 줄임 (음악, 영상)"), isOn: $input.audioFX.ducked)
            Toggle(L("더킹 사용 (전체)"), isOn: $engine.ducking.enabled)
            HStack {
                Text(L("줄이는 양"))
                Slider(value: $engine.ducking.amountDB, in: -40...(-3))
                Text(String(format: "%.0f dB", engine.ducking.amountDB)).frame(width: 52).monospacedDigit()
            }
            HStack {
                Text(L("감지 레벨"))
                Slider(value: $engine.ducking.thresholdDB, in: -60...(-10))
                Text(String(format: "%.0f dB", engine.ducking.thresholdDB)).frame(width: 52).monospacedDigit()
            }
            HStack {
                Text(L("복귀 시간"))
                Slider(value: $engine.ducking.releaseMs, in: 100...3000)
                Text(String(format: "%.1f s", engine.ducking.releaseMs / 1000)).frame(width: 52).monospacedDigit()
            }
            Text(L("설정(양·레벨·시간)은 모든 입력에 공통입니다. 줄어드는 중에는 믹서 제목 옆에 DUCK 표시가 나옵니다."))
                .font(.caption).foregroundColor(.secondary)
        }
    }
}
