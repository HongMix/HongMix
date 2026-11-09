import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// Input Properties › Key: AI background removal (no green screen).
struct BGRemovalSection: View {
    @ObservedObject var input: InputSource

    var body: some View {
        Section {
            Toggle(L("사람만 남기기"), isOn: $input.bgRemoval.enabled)
            Picker(L("품질"), selection: $input.bgRemoval.quality) {
                Text(L("빠름")).tag(0)
                Text(L("균형")).tag(1)
                Text(L("정밀")).tag(2)
            }
            .pickerStyle(.segmented)
            LabeledContent(L("가장자리 부드럽게")) {
                Slider(value: $input.bgRemoval.softness, in: 0...1).frame(width: 220)
            }
            Picker(L("배경"), selection: $input.bgRemoval.background) {
                Text(L("투명 (뒤 레이어 보임)")).tag("transparent")
                Text(L("흐리게")).tag("blur")
                Text(L("이미지")).tag("image")
            }
            .pickerStyle(.segmented)
            if input.bgRemoval.background == "image" {
                HStack {
                    TextField("", text: $input.bgRemoval.imagePath, prompt: Text(L("배경 이미지 파일"))).labelsHidden()
                    Button("Browse…") {
                        let p = NSOpenPanel()
                        p.allowedContentTypes = [.png, .jpeg, .heic, .tiff, .image]
                        if p.runModal() == .OK, let u = p.url { input.bgRemoval.imagePath = u.path }
                    }
                }
            }
            if input.bgRemoval.enabled {
                TimelineView(.periodic(from: .now, by: 1)) { _ in
                    let r = input.bgRemover
                    let ms = r?.averageMs ?? 0
                    let frameMs = 1000 / max(1, VideoSlot.programFPS)
                    HStack {
                        if input.kind == .image {
                            Text(L("정지 이미지 — 한 번만 처리합니다")).foregroundColor(.secondary)
                        } else if r?.hasFailed == true {
                            Label(L("이 입력에서 사람을 찾지 못했거나 처리에 실패했습니다"), systemImage: "exclamationmark.triangle")
                                .foregroundColor(.orange)
                        } else if ms > 0 {
                            Text(Lf("처리 시간 %@ ms / 프레임 · Neural Engine", String(format: "%.1f", ms)))
                                .foregroundColor(ms > frameMs ? .orange : .secondary)
                            if ms > frameMs {
                                Text(L("— 프레임 시간보다 깁니다. ‘빠름’을 고르세요")).foregroundColor(.orange)
                            }
                        } else {
                            Text(L("준비 중…")).foregroundColor(.secondary)
                        }
                    }
                    .font(.caption)
                }
            }
            Text(L("맥 내장 사람 인식(Vision)으로 사람만 남깁니다. 머리카락·손가락 끝은 그린스크린보다 덜 깔끔합니다. ‘정밀’은 대부분의 맥에서 실시간이 아닙니다. 투명 배경은 오버레이(1~8)나 Virtual Set·레이어 위에 올려 쓰세요."))
                .font(.caption).foregroundColor(.secondary)
        } header: {
            Text(L("AI 배경 제거 (그린스크린 없이)"))
        }
    }
}
