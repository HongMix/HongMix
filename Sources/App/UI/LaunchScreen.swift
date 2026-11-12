import SwiftUI
import AppKit
import Metal

/// Launch screen shown over the main window while the engine comes up.
/// The steps report what is really happening (renderer, session, inputs, NDI, control API) and the
/// screen fades out by itself once everything is up — or after a few seconds at most, so a show can
/// always start. Status text is English on purpose (same on every system language).
final class LaunchModel: ObservableObject {
    static let shared = LaunchModel()

    enum StepState { case waiting, running, done, warning }

    struct Step: Identifiable {
        let id: Int
        let title: String
        var detail: String = ""
        var state: StepState = .waiting
    }

    @Published var steps: [Step] = [
        Step(id: 0, title: "VISUAL CORE · INITIALIZING METAL"),
        Step(id: 1, title: "SESSION MEMORY · RESTORING"),
        Step(id: 2, title: "INPUT MATRIX · ACQUIRING SIGNALS"),
        Step(id: 3, title: "MEDIA I/O · CHECKING NDI RUNTIME"),
        Step(id: 4, title: "CONTROL LINK · STARTING API"),
        Step(id: 5, title: "HONGMIX SYSTEM · READY"),
    ]
    @Published var progress: Double = 0
    @Published var visible = true
    @Published var fading = false
    private var started = false
    /// Runs once the launch screen is gone (Do Not Disturb, monitor outputs, pre-show check).
    var onFinished: (() -> Void)?

    private func set(_ i: Int, _ state: StepState, _ detail: String = "") {
        steps[i].state = state
        if !detail.isEmpty { steps[i].detail = detail }
        progress = Double(steps.filter { $0.state == .done || $0.state == .warning }.count) / Double(steps.count)
    }

    /// Called once the engine has started and the last session was restored.
    func run(engine: SwitcherEngine) {
        guard !started else { return }
        started = true
        let t0 = CACurrentMediaTime()
        let pace = 0.55                       // deliberate boot cadence; full sequence is at least 5 seconds

        func after(_ s: Double, _ f: @escaping () -> Void) { DispatchQueue.main.asyncAfter(deadline: .now() + s, execute: f) }

        set(0, .running)
        after(pace) {
            let gpu = MetalContext.shared.device.name
            self.set(0, .done, "\(gpu) · \(engine.format.name)")
            self.set(1, .running)
            after(pace) {
                let n = engine.inputs.count
                self.set(1, .done, n == 0 ? L("새 세션") : Lf("입력 %@개 복원", "\(n)"))
                self.set(2, .running)
                self.waitForInputs(engine: engine, since: CACurrentMediaTime()) {
                    self.set(3, .running)
                    after(pace) {
                        self.set(3, mc_ndi_available() != 0 ? .done : .warning,
                                 mc_ndi_available() != 0 ? L("NDI® 런타임 로드됨") : L("NDI® 런타임 없음 (선택 사항)"))
                        self.set(4, .running)
                        after(pace) {
                            let off = !APIAccess.enabled
                            let ok = off || engine.apiStatus.contains("8088")
                            let tcp = engine.apiStatus.contains("TCP 8099") && !engine.apiStatus.contains("8099 사용")
                                && !engine.apiStatus.contains("8099 unavailable")
                            self.set(4, ok ? .done : .warning,
                                     off ? L("원격 제어 꺼짐 (설정 › 네트워크)") : ok ? (tcp ? L("HTTP 8088 · TCP 8099 대기 중") : L("HTTP 8088 대기 중 · TCP 8099 사용 불가"))
                                        : L("HTTP 8088 사용 불가"))
                            self.set(5, .running)
                            let minTotal = 5.0
                            let wait = max(pace, minTotal - (CACurrentMediaTime() - t0))
                            after(wait) {
                                self.set(5, .done, String(format: L("%.2f fps · 렌더 %.1f ms"), engine.format.fps, max(engine.renderMs, 0.1)))
                                after(0.55) { self.dismiss() }
                            }
                        }
                    }
                }
            }
        }
    }

