import SwiftUI
import AppKit

/// Replay › clip ⬇: export one or more clips as files (horizontal / vertical 9:16 / square) in the background.
struct ReplayExportSheet: View {
    let events: [ReplayEvent]
    let fps: Double
    @ObservedObject var replay = ReplayEngine.shared
    @Environment(\.dismiss) private var dismiss
    @ViewState private var o = ReplayExportOptions.saved

    private var seconds: Double {
        events.reduce(0) { $0 + Double($1.outFrame - $1.inFrame) / max(1, fps) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(events.count == 1
                 ? Lf("클립 %@ 내보내기 (%@초)", String(format: "%04d", events[0].number), String(format: "%.1f", seconds))
                 : Lf("클립 %@개 내보내기 (%@초)", "\(events.count)", String(format: "%.1f", seconds)))
                .font(.headline)
            Form {
                Picker(L("화면 비율"), selection: $o.aspect) {
                    Text(L("가로 16:9")).tag(0)
                    Text(L("세로 9:16")).tag(1)
                    Text(L("정사각 1:1")).tag(2)
                }
                .pickerStyle(.segmented)
                if o.aspect != 0 {
                    LabeledContent(L("자를 위치")) {
                        HStack(spacing: 10) {
                            Slider(value: $o.cropX, in: 0...1).frame(width: 180)
                            CropDiagram(aspect: o.aspect, cropX: o.cropX).frame(width: 96, height: 54)
                        }
                    }
                }
                Picker(L("앵글"), selection: $o.allAngles) {
                    Text(L("클립 앵글")).tag(false)
                    Text(L("앵글마다 따로")).tag(true)
                }
                .pickerStyle(.segmented)
                Picker(L("속도"), selection: $o.speed) {
                    Text(L("원래 속도")).tag(0)
                    Text(L("50% 슬로")).tag(1)
                    Text(L("AI 슬로 (25%)")).tag(2)
                }
                .pickerStyle(.segmented)
                if o.speed == 2, events.contains(where: { replay.aiClips[$0.id]?.ready != true }) {
                    Text(L("AI 프레임이 아직 준비되지 않은 클립은 프레임을 반복해 25%로 만듭니다."))
                        .font(.caption).foregroundColor(.orange)
                }
                if o.speed != 0 {
                    Text(L("슬로 모션 파일에는 소리를 넣지 않습니다 (재생과 같음).")).font(.caption).foregroundColor(.secondary)
                }
                Picker(L("앞뒤 여유"), selection: $o.pad) {
                    Text(L("0초")).tag(0)
                    Text(L("1초")).tag(1)
                    Text(L("2초")).tag(2)
                }
                .pickerStyle(.segmented)
                Picker(L("화질"), selection: $o.codec) {
                    Text("H.264 (SNS)").tag("h264")
                    Text("HEVC").tag("hevc")
                    Text(L("ProRes (편집)")).tag("prores")
                }
                .pickerStyle(.segmented)
                LabeledContent(L("저장 폴더")) {
                    HStack {
                        Text((o.folder as NSString).abbreviatingWithTildeInPath)
                            .font(.system(size: 11).monospaced()).lineLimit(1).truncationMode(.middle)
                        Button(L("선택…")) {
                            let p = NSOpenPanel()
                            p.canChooseDirectories = true; p.canChooseFiles = false; p.canCreateDirectories = true
                            if p.runModal() == .OK, let u = p.url { o.folder = u.path }
                        }
                        Button { NSWorkspace.shared.open(URL(fileURLWithPath: o.folder)) } label: { Image(systemName: "folder") }
                            .buttonStyle(.borderless).help(L("Finder에서 열기"))
                    }
                }
            }
            .formStyle(.grouped)
            Text(L("내보내기는 뒤에서 진행되어 방송·리플레이 재생을 멈추지 않습니다. 진행률은 클립 줄에 표시됩니다."))
                .font(.caption).foregroundColor(.secondary)
            HStack {
                Spacer()
                Button(L("취소")) { dismiss() }.keyboardShortcut(.cancelAction)
                Button(L("내보내기")) {
                    ReplayExportOptions.saved = o
                    replay.export(events, options: o)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(16)
        .frame(width: 560)
    }
}

/// Small picture of which part of the 16:9 frame a vertical / square export keeps.
private struct CropDiagram: View {
    let aspect: Int
    let cropX: Double

    var body: some View {
        GeometryReader { g in
            let W = g.size.width, H = g.size.height
            let cw = aspect == 1 ? H * 9 / 16 : H
            let x = (W - cw) * cropX
            ZStack(alignment: .topLeading) {
                Rectangle().fill(Color.black.opacity(0.6))
                Rectangle().stroke(Color.secondary, lineWidth: 1)
                Rectangle().fill(Color.accentColor.opacity(0.35))
                    .overlay(Rectangle().stroke(Color.accentColor, lineWidth: 1.5))
                    .frame(width: cw, height: H)
                    .offset(x: x)
            }
        }
    }
}
