import SwiftUI

/// Bottom-bar "Overlay" button: opens the overlay channel / stinger settings.
struct OverlaySettingsButton: View {
    @EnvironmentObject var engine: SwitcherEngine
    @ViewState private var show = false

    var body: some View {
        Button {
            show = true
        } label: {
            Text("Overlay")
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(.white)
                .padding(.horizontal, 14)
                .frame(height: 30)
                .background(engine.overlayOn.contains(true) ? Theme.overlay : Theme.button)
                .clipShape(RoundedRectangle(cornerRadius: 3))
        }
        .buttonStyle(.plain)
        .help(L("오버레이 채널 1~4 / Stinger 설정"))
        .sheet(isPresented: $show) {
            OverlaySettingsSheet().environmentObject(engine)
        }
    }
}

struct OverlaySettingsSheet: View {
    @EnvironmentObject var engine: SwitcherEngine
    @Environment(\.dismiss) private var dismiss
    @ViewState private var number = 1

    var body: some View {
        VStack(spacing: 0) {
            Text("Overlay Settings").font(.headline).padding()
            Picker("Number", selection: $number) {
                ForEach(1...4, id: \.self) { Text("Overlay \($0)").tag($0) }
                ForEach(1...4, id: \.self) { Text("Stinger \($0)").tag(10 + $0) }
            }
            .pickerStyle(.menu)
            .frame(width: 260)

            Form {
                if number <= 4 {
                    overlaySection(number - 1)
                } else {
                    stingerSection(number - 11)
                }
            }
            .formStyle(.grouped)
            .textFieldStyle(.roundedBorder)

            HStack {
                Spacer()
                Button(L("닫기")) { dismiss() }.keyboardShortcut(.defaultAction)
            }
            .padding()
        }
        .frame(width: 520, height: 520)
    }

    @ViewBuilder private func overlaySection(_ i: Int) -> some View {
        Section("Overlay \(i + 1)") {
            Picker("Type", selection: $engine.overlaySettings[i].pip) {
                Text("Fullscreen").tag(false)
                Text("Picture In Picture").tag(true)
            }
            Picker("Transition Effect", selection: $engine.overlaySettings[i].effect) {
                ForEach(OverlayEffect.allCases) { Text($0.label).tag($0) }
            }
            Stepper("Effect Duration: \(engine.overlaySettings[i].durationMs) ms",
                    value: $engine.overlaySettings[i].durationMs, in: 0...5000, step: 100)
            Stepper(engine.overlaySettings[i].autoCloseSeconds == 0
                    ? L("Duration: 0 (자동으로 닫지 않음)")
                    : Lf("Duration: %@초 후 자동으로 닫힘", "\(Int(engine.overlaySettings[i].autoCloseSeconds))"),
                    value: $engine.overlaySettings[i].autoCloseSeconds, in: 0...600, step: 1)
        }
        if engine.overlaySettings[i].pip {
            Section(L("Picture In Picture 위치")) {
                HStack {
                    Text("Zoom")
                    Slider(value: $engine.overlaySettings[i].pipZoom, in: 0.1...1)
                    Text(String(format: "%.2f", engine.overlaySettings[i].pipZoom)).frame(width: 40)
                }
                HStack {
                    Text("Pan X")
                    Slider(value: $engine.overlaySettings[i].pipX, in: -2...2)
                    Text(String(format: "%.2f", engine.overlaySettings[i].pipX)).frame(width: 40)
                }
                HStack {
                    Text("Pan Y")
                    Slider(value: $engine.overlaySettings[i].pipY, in: -2...2)
                    Text(String(format: "%.2f", engine.overlaySettings[i].pipY)).frame(width: 40)
                }
                HStack {
                    Button(L("왼쪽 위")) { setPiP(i, -0.9, 0.9) }
                    Button(L("오른쪽 위")) { setPiP(i, 0.9, 0.9) }
                    Button(L("왼쪽 아래")) { setPiP(i, -0.9, -0.9) }
                    Button(L("오른쪽 아래")) { setPiP(i, 0.9, -0.9) }
                }
            }
        }
    }

    private func setPiP(_ i: Int, _ x: Float, _ y: Float) {
        engine.overlaySettings[i].pipX = x
        engine.overlaySettings[i].pipY = y
    }

    @ViewBuilder private func stingerSection(_ i: Int) -> some View {
        Section("Stinger \(i + 1)") {
            Picker("Stinger Input", selection: $engine.stingers[i].inputID) {
                Text(L("없음")).tag(UUID?.none)
                ForEach(engine.inputs.filter { $0.kind == .media }) { input in
                    Text("\(engine.number(of: input)). \(input.name)").tag(UUID?.some(input.id))
                }
            }
            Stepper("Cut Point: \(engine.stingers[i].cutPointMs) ms", value: $engine.stingers[i].cutPointMs,
                    in: 0...10000, step: 50)
            Text(L("투명 배경 애니메이션(ProRes 4444 MOV 등)을 미디어 입력으로 추가한 뒤 지정하세요. 컷 지점에서 Preview가 Output으로 바뀝니다. Stinger 1·2 버튼은 전환 영역에, 3·4는 API(Stinger3/Stinger4)로 실행합니다."))
                .font(.caption).foregroundColor(.secondary)
        }
    }
}
