import SwiftUI
import AppKit

extension Color {
    /// "#RRGGBB" / "#RRGGBBAA" (HexColor.parse), white when unreadable.
    init(talentHex hex: String) {
        let c = HexColor.parse(hex) ?? (1, 1, 1, 1)
        self.init(.sRGB, red: Double(c.0), green: Double(c.1), blue: Double(c.2), opacity: Double(c.3))
    }

    var talentHex: String {
        guard let c = NSColor(self).usingColorSpace(.sRGB) else { return "#FFFFFF" }
        return String(format: "#%02X%02X%02X", Int(c.redComponent * 255), Int(c.greenComponent * 255), Int(c.blueComponent * 255))
    }
}

/// Background / logo images, read from disk once per path (the display redraws 4× a second).
enum TalentImages {
    private static var cache: [String: NSImage?] = [:]   // nil kept too: a missing file isn't read again 4× a second
    static func image(_ path: String) -> NSImage? {
        guard !path.isEmpty else { return nil }
        if let i = cache[path] { return i }
        let i = NSImage(contentsOfFile: path)
        cache[path] = .some(i)
        return i
    }
    /// After picking or clearing a file (the same path may now hold another picture).
    static func reset() { cache.removeAll() }
}

/// The Talent Display as video frames for MultiView cells: 4 per second at 960×540, only while a MultiView
/// has a Talent cell (SwitcherEngine.multiViews). Rendered on the main thread, read by the render thread.
final class TalentFrames {
    static let shared = TalentFrames()
    private let lock = NSLock()
    private var frame: CVPixelBuffer?
    private var timer: Timer?
    private let pool = PixelBufferFactory.makePool(width: 960, height: 540, minimumCount: 2)

    var latest: CVPixelBuffer? { lock.lock(); defer { lock.unlock() }; return frame }

    /// Main thread.
    func setActive(_ on: Bool) {
        if on, timer == nil {
            let t = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in MainActor.assumeIsolated { self?.render() } }
            RunLoop.main.add(t, forMode: .common)      // keeps running while a menu is open
            timer = t
            MainActor.assumeIsolated { render() }
        } else if !on, let t = timer {
            t.invalidate()
            timer = nil
            lock.lock(); frame = nil; lock.unlock()
        }
    }

    @MainActor private func render() {
        let r = ImageRenderer(content: TalentDisplayView(cue: TalentCue.shared).frame(width: 960, height: 540))
        r.scale = 1
        guard let cg = r.cgImage, let pool, let pb = PixelBufferFactory.makeBuffer(pool: pool) else { return }
        CVPixelBufferLockBaseAddress(pb, [])
        if let base = CVPixelBufferGetBaseAddress(pb) {
            let info = CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
            if let ctx = CGContext(data: base, width: 960, height: 540, bitsPerComponent: 8,
                                   bytesPerRow: CVPixelBufferGetBytesPerRow(pb),
                                   space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: info) {
                ctx.setFillColor(CGColor(gray: 0, alpha: 1))
                ctx.fill(CGRect(x: 0, y: 0, width: 960, height: 540))
                ctx.draw(cg, in: CGRect(x: 0, y: 0, width: 960, height: 540))
            }
        }
        CVPixelBufferUnlockBaseAddress(pb, [])
        lock.lock(); frame = pb; lock.unlock()
    }
}

/// What the presenter sees: the Talent Display output, and the preview in the Talent Cue window.
/// Sizes follow the view height, so the preview is an exact miniature.
struct TalentDisplayView: View {
    @ObservedObject var cue: TalentCue

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.25)) { ctx in
            GeometryReader { g in
                content(now: ctx.date, u: g.size.height / 100)
                    .frame(width: g.size.width, height: g.size.height)
            }
        }
        .clipped()
    }

    @ViewBuilder private func content(now: Date, u: CGFloat) -> some View {
        let s = cue.settings
        if cue.blackout {
            Color.black
        } else {
            ZStack {
                background(s)
                VStack(spacing: 2 * u) {
                    if !s.title.isEmpty && !(isIdle && s.idle == .black) {
                        Text(s.title).font(.system(size: 6 * u, weight: .semibold)).foregroundColor(.white.opacity(0.9))
                            .lineLimit(1).minimumScaleFactor(0.3).padding(.top, 3 * u)
                    }
                    Spacer(minLength: 0)
                    middle(now: now, u: u, s: s)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 4 * u)
            }
        }
    }

    private var isIdle: Bool { cue.liveMessage == nil && !cue.timerOnDisplay }

    @ViewBuilder private func background(_ s: TalentCue.Settings) -> some View {
        if isIdle && s.idle == .black {
            Color.black
        } else if let img = TalentImages.image(s.backgroundImage) {
            Image(nsImage: img).resizable().aspectRatio(contentMode: .fill)
        } else {
            Color(talentHex: s.background)
        }
    }

    @ViewBuilder private func middle(now: Date, u: CGFloat, s: TalentCue.Settings) -> some View {
        let blinkOn = Int(now.timeIntervalSince1970 * 2) % 2 == 0
        if let m = cue.liveMessage {
            // the time stays visible, small, above the message: the timer when it is on, else the clock
            if cue.timerOnDisplay { timer(now: now, size: 11 * u * s.timerScale, blink: blinkOn) }
            else { clock(now, size: 7 * u) }
            Text(m.text)
                .font(.system(size: 14 * u * s.messageScale, weight: .bold))
                .foregroundColor(Color(talentHex: m.color))
                .multilineTextAlignment(.center)
                .lineLimit(5).minimumScaleFactor(0.2)
                .padding(3 * u)
                .background(RoundedRectangle(cornerRadius: 2 * u)
                    .fill(cue.flash && blinkOn ? Color(talentHex: s.colorCritical).opacity(0.85) : .clear))
                .overlay(RoundedRectangle(cornerRadius: 2 * u)
                    .stroke(cue.flash ? Color(talentHex: s.colorCritical) : .clear, lineWidth: 0.8 * u))
        } else if cue.timerOnDisplay {
            timer(now: now, size: 40 * u * s.timerScale, blink: blinkOn)
            if s.clockUnderTimer { clock(now, size: 8 * u) }
        } else {
            switch s.idle {
            case .clock: clock(now, size: 25 * u)
            case .logo:
                if let img = TalentImages.image(s.logoPath) {
                    Image(nsImage: img).resizable().aspectRatio(contentMode: .fit).frame(maxHeight: 50 * u)
                }
            case .title, .black: EmptyView()
            }
        }
    }

    private func timer(now: Date, size: CGFloat, blink: Bool) -> some View {
        let t = cue.timer
        let s = cue.settings
        let phase = t.phase(at: now)
        let color: String = switch phase {
        case .normal: s.colorNormal
        case .warning: s.colorWarning
        case .critical, .overtime: s.colorCritical
        }
        return Text(TalentTimer.format(t.displaySeconds(at: now)))
            .font(.system(size: size, weight: .heavy, design: .rounded).monospacedDigit())
            .foregroundColor(Color(talentHex: color))
            .opacity(phase == .overtime && s.flashOvertime && !blink ? 0.25 : 1)
            .lineLimit(1).minimumScaleFactor(0.2)
    }

    private func clock(_ now: Date, size: CGFloat) -> some View {
        let f = DateFormatter()
        f.dateFormat = cue.settings.clock24h ? "HH:mm:ss" : "h:mm:ss a"
        return Text(f.string(from: now))
            .font(.system(size: size, weight: .semibold, design: .rounded).monospacedDigit())
            .foregroundColor(.white.opacity(0.85))
            .lineLimit(1).minimumScaleFactor(0.2)
    }
}
