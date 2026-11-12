import SwiftUI
import AppKit

/// "Monitor" button on an input tile: one resizable window per input, showing that input large
/// (placed as in Program) with its audio meter. View-only apart from play/pause and restart —
/// no Cut/Preview here so a stray click can't change what's on air.
enum InputMonitorWindow {
    private static var windows: [UUID: NSWindow] = [:]
    /// Inputs with an open monitor window (main thread).
    static var openIDs: Dictionary<UUID, NSWindow>.Keys { windows.keys }

    static func show(_ input: InputSource, engine: SwitcherEngine) {
        if let w = windows[input.id] { w.makeKeyAndOrderFront(nil); return }
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 494),
                         styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
        w.isReleasedWhenClosed = false
        w.appearance = NSAppearance(named: .darkAqua)
        w.title = Lf("입력 %@ · %@", "\(engine.number(of: input))", input.name)
        w.contentView = NSHostingView(rootView: InputMonitorView(input: input).environmentObject(engine))
        w.contentMinSize = NSSize(width: 320, height: 220)
        if let main = FullscreenOutput.switcherWindow {
            let f = main.frame
            let offset = CGFloat(windows.count % 6) * 24
            w.setFrameOrigin(NSPoint(x: f.midX - 400 + offset, y: f.midY - 247 - offset))
        } else { w.center() }
        let id = input.id
        windows[id] = w
        NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: w, queue: .main) { _ in
            windows[id] = nil
        }
        w.makeKeyAndOrderFront(nil)
    }

    /// The input was removed from the project.
    static func close(_ id: UUID) { windows[id]?.close() }
}

struct InputMonitorView: View {
    @EnvironmentObject var engine: SwitcherEngine
    @ObservedObject var input: InputSource

    private var tallyColor: Color? {
        switch engine.tally(of: input) {
        case 1: return Theme.live
        case 2: return .green
        default: return nil
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                MonitorView(fps: 30, placement: { [weak input] in input?.videoAdjust }) { [weak input] in
                    input?.currentFrame()
                }
                .aspectRatio(16.0 / 9.0, contentMode: .fit)
                .background(Color.black)
                .overlay(RoundedRectangle(cornerRadius: 2).stroke(tallyColor ?? .clear, lineWidth: 3))
                if input.hasAudio {
                    LayerMeter(meter: { [weak engine, id = input.id] in engine?.audioMixer.meter(for: id) ?? (0, 0) })
                        .frame(width: 12)
                }
            }
            .padding(8)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color.black)

            HStack(spacing: 8) {
                if input.supportsTransport {
                    Button { input.restart() } label: { Image(systemName: "backward.end.fill") }
                        .help(L("처음부터 (Restart)"))
                    Button { input.playing.toggle() } label: {
                        Image(systemName: input.playing ? "pause.fill" : "play.fill")
                    }
                    .help(input.playing ? L("일시정지") : L("재생"))
                }
                Spacer()
                Text(tallyText).font(.caption).foregroundColor(tallyColor ?? .secondary)
                Text(L("보기 전용 · 출력에는 영향 없음")).font(.caption).foregroundColor(.secondary)
            }
            .padding(.horizontal, 10).padding(.vertical, 6)
        }
    }

    private var tallyText: String {
        switch engine.tally(of: input) {
        case 1: return L("출력 중")
        case 2: return L("미리보기")
        default: return ""
        }
    }
}
