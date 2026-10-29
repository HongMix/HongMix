import SwiftUI

/// vMix "Video Controls" under the Preview and Output windows: Restart, Play/Pause, a Position bar you can
/// click or drag to seek, Mark In / Mark Out (right-click the bar — green / red markers) and the time
/// (position / duration, plus remaining time that turns red in the last 10 seconds).
/// Shown for non-live inputs (video/audio files); the row stays reserved so the monitors never jump.
struct TransportBar: View {
    let input: InputSource?

    var body: some View {
        Group {
            if let i = input, i.supportsTransport {
                TransportControls(input: i)
            } else {
                Color.clear
            }
        }
        .frame(height: SwitcherLayout.transport)
        .background(Theme.panelDark)
    }
}

private struct TransportControls: View {
    @ObservedObject var input: InputSource
    @ViewState private var scrub: Double? = nil        // seconds while dragging
    @ViewState private var showRemaining = false

    var body: some View {
        let dur = input.duration
        let pos = scrub ?? input.position
        let remaining = max(0, effectiveEnd - pos)
        let nearEnd = dur > 0 && !input.looping && input.playing && remaining <= 10
        HStack(spacing: 6) {
            iconButton("backward.end.fill", help: L("Restart — 처음(Mark In)부터")) { input.restart() }
            iconButton(input.playing ? "pause.fill" : "play.fill", help: input.playing ? L("일시정지") : L("재생")) {
                input.playing.toggle()
            }
            PositionBar(input: input, scrub: $scrub)
            Button { showRemaining.toggle() } label: {
                Text(showRemaining ? "-" + TransportControls.tc(remaining) : TransportControls.tc(pos))
                    .foregroundColor(nearEnd ? .red : .white)
                + Text(" / " + TransportControls.tc(dur)).foregroundColor(.secondary)
            }
            .buttonStyle(.plain)
            .font(.system(size: 11, weight: .semibold).monospacedDigit())
            .help(L("클릭: 경과 시간 ↔ 남은 시간"))
            .fixedSize()
        }
        .padding(.horizontal, 6)
    }

    private var effectiveEnd: Double {
        input.markOut > 0 && input.markOut < input.duration ? input.markOut : input.duration
    }

    private func iconButton(_ name: String, help: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: name)
                .font(.system(size: 11, weight: .bold))
                .foregroundColor(.white)
                .frame(width: 26, height: 20)
                .background(Theme.button)
                .clipShape(RoundedRectangle(cornerRadius: 3))
        }
        .buttonStyle(.plain)
        .help(help)
    }

    /// hh:mm:ss.ff style used in broadcast (hours only when needed)
    static func tc(_ s: Double) -> String {
        let t = max(0, s)
        let h = Int(t) / 3600, m = Int(t) / 60 % 60, sec = Int(t) % 60
        let cs = Int((t - t.rounded(.down)) * 100)
        return h > 0 ? String(format: "%d:%02d:%02d.%02d", h, m, sec, cs) : String(format: "%02d:%02d.%02d", m, sec, cs)
    }
}

/// Seek bar. Click/drag seeks live (like vMix); right-click sets Mark In / Mark Out at the clicked point.
private struct PositionBar: View {
    @ObservedObject var input: InputSource
    @Binding var scrub: Double?
    @ViewState private var lastSeek = Date.distantPast

    var body: some View {
        GeometryReader { g in
            let dur = max(0.001, input.duration)
            let pos = scrub ?? input.position
            let x = { (t: Double) -> CGFloat in CGFloat(min(1, max(0, t / dur))) * g.size.width }
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 2).fill(Color.black.opacity(0.6)).frame(height: 8)
                // active range between the marks
                if input.markIn > 0 || input.markOut > 0 {
                    let a = input.markIn > 0 ? input.markIn : 0
                    let b = input.markOut > 0 ? input.markOut : dur
                    Rectangle().fill(Color.white.opacity(0.12))
                        .frame(width: max(0, x(b) - x(a)), height: 8).offset(x: x(a))
                }
                RoundedRectangle(cornerRadius: 2).fill(Theme.accent).frame(width: x(pos), height: 8)
                if input.markIn > 0 {
                    Rectangle().fill(Color.green).frame(width: 6, height: 14).offset(x: x(input.markIn) - 3)
                        .help("Mark In " + TransportControls.tc(input.markIn))
                }
                if input.markOut > 0 {
                    Rectangle().fill(Color.red).frame(width: 6, height: 14).offset(x: x(input.markOut) - 3)
                        .help("Mark Out " + TransportControls.tc(input.markOut))
                }
                // playhead
                Rectangle().fill(Color.white).frame(width: 2, height: 16).offset(x: x(pos) - 1)
            }
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { v in
                        let t = Double(min(max(0, v.location.x), g.size.width) / max(1, g.size.width)) * dur
                        scrub = t
                        // seek while dragging, throttled (the decoder keeps up, the UI stays smooth)
                        if Date().timeIntervalSince(lastSeek) > 0.08 { input.seek(seconds: t); lastSeek = Date() }
                    }
                    .onEnded { v in
                        let t = Double(min(max(0, v.location.x), g.size.width) / max(1, g.size.width)) * dur
                        input.seek(seconds: t)
                        input.position = t
                        scrub = nil
                    }
            )
            .contextMenu {
                let t = input.position
                Button(Lf("Mark In (현재 위치 %@)", "\(TransportControls.tc(t))")) { input.markIn = t }
                Button(Lf("Mark Out (현재 위치 %@)", "\(TransportControls.tc(t))")) { input.markOut = t }
                Divider()
                Button(L("Mark In 지우기")) { input.markIn = -1 }.disabled(input.markIn <= 0)
                Button(L("Mark Out 지우기")) { input.markOut = -1 }.disabled(input.markOut <= 0)
                Button(L("Mark 모두 지우기")) { input.markIn = -1; input.markOut = -1 }
            }
        }
        .frame(height: 20)
        .help(L("클릭·드래그로 위치 이동. 우클릭 → Mark In / Mark Out (재생 바를 원하는 위치로 옮긴 뒤 설정)"))
    }
}