    /// Waits (max 5 s) until every live input delivers frames or reports an error.
    private func waitForInputs(engine: SwitcherEngine, since: CFTimeInterval, done: @escaping () -> Void) {
        let live = engine.inputs.filter { $0.isLiveSource }
        let online = live.filter { $0.video.frameCount > 0 }.count
        let failed = live.filter { $0.state == Int32(MC_STATE_ERROR) }.count
        let elapsed = CACurrentMediaTime() - since
        if live.isEmpty {
            set(2, .done, L("라이브 소스 없음"))
            done()
        } else if online + failed >= live.count || elapsed > 5 {
            let ok = online == live.count
            set(2, ok ? .done : .warning,
                Lf("라이브 소스 %@ / %@ 연결", "\(online)", "\(live.count)") + (ok ? "" : L(" · 계속 진행")))
            done()
        } else {
            steps[2].detail = "\(online) / \(live.count) live sources online…"
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                self.waitForInputs(engine: engine, since: since, done: done)
            }
        }
    }

    func dismiss() {
        guard visible, !fading else { return }
        withAnimation(.easeInOut(duration: 0.45)) { fading = true }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            self.visible = false
            let f = self.onFinished
            self.onFinished = nil
            f?()
        }
    }
}

struct LaunchScreen: View {
    @ObservedObject var model = LaunchModel.shared
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ViewState private var glow = false
    @ViewState private var markVisible = false
    @ViewState private var fadersLive = false
    @ViewState private var tallyLive = false
    @ViewState private var titleVisible = false
    @ViewState private var subtitleVisible = false

