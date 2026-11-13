import SwiftUI

/// Input Settings › Position › AI upscaling (Upscaler.swift): on/off and what it is doing right now.
struct UpscaleSection: View {
    @EnvironmentObject var engine: SwitcherEngine
    @ObservedObject var input: InputSource

    var body: some View {
        Section(L("AI 화질 올리기 (업스케일)")) {
            Toggle(L("저해상도 소스를 AI로 선명하게 키우기"), isOn: $input.upscale)
                .disabled(!Upscaler.isSupported && !input.upscale)
            Text(L("720p 카메라·SD 캡처처럼 출력보다 작은 소스를 Apple 실시간 초해상도 모델로 키운 뒤 배치합니다. 송출(Program·Preview·오버레이)에 올라간 동안에만 처리합니다. GPU·Neural Engine을 쓰므로 필요한 입력에만 켜세요. 카메라·영상용이며, 색 막대·그래픽처럼 아주 진한 색은 조금 옅어질 수 있습니다."))
                .font(.caption).foregroundColor(.secondary).fixedSize(horizontal: false, vertical: true)
            if !Upscaler.isSupported {
                Label(L("이 Mac에서는 쓸 수 없습니다 (macOS 26 이상, Apple Silicon 필요)"), systemImage: "exclamationmark.triangle")
                    .font(.caption).foregroundColor(.orange)
            } else if input.upscale {
                TimelineView(.periodic(from: .now, by: 1)) { _ in
                    status.font(.caption)
                }
            }
        }
    }

    @ViewBuilder private var status: some View {
        let u = input.upscaler
        let frameMs = 1000 / max(1, VideoSlot.programFPS)
        switch u?.state {
        case nil:
            Text(L("송출이나 Preview에 올리면 시작합니다")).foregroundColor(.secondary)
        case .notNeeded?:
            let s = u!.sourceSize
            Text(Lf("소스(%@)가 출력만큼 커서 키울 필요가 없습니다", "\(s.0)×\(s.1)")).foregroundColor(.secondary)
        case .unsupported?:
            Label(L("이 소스 크기는 모델이 지원하지 않습니다"), systemImage: "exclamationmark.triangle").foregroundColor(.orange)
        case .failed?:
            Label(L("처리에 실패해 원래 화면을 쓰는 중 · 잠시 후 다시 시도합니다"), systemImage: "exclamationmark.triangle").foregroundColor(.orange)
        case .starting?:
            Text(L("모델 불러오는 중… (처음 한 번 몇 초 걸립니다)")).foregroundColor(.secondary)
        case .running?:
            let s = u!.sourceSize, ms = u!.averageMs
            HStack {
                Text(Lf("%@ → ×%@ · 처리 시간 %@ ms / 프레임", "\(s.0)×\(s.1)", String(format: "%.1f", u!.factor),
                        ms > 0 ? String(format: "%.1f", ms) : "…"))
                    .foregroundColor(ms > frameMs ? .orange : .secondary)
                if ms > frameMs {
                    Text(L("— 프레임 시간보다 길어 일부 프레임이 반복됩니다")).foregroundColor(.orange)
                }
            }
        }
    }
}
