import SwiftUI

/// vMix "Video Controls" under the Preview and Output windows: Restart, Play/Pause, a Position bar you can
/// click or drag to seek, Mark In / Mark Out (right-click the bar — green / red markers) and the time
/// (position / duration, plus remaining time that turns red in the last 10 seconds).
/// Shown for non-live inputs (video/audio files); the row stays reserved so the monitors never jump.
struct TransportBar: View {
    let input: InputSource?

    var body: some View {
        Group {
            if let d = input as? SlideDeckInput {
                // PDF / PowerPoint / Photos: ◀ Previous · n / N · Next ▶ (2.3.3)
                IsolatedHost(id: d.id) { SlideControls(deck: d) }
            } else if let m = input as? MultiLayoutInput {
                // MultiLayout: its scenes (a click takes one, animated)
                IsolatedHost(id: m.id) { MLSceneControls(ml: m) }
            } else if let i = input, i.supportsTransport {
                // Own hosting view: the playhead/timecode change ~20×/s, and in the main window's
                // SwiftUI graph every change re-ran layout for the whole switcher (main-thread stalls).
                IsolatedHost(id: i.id) { TransportControls(input: i) }
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
    @ObservedObject var transport: InputTransportState
    @ViewState private var scrub: Double? = nil        // seconds while dragging
    @ViewState private var showRemaining = false

    init(input: InputSource) {
        self.input = input
        self.transport = input.transport
    }

    var body: some View {
        let dur = transport.duration
        let pos = scrub ?? transport.position
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
        input.markOut > 0 && input.markOut < transport.duration ? input.markOut : transport.duration
    }

    private func iconButton(_ name: String, help: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: name)
                .font(.system(size: 11, weight: .bold))
                .foregroundColor(.white)
                .frame(width: 26, height: 20)
                .background(Theme.button)
                .clipShape(RoundedRectangle(cornerRadius: 3))
                .hmBevel(cornerRadius: 3)
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
    @ObservedObject var transport: InputTransportState
    @Binding var scrub: Double?
    @ViewState private var lastSeek = Date.distantPast

    init(input: InputSource, scrub: Binding<Double?>) {
        self.input = input
        self.transport = input.transport
        self._scrub = scrub
    }

    var body: some View {
        GeometryReader { g in
            let dur = max(0.001, transport.duration)
            let pos = scrub ?? transport.position
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
                        transport.position = t
                        scrub = nil
                    }
            )
            .contextMenu {
                let t = transport.position
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

/// Hosts a SwiftUI subtree in its own NSHostingView inside a fixed frame, so frequent updates in it
/// re-layout only that subtree instead of the surrounding window. `id` rebuilds it for a new input.
struct IsolatedHost<Content: View>: NSViewRepresentable {
    let id: AnyHashable
    let content: () -> Content

    init(id: AnyHashable, @ViewBuilder content: @escaping () -> Content) {
        self.id = id
        self.content = content
    }

    final class Coordinator { var id: AnyHashable? }
    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSHostingView<Content> {
        let v = NSHostingView(rootView: content())
        v.sizingOptions = []          // never push size changes up to the parent layout
        context.coordinator.id = id
        return v
    }

    func updateNSView(_ v: NSHostingView<Content>, context: Context) {
        // Only a different input replaces the content; the subtree updates itself from its own observers.
        guard context.coordinator.id != id else { return }
        context.coordinator.id = id
        v.rootView = content()
    }
}

/// Under the Preview / Output monitor for PDF / PowerPoint / Photos inputs: step through the slides
/// right there — check the next slide in Preview before the cut, or turn the slide on air (2.3.3).
struct SlideControls: View {
    @ObservedObject var deck: SlideDeckInput

    var body: some View {
        HStack(spacing: 6) {
            stepButton("backward.end.fill", text: nil, help: L("첫 슬라이드")) { deck.select(0) }
            stepButton("chevron.left", text: L("이전"), help: L("이전 슬라이드 (PreviousPicture)")) { deck.previous() }
            Text(deck.count > 0 ? "\(deck.currentIndex + 1) / \(deck.count)" : "– / –")
                .font(.system(size: 12, weight: .bold).monospacedDigit())
                .foregroundColor(.white)
                .frame(minWidth: 64)
            stepButton("chevron.right", text: L("다음"), help: L("다음 슬라이드 (NextPicture)"), trailing: true) { deck.next() }
            if deck.supportsTransport {          // Photos: automatic slideshow on / off
                stepButton(deck.playing ? "pause.fill" : "play.fill", text: nil,
                           help: deck.playing ? L("자동 넘김 멈춤") : L("자동 넘김")) { deck.playing.toggle() }
            }
            if deck is PhotosInput {            // file name; a PDF page has no name of its own
                Text(deck.currentName)
                    .font(.system(size: 10)).foregroundColor(.secondary)
                    .lineLimit(1).truncationMode(.middle)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 6)
    }

    private func stepButton(_ icon: String, text: String?, help: String, trailing: Bool = false,
                            _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 4) {
                if !trailing { Image(systemName: icon).font(.system(size: 10, weight: .bold)) }
                if let text { Text(text).font(.system(size: 11, weight: .semibold)) }
                if trailing { Image(systemName: icon).font(.system(size: 10, weight: .bold)) }
            }
            .foregroundColor(.white)
            .padding(.horizontal, text == nil ? 0 : 10)
            .frame(minWidth: 26, minHeight: 20)
            .background(Theme.button)
            .clipShape(RoundedRectangle(cornerRadius: 3))
            .hmBevel(cornerRadius: 3)
        }
        .buttonStyle(.plain)
        .help(help)
    }
}
