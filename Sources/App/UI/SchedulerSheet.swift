import SwiftUI

struct SchedulerButton: View {
    @EnvironmentObject var engine: SwitcherEngine
    @ViewState private var show = false

    var body: some View {
        Button { show = true } label: {
            HStack(spacing: 4) {
                Image(systemName: "alarm")
                Text("Schedule")
            }
            .font(.system(size: 12, weight: .semibold))
            .foregroundColor(.white)
            .padding(.horizontal, 12)
            .frame(height: 30)
            .background(Theme.button)
            .clipShape(RoundedRectangle(cornerRadius: 3))
        }
        .buttonStyle(.plain)
        .help(L("스케줄러 — 정해진 시각/요일에 송출 시작·녹화·컷·오버레이 등 아무 기능이나 자동 실행"))
        .sheet(isPresented: $show) { SchedulerSheet(scheduler: engine.scheduler).environmentObject(engine) }
    }
}

struct SchedulerSheet: View {
    @EnvironmentObject var engine: SwitcherEngine
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var scheduler: Scheduler
    @ViewState private var selected: UUID? = nil

    static let commonFunctions = [
        "StartStreaming", "StopStreaming", "StartRecording", "StopRecording", "StartMultiCorder", "StopMultiCorder",
        "StartExternal", "StopExternal", "Cut", "Fade", "CutDirect", "PreviewInput", "OverlayInput1In", "OverlayInput1Out",
        "OverlayInput2In", "OverlayInput2Out", "Play", "Pause", "Restart", "SetVolume", "AudioOn", "AudioOff",
        "SetText", "FadeToBlack", "LoudnessReset",
    ]
    static let dayNames = [L("일"), L("월"), L("화"), L("수"), L("목"), L("금"), L("토")]

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(L("스케줄러")).font(.headline)
                Spacer()
                if let (a, t) = scheduler.nextUp {
                    Text(Lf("다음: %@ · %@", "\(a.name.isEmpty ? a.function : a.name)", "\(SchedulerSheet.whenText(t))"))
                        .font(.system(size: 12)).foregroundColor(.secondary)
                }
            }
            .padding()

            HStack(spacing: 0) {
                VStack(spacing: 0) {
                    List(selection: $selected) {
                        ForEach($scheduler.actions) { $a in
                            HStack {
                                Toggle("", isOn: $a.enabled).labelsHidden().toggleStyle(.checkbox)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(a.name.isEmpty ? a.function : a.name).lineLimit(1)
                                    Text(SchedulerSheet.summary(a)).font(.caption).foregroundColor(.secondary).lineLimit(1)
                                }
                            }
                            .tag(a.id)
                        }
                        .onMove { scheduler.actions.move(fromOffsets: $0, toOffset: $1) }
                    }
                    HStack {
                        Button { add() } label: { Image(systemName: "plus") }
                        Button {
                            if let id = selected { scheduler.actions.removeAll { $0.id == id }; selected = nil }
                        } label: { Image(systemName: "minus") }
                        .disabled(selected == nil)
                        Spacer()
                    }
                    .padding(6)
                }
                .frame(width: 260)

                Divider()

                if let id = selected, let idx = scheduler.actions.firstIndex(where: { $0.id == id }) {
                    editor($scheduler.actions[idx])
                        .padding()
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                } else {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(L("왼쪽에서 항목을 고르거나 + 로 추가하세요.")).foregroundColor(.secondary)
                        Text(L("예) 매주 일요일 10:55 StartStreaming → 11:00 Fade(Input=오프닝) → 12:30 StopStreaming"))
                            .font(.caption).foregroundColor(.secondary)
                        Divider()
                        Text(L("실행 기록")).font(.subheadline)
                        ScrollView {
                            VStack(alignment: .leading, spacing: 2) {
                                ForEach(Array(scheduler.log.enumerated()), id: \.offset) { _, l in
                                    Text(l).font(.system(size: 11).monospacedDigit())
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    .padding()
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                }
            }

            HStack {
                Text(L("앱이 켜져 있는 동안 1초 단위로 실행됩니다. 꺼져 있던 동안 지난 일정은 실행하지 않습니다."))
                    .font(.caption).foregroundColor(.secondary)
                Spacer()
                Button(L("닫기")) { dismiss() }.keyboardShortcut(.defaultAction)
            }
            .padding()
        }
        .frame(width: 760, height: 520)
    }

    private func add() {
        var a = ScheduledAction()
        let c = Calendar.current.dateComponents([.hour, .minute], from: Date().addingTimeInterval(300))
        a.hour = c.hour ?? 9; a.minute = c.minute ?? 0
        scheduler.actions.append(a)
        selected = a.id
    }

    @ViewBuilder private func editor(_ a: Binding<ScheduledAction>) -> some View {
        Form {
            TextField(L("이름"), text: a.name, prompt: Text(L("예: 예배 송출 시작")))
            LabeledContent(L("시각 (시:분:초)")) {
                HStack(spacing: 3) {
                    timeField(Binding(get: { a.wrappedValue.hour }, set: { a.wrappedValue.hour = max(0, min(23, $0)) }))
                    Text(":")
                    timeField(Binding(get: { a.wrappedValue.minute }, set: { a.wrappedValue.minute = max(0, min(59, $0)) }))
                    Text(":")
                    timeField(Binding(get: { a.wrappedValue.second }, set: { a.wrappedValue.second = max(0, min(59, $0)) }))
                }
            }
            Toggle(L("특정 날짜에 한 번만"), isOn: Binding(get: { a.wrappedValue.date != nil },
                                                    set: { a.wrappedValue.date = $0 ? Date() : nil }))
            if a.wrappedValue.date != nil {
                DatePicker(L("날짜"), selection: Binding(get: { a.wrappedValue.date ?? Date() }, set: { a.wrappedValue.date = $0 }),
                           displayedComponents: .date)
            } else {
                HStack(spacing: 4) {
                    Text(L("요일"))
                    ForEach(1...7, id: \.self) { d in
                        let on = a.wrappedValue.weekdays.contains(d)
                        Button(SchedulerSheet.dayNames[d - 1]) {
                            if on { a.wrappedValue.weekdays.removeAll { $0 == d } } else { a.wrappedValue.weekdays.append(d); a.wrappedValue.weekdays.sort() }
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(on ? .accentColor : .gray.opacity(0.4))
                        .controlSize(.small)
                    }
                    Text(a.wrappedValue.weekdays.isEmpty ? L("(매일)") : "").font(.caption).foregroundColor(.secondary)
                }
            }
            HStack {
                TextField(L("기능 (Function)"), text: a.function)
                Menu(L("자주 쓰는 기능")) {
                    ForEach(SchedulerSheet.commonFunctions, id: \.self) { f in Button(f) { a.wrappedValue.function = f } }
                }
                .fixedSize()
            }
            Picker(L("입력 (Input)"), selection: a.input) {
                Text(L("없음")).tag("")
                ForEach(engine.inputs) { i in
                    Text("\(engine.number(of: i)). \(i.name)").tag(i.id.uuidString)
                }
                if !a.wrappedValue.input.isEmpty && !engine.inputs.contains(where: { $0.id.uuidString == a.wrappedValue.input }) {
                    Text(a.wrappedValue.input + L(" (없음)")).tag(a.wrappedValue.input)
                }
            }
            TextField(L("값 (Value)"), text: a.value)
            TextField(L("추가 파라미터"), text: a.extra, prompt: Text(L("예: Duration=1000&SelectedName=Headline.Text")))
            HStack {
                Button(L("지금 실행 (테스트)")) { scheduler.runNow(a.wrappedValue.id, engine) }
                Spacer()
                if let t = a.wrappedValue.nextFire(after: Date()) {
                    Text(L("다음 실행: ") + SchedulerSheet.whenText(t)).font(.caption).foregroundColor(.secondary)
                } else {
                    Text(a.wrappedValue.enabled ? L("예정 없음") : L("꺼짐")).font(.caption).foregroundColor(.orange)
                }
            }
        }
    }

    private func timeField(_ v: Binding<Int>) -> some View {
        TextField("", value: v, format: .number.grouping(.never))
            .textFieldStyle(.roundedBorder)
            .multilineTextAlignment(.center)
            .frame(width: 42)
    }

    static func summary(_ a: ScheduledAction) -> String {
        let days: String
        if let d = a.date {
            let f = DateFormatter(); f.dateFormat = "M/d"
            days = f.string(from: d)
        } else if a.weekdays.isEmpty || a.weekdays.count == 7 {
            days = L("매일")
        } else {
            days = a.weekdays.map { dayNames[$0 - 1] }.joined()
        }
        return "\(days) \(a.timeText) · \(a.function)"
    }

    static func whenText(_ t: Date) -> String {
        let s = Int(t.timeIntervalSinceNow)
        let f = DateFormatter(); f.dateFormat = Calendar.current.isDateInToday(t) ? "HH:mm:ss" : "M/d (E) HH:mm"
        f.locale = Locale(identifier: "ko_KR")
        let rel = s < 3600 ? String(format: L("%d분 %02d초 후"), s / 60, s % 60) : String(format: L("%d시간 %d분 후"), s / 3600, s / 60 % 60)
        return "\(f.string(from: t)) (\(rel))"
    }
}
