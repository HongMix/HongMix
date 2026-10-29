import SwiftUI

/// Rundown (cue sheet) window: the show's running order. NEXT runs the next step's actions
/// (cuts, overlays, titles, audio, recording …) and times each step against its planned length.
struct RundownView: View {
    @EnvironmentObject var engine: SwitcherEngine
    @ObservedObject var rundown: Rundown
    @ViewState private var selected: UUID? = nil

    var body: some View {
        HSplitView {
            VStack(spacing: 0) {
                header
                List(selection: $selected) {
                    ForEach(Array(rundown.items.enumerated()), id: \.element.id) { k, it in
                        row(k, it).tag(it.id)
                    }
                    .onMove { rundown.items.move(fromOffsets: $0, toOffset: $1) }
                }
                HStack {
                    Button { addItem(capture: false) } label: { Label(L("항목 추가"), systemImage: "plus") }
                    Button { addItem(capture: true) } label: { Label(L("지금 화면으로 추가"), systemImage: "camera.viewfinder") }
                        .help(L("현재 Output 입력과 켜진 오버레이를 그대로 재현하는 항목을 만듭니다"))
                    Spacer()
                    Button(role: .destructive) {
                        if let id = selected { rundown.items.removeAll { $0.id == id }; selected = nil }
                    } label: { Image(systemName: "trash") }
                    .disabled(selected == nil)
                }
                .padding(8)
            }
            .frame(minWidth: 460)

            editor
                .frame(minWidth: 360, maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(minWidth: 860, minHeight: 520)
    }

    // MARK: header — big NEXT + timers

    private var header: some View {
        TimelineView(.periodic(from: .now, by: 0.5)) { _ in
            let now = Date()
            let cur = rundown.items.indices.contains(rundown.current) ? rundown.items[rundown.current] : nil
            let elapsed = rundown.itemStarted.map { now.timeIntervalSince($0) } ?? 0
            let remain = Double(cur?.durationSec ?? 0) - elapsed
            let showElapsed = rundown.showStarted.map { now.timeIntervalSince($0) } ?? 0
            let planNow = Double(rundown.plannedStart(max(0, rundown.current))) + min(elapsed, Double(cur?.durationSec ?? 0))
            HStack(spacing: 14) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(cur.map { "\(rundown.current + 1). \($0.title)" } ?? L("대기 중 — NEXT로 시작"))
                        .font(.system(size: 15, weight: .bold)).lineLimit(1)
                    HStack(spacing: 12) {
                        if let c = cur, c.durationSec > 0 {
                            Text((remain >= 0 ? L("남음 ") : L("초과 +")) + RundownView.clock(abs(remain)))
                                .foregroundColor(remain < 0 ? .red : (remain < 10 ? .orange : .green))
                        } else if cur != nil {
                            Text(L("경과 ") + RundownView.clock(elapsed))
                        }
                        Text(L("쇼 ") + RundownView.clock(showElapsed) + " / " + RundownView.clock(Double(rundown.plannedTotal)))
                            .foregroundColor(.secondary)
                        if rundown.showStarted != nil {
                            let diff = showElapsed - planNow
                            Text(diff >= 0 ? L("늦음 +") + RundownView.clock(diff) : L("빠름 ") + RundownView.clock(-diff))
                                .foregroundColor(abs(diff) < 30 ? .secondary : (diff > 0 ? .orange : .blue))
                        }
                    }
                    .font(.system(size: 12, weight: .semibold).monospacedDigit())
                }
                Spacer()
                Button { rundown.previous(engine) } label: { Image(systemName: "backward.end.fill") }
                    .help(L("이전 항목 다시 실행"))
                Button { rundown.next(engine) } label: {
                    Text("NEXT").font(.system(size: 16, weight: .heavy)).frame(width: 90, height: 34)
                }
                .buttonStyle(.borderedProminent)
                .tint(Theme.program)
                .disabled(rundown.current + 1 >= rundown.items.count)
                .help(L("다음 항목 실행 (API: RundownNext)"))
                Menu {
                    Button(L("처음으로 되돌리기")) { rundown.reset() }
                } label: { Image(systemName: "ellipsis.circle") }
                .menuStyle(.borderlessButton).fixedSize()
            }
            .padding(10)
            .background(Theme.panelDark)
        }
    }

    private func row(_ k: Int, _ it: RundownItem) -> some View {
        let isCur = k == rundown.current
        return HStack(spacing: 8) {
            Text("\(k + 1)").font(.system(size: 12, weight: .bold).monospacedDigit()).frame(width: 24)
            VStack(alignment: .leading, spacing: 1) {
                Text(it.title.isEmpty ? L("(제목 없음)") : it.title).font(.system(size: 13, weight: isCur ? .bold : .regular))
                Text(it.actions.map { $0.function }.joined(separator: " · "))
                    .font(.caption).foregroundColor(.secondary).lineLimit(1)
            }
            Spacer()
            if it.autoNext { Image(systemName: "forward.fill").font(.caption).foregroundColor(.secondary) }
            Text(RundownView.clock(Double(rundown.plannedStart(k)))).font(.caption.monospacedDigit()).foregroundColor(.secondary)
            Text(it.durationSec > 0 ? RundownView.clock(Double(it.durationSec)) : "—")
                .font(.system(size: 12).monospacedDigit()).frame(width: 52, alignment: .trailing)
            Button { rundown.go(k, engine) } label: { Image(systemName: "play.fill") }
                .buttonStyle(.borderless).help(L("이 항목 바로 실행"))
        }
        .padding(.vertical, 3)
        .listRowBackground(isCur ? Theme.program.opacity(0.35) : (k == rundown.current + 1 ? Theme.preview.opacity(0.2) : Color.clear))
    }