    var body: some View {
        ZStack {
            background
            VStack(spacing: 0) {
                Spacer()
                logo
                Spacer().frame(height: 34)
                progressBlock
                Spacer()
                footer
            }
            .padding(.vertical, 36)
        }
        .opacity(model.fading ? 0 : 1)
        .scaleEffect(model.fading ? 1.02 : 1)
        .contentShape(Rectangle())
        .onAppear {
            withAnimation(.easeInOut(duration: 1.6).repeatForever(autoreverses: true)) { glow = true }
            if reduceMotion {
                markVisible = true; fadersLive = true; tallyLive = true
                titleVisible = true; subtitleVisible = true
            } else {
                withAnimation(.spring(response: 0.65, dampingFraction: 0.78)) { markVisible = true }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.55) {
                    withAnimation(.easeInOut(duration: 0.85)) { fadersLive = true }
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.35) {
                    withAnimation(.easeOut(duration: 0.16)) { tallyLive = true }
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.55) {
                    withAnimation(.easeOut(duration: 0.55)) { titleVisible = true }
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.9) {
                    withAnimation(.easeOut(duration: 0.55)) { subtitleVisible = true }
                }
            }
        }
    }

    private var background: some View {
        ZStack {
            LinearGradient(colors: [Color(red: 0.05, green: 0.06, blue: 0.09), Color(red: 0.02, green: 0.02, blue: 0.04)],
                           startPoint: .top, endPoint: .bottom)
            RadialGradient(colors: [Theme.accent.opacity(0.28), .clear], center: .center, startRadius: 10, endRadius: 520)
                .offset(y: -60)
            // faint tally colours, as on a switcher panel
            HStack(spacing: 0) {
                Theme.preview.opacity(0.10).frame(maxWidth: .infinity)
                Color.clear.frame(maxWidth: .infinity)
                Theme.program.opacity(0.10).frame(maxWidth: .infinity)
            }
            .mask(LinearGradient(colors: [.clear, .black, .clear], startPoint: .top, endPoint: .bottom))
            .blur(radius: 60)
        }
        .ignoresSafeArea()
    }

    private var logo: some View {
        VStack(spacing: 14) {
            ZStack {
                Circle()
                    .fill(Theme.accent.opacity(glow ? 0.45 : 0.22))
                    .frame(width: 150, height: 150)
                    .blur(radius: 40)
                AnimatedHongMixMark(fadersLive: fadersLive, tallyLive: tallyLive, ready: model.steps[5].state == .done)
                    .frame(width: 128, height: 128)
                    .scaleEffect(markVisible ? 1 : 0.82)
                    .opacity(markVisible ? 1 : 0)
                    .shadow(color: Theme.accent.opacity(glow ? 0.45 : 0.18), radius: glow ? 22 : 12)
                    .shadow(color: .black.opacity(0.65), radius: 18, y: 8)
            }
            Text("HongMix")
                .font(.system(size: 46, weight: .heavy, design: .rounded))
                .foregroundStyle(LinearGradient(colors: [.white, Color(white: 0.78)], startPoint: .top, endPoint: .bottom))
                .tracking(0.5)
                .opacity(titleVisible ? 1 : 0)
                .offset(y: titleVisible ? 0 : 8)
            Text("LIVE PRODUCTION SWITCHER")
                .font(.system(size: 12, weight: .semibold))
                .tracking(4)
                .foregroundColor(Color(white: 0.62))
                .opacity(subtitleVisible ? 1 : 0)
                .offset(y: subtitleVisible ? 0 : 5)
            HStack(spacing: 8) {
                tag("v\(AppInfo.version)")
                tag("Apple Silicon")
                tag("Metal")
            }
            .padding(.top, 2)
            .opacity(subtitleVisible ? 1 : 0)
        }
    }

    private func tag(_ s: String) -> some View {
        Text(s)
            .font(.system(size: 10.5, weight: .semibold).monospacedDigit())
            .foregroundColor(Color(white: 0.80))
            .padding(.horizontal, 8).padding(.vertical, 3)
            .background(Capsule().fill(Color.white.opacity(0.07)))
            .overlay(Capsule().stroke(Color.white.opacity(0.12), lineWidth: 1))
    }

    private var progressBlock: some View {
        VStack(alignment: .leading, spacing: 14) {
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.08)).frame(height: 4)
                Capsule()
                    .fill(LinearGradient(colors: [Theme.accent, Color(red: 0.35, green: 0.75, blue: 1.0)],
                                         startPoint: .leading, endPoint: .trailing))
                    .frame(width: max(8, 420 * model.progress), height: 4)
                    .shadow(color: Theme.accent.opacity(0.8), radius: 6)
                    .animation(.easeOut(duration: 0.35), value: model.progress)
            }
            .frame(width: 420)
            VStack(alignment: .leading, spacing: 7) {
                ForEach(model.steps) { s in
                    HStack(spacing: 10) {
                        icon(s.state).frame(width: 14)
                        Text(s.title)
                            .font(.system(size: 12, weight: s.state == .running ? .semibold : .regular))
                            .foregroundColor(s.state == .waiting ? Color(white: 0.38) : Color(white: 0.90))
                            .lineLimit(1)
                            .layoutPriority(1)      // keep the step title; the detail truncates first
                        Spacer(minLength: 8)
                        Text(s.detail)
                            .font(.system(size: 11).monospacedDigit())
                            .foregroundColor(s.state == .warning ? .orange : Color(white: 0.55))
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .help(s.detail)
                    }
                    .animation(.easeOut(duration: 0.2), value: s.state == .done)
                }
            }
            .frame(width: 420)
        }
    }

    @ViewBuilder private func icon(_ st: LaunchModel.StepState) -> some View {
        switch st {
        case .waiting:
            Circle().stroke(Color(white: 0.30), lineWidth: 1).frame(width: 8, height: 8)
        case .running:
            ProgressView().controlSize(.mini).scaleEffect(0.8)
        case .done:
            Image(systemName: "checkmark").font(.system(size: 10, weight: .bold)).foregroundColor(Theme.program)
        case .warning:
            Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 10)).foregroundColor(.orange)
        }
    }

    private var footer: some View {
        VStack(spacing: 4) {
            Text(L("전 세계 방송 엔지니어를 위해 만들었습니다"))
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(Color(white: 0.50))
            Text("© 2026 Hong Seunghoon · github.com/HongMix/HongMix")
                .font(.system(size: 10))
                .foregroundColor(Color(white: 0.36))
        }
    }
}

