import SwiftUI
import AppKit

/// Top bar: Do Not Disturb lamp + switch (orange = on, grey = off).
struct FocusChip: View {
    @ObservedObject var focus = FocusGuard.shared

    var body: some View {
        let on = focus.isOn
        Button { focus.toggle() } label: {
            HStack(spacing: 5) {
                Circle().fill(on ? Color.orange : Color.gray.opacity(0.6)).frame(width: 7, height: 7)
                Text(L("방해 금지"))
            }
            .font(.system(size: 11, weight: .semibold))
            .foregroundColor(on ? .white : .secondary)
            .padding(.horizontal, 8).frame(height: 20)
            .background(Capsule().fill(on ? Color.orange.opacity(0.18) : Color.white.opacity(0.06)))
            .overlay(Capsule().stroke(on ? Color.orange.opacity(0.85) : Color.white.opacity(0.12), lineWidth: 1))
            .opacity(focus.busy ? 0.55 : 1)
        }
        .buttonStyle(.plain)
        .help(!focus.installed ? L("방해 금지 단축어 승인이 필요합니다 — 누르면 승인 창이 열립니다")
              : on ? Lf("방해 금지 켜짐 (%@): 방송 중 제어를 다른 창에 뺏기지 않습니다. 누르면 끕니다.", focus.focusName ?? "")
              : L("방해 금지 꺼짐 — 누르면 켭니다"))
    }
}

/// Is HongMix the active app, and which app has the keyboard otherwise.
final class AppFocusWatch: ObservableObject {
    static let shared = AppFocusWatch()
    @Published private(set) var active = true
    @Published private(set) var frontApp = ""
    private var tokens: [NSObjectProtocol] = []

    private init() {
        let nc = NotificationCenter.default
        tokens.append(nc.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            self?.active = true
        })
        tokens.append(nc.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
            self?.active = false
        })
        tokens.append(NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] n in
            let app = n.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            self?.frontApp = app?.localizedName ?? ""
        })
        active = NSApp.isActive
    }
}

/// Orange line under the top bar while something is on air and another app has the keyboard:
/// HongMix keyboard shortcuts don't reach HongMix then (Companion / MIDI / API still work).
struct ControlFocusBanner: View {
    @EnvironmentObject var engine: SwitcherEngine
    @ObservedObject var watch = AppFocusWatch.shared
    var forceShow = false       // screenshots

    var body: some View {
        let live = engine.outputs.contains { $0.running } || FullscreenOutput.shared.isShowing || DisplayMap.shared.showingCount > 0
        if forceShow || (live && !watch.active) {
            Button { NSApp.activate(ignoringOtherApps: true) } label: {
                HStack(spacing: 8) {
                    Image(systemName: "keyboard.badge.exclamationmark")
                    Text(watch.frontApp.isEmpty
                         ? L("키보드 제어가 다른 앱에 있습니다 — HongMix 단축키가 동작하지 않습니다. 누르면 돌아옵니다.")
                         : Lf("키보드 제어가 다른 앱(%@)에 있습니다 — HongMix 단축키가 동작하지 않습니다. 누르면 돌아옵니다.", watch.frontApp))
                        .lineLimit(1).truncationMode(.tail)
                    Spacer(minLength: 0)
                }
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(.black)
                .padding(.horizontal, 12).frame(height: 24)
                .background(Color.orange)
            }
            .buttonStyle(.plain)
            .help(L("Companion · MIDI · 웹 API 제어는 계속 동작합니다"))
        }
    }
}

/// Orange line when macOS itself makes the HongMix window stall (see SystemHealth): names the cause and
/// offers to restart the macOS widget helpers. Output is not affected, and the line says so.
struct SystemHealthBanner: View {
    @ObservedObject var health = SystemHealth.shared
    var preview: SystemHealth.Alert? = nil      // screenshots

    var body: some View {
        let a = preview ?? health.alert
        if preview != nil || (a != nil && !health.dismissed) || health.cleaning || health.result != nil {
            HStack(spacing: 8) {
                Image(systemName: "gauge.with.dots.needle.67percent")
                Text(message(a)).lineLimit(1).truncationMode(.tail)
                Spacer(minLength: 0)
                if health.cleaning { ProgressView().controlSize(.small) }
                if let a, !a.restartable.isEmpty, !health.cleaning, health.result == nil {
                    Button(L("정리하기")) { health.cleanup() }
                        .help(L("맥 위젯 도우미만 재시작합니다. 맥이 바로 다시 띄우고 설정은 바뀌지 않습니다."))
                }
                Button(L("닫기")) { health.dismissed = true; health.clearResult() }
            }
            .font(.system(size: 12, weight: .semibold))
            .foregroundColor(.black)
            .padding(.horizontal, 12).frame(height: 24)
            .background(Color.orange)
        }
    }

    private func message(_ a: SystemHealth.Alert?) -> String {
        if preview == nil, let r = health.result { return r }
        if preview == nil, health.cleaning { return L("정리 중…") }
        guard let a else { return "" }
        let cause = a.culprits.prefix(2).map { "\(SystemHealth.friendly($0)) \(Int($0.cpu))%" }.joined(separator: ", ")
        return cause.isEmpty
            ? L("맥 화면이 느려졌어요 — HongMix 화면이 끊길 수 있어요 (출력에는 영향 없음)")
            : Lf("맥 화면이 느려졌어요 — 원인: %@ (출력에는 영향 없음)", cause)
    }
}