    // MARK: editor

    @ViewBuilder private var editor: some View {
        if let id = selected, let i = rundown.items.firstIndex(where: { $0.id == id }) {
            Form {
                TextField(L("제목"), text: $rundown.items[i].title)
                LabeledContent(L("길이 (초, 0 = 정하지 않음)")) {
                    TextField("", value: $rundown.items[i].durationSec, format: .number.grouping(.never))
                        .frame(width: 80).textFieldStyle(.roundedBorder)
                }
                Toggle(L("시간이 되면 자동으로 다음 항목"), isOn: $rundown.items[i].autoNext)
                TextField(L("메모 (진행 큐, 멘트 등)"), text: $rundown.items[i].notes, axis: .vertical)
                    .lineLimit(2...5)
                Section(L("실행할 기능 (위에서부터 차례로)")) {
                    ForEach($rundown.items[i].actions) { $a in
                        HStack {
                            TextField(L("기능"), text: $a.function).frame(width: 150)
                            Picker("", selection: $a.input) {
                                Text(L("입력 없음")).tag("")
                                ForEach(engine.inputs) { inp in Text("\(engine.number(of: inp)). \(inp.name)").tag(inp.id.uuidString) }
                                if !a.input.isEmpty && !engine.inputs.contains(where: { $0.id.uuidString == a.input }) {
                                    Text(a.input).tag(a.input)
                                }
                            }
                            .labelsHidden().frame(width: 150)
                            TextField(L("값"), text: $a.value).frame(width: 80)
                            Button(role: .destructive) { rundown.items[i].actions.removeAll { $0.id == a.id } } label: {
                                Image(systemName: "minus.circle")
                            }.buttonStyle(.borderless)
                        }
                    }
                    HStack {
                        Menu(L("기능 추가")) {
                            ForEach(RundownView.common, id: \.self) { f in
                                Button(f) { rundown.items[i].actions.append(RundownAction(function: f)) }
                            }
                        }
                        .fixedSize()
                        Button(L("지금 화면을 기능으로")) { rundown.items[i].actions = Rundown.captureActions(engine) }
                    }
                    Text(L("예: Fade(Input=카메라1) → OverlayInput1In(Input=이름 자막) → SetText … 모든 vMix 함수 사용 가능"))
                        .font(.caption).foregroundColor(.secondary)
                }
            }
            .formStyle(.grouped)
            .textFieldStyle(.roundedBorder)
        } else {
            VStack(alignment: .leading, spacing: 8) {
                Text(L("런다운 (큐시트)")).font(.headline)
                Text(L("방송 순서를 한 줄씩 만들어 두고 NEXT로 진행합니다. 항목마다 컷·자막·오디오·녹화 같은 기능을 여러 개 넣을 수 있고, 계획한 길이와 실제 진행 시간을 비교해 보여줍니다."))
                    .foregroundColor(.secondary)
                Divider()
                Text(L("실행 기록")).font(.subheadline)
                ScrollView {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(Array(rundown.log.enumerated()), id: \.offset) { _, l in
                            Text(l).font(.system(size: 11).monospacedDigit())
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding()
        }
    }

    private func addItem(capture: Bool) {
        var it = RundownItem()
        it.title = capture ? (engine.input(withID: engine.programID)?.name ?? L("새 항목")) : Lf("새 항목 %@", "\(rundown.items.count + 1)")
        it.actions = capture ? Rundown.captureActions(engine) : [RundownAction(function: "Fade")]
        if let id = selected, let i = rundown.items.firstIndex(where: { $0.id == id }) {
            rundown.items.insert(it, at: i + 1)
        } else {
            rundown.items.append(it)
        }
        selected = it.id
    }

    static let common = ["Cut", "Fade", "CutDirect", "PreviewInput", "OverlayInput1In", "OverlayInput1Out",
                         "OverlayInput2In", "OverlayInput2Out", "OverlayInputAllOff", "SetText", "Play", "Pause",
                         "Restart", "AudioOn", "AudioOff", "SetVolume", "StartRecording", "StopRecording",
                         "StartStreaming", "StopStreaming", "StartCountdown", "FadeToBlack", "Stinger1"]

    static func clock(_ s: Double) -> String {
        let t = Int(s.rounded(.down))
        return t >= 3600 ? String(format: "%d:%02d:%02d", t / 3600, t / 60 % 60, t % 60) : String(format: "%02d:%02d", t / 60, t % 60)
    }
}

/// Bottom-bar button that opens the rundown window.
struct RundownButton: View {
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button { openWindow(id: "rundown") } label: {
            HStack(spacing: 4) {
                Image(systemName: "list.number")
                Text("Rundown")
            }
            .font(.system(size: 12, weight: .semibold))
            .foregroundColor(.white)
            .padding(.horizontal, 12)
            .frame(height: 30)
            .background(Theme.button)
            .clipShape(RoundedRectangle(cornerRadius: 3))
        }
        .buttonStyle(.plain)
        .help(L("런다운(큐시트) — 방송 순서를 NEXT 한 번으로 진행"))
    }
}