/// Vector version of the app mark so the switcher controls can animate during startup.
private struct AnimatedHongMixMark: View {
    let fadersLive: Bool
    let tallyLive: Bool
    let ready: Bool

    var body: some View {
        GeometryReader { geo in
            let s = geo.size.width / 128
            ZStack {
                RoundedRectangle(cornerRadius: 30 * s, style: .continuous)
                    .fill(LinearGradient(colors: [Color(red: 0.15, green: 0.15, blue: 0.24),
                                                   Color(red: 0.075, green: 0.07, blue: 0.14)],
                                         startPoint: .top, endPoint: .bottom))
                    .overlay(alignment: .top) {
                        RoundedRectangle(cornerRadius: 30 * s, style: .continuous)
                            .fill(LinearGradient(colors: [.white.opacity(0.13), .clear], startPoint: .top, endPoint: .bottom))
                            .frame(height: 56 * s)
                    }
                    .overlay(RoundedRectangle(cornerRadius: 30 * s, style: .continuous)
                        .stroke(.white.opacity(0.13), lineWidth: s))

                // Level bridge: the gradient grows like a live audio meter.
                Capsule()
                    .fill(Color.white.opacity(0.10))
                    .frame(width: 57 * s, height: 12 * s)
                Capsule()
                    .fill(LinearGradient(colors: [Color.orange, Color.yellow.opacity(0.85), Theme.program],
                                         startPoint: .leading, endPoint: .trailing))
                    .frame(width: (fadersLive ? 57 : 8) * s, height: 10 * s)
                    .frame(width: 57 * s, alignment: .leading)
                    .shadow(color: Theme.program.opacity(fadersLive ? 0.45 : 0), radius: 5 * s)

                fader(x: -27 * s, offset: (fadersLive ? -19 : 14) * s, scale: s)
                fader(x:  27 * s, offset: (fadersLive ?  19 : -14) * s, scale: s)

                Circle()
                    .fill(tallyLive ? Theme.program : Color.red.opacity(0.28))
                    .frame(width: 15 * s, height: 15 * s)
                    .offset(x: 34 * s, y: -43 * s)
                    .shadow(color: Theme.program.opacity(tallyLive ? 0.9 : 0), radius: ready ? 11 * s : 5 * s)
                    .scaleEffect(ready ? 1.13 : 1)
                    .animation(.easeInOut(duration: 0.65).repeatCount(2, autoreverses: true), value: ready)
            }
        }
        .aspectRatio(1, contentMode: .fit)
    }

    private func fader(x: CGFloat, offset: CGFloat, scale: CGFloat) -> some View {
        ZStack {
            Capsule().fill(Color(white: 0.90)).frame(width: 9 * scale, height: 75 * scale)
            RoundedRectangle(cornerRadius: 2.5 * scale)
                .fill(Color(white: 0.96))
                .frame(width: 25 * scale, height: 9 * scale)
                .overlay(RoundedRectangle(cornerRadius: 2.5 * scale).stroke(.black.opacity(0.25), lineWidth: scale))
                .offset(y: offset)
        }
        .offset(x: x)
    }
}

/// Shows the launch screen only until it has dismissed itself.
struct LaunchOverlay: View {
    @ObservedObject var model = LaunchModel.shared
    var body: some View {
        if model.visible { LaunchScreen().transition(.opacity) }
    }
}
