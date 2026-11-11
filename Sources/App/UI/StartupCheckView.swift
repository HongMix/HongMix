import SwiftUI
import AppKit
import AVFoundation

/// "Pre-show check" window — opens once after launch (can be turned off), and from HongMix › 시작 전 점검….
enum StartupCheckWindow {
    private static var window: NSWindow?

    static func show(engine: SwitcherEngine) {
        if let w = window {
            SystemCheck.shared.run(recordFolder: recordFolder(engine))
            w.makeKeyAndOrderFront(nil)
            return
        }
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 820, height: 700),
                         styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        w.title = L("시작 전 점검")
        w.isReleasedWhenClosed = false
        w.appearance = NSAppearance(named: .darkAqua)
        w.contentView = NSHostingView(rootView: StartupCheckView(onClose: { close() }).environmentObject(engine))
        w.setContentSize(NSSize(width: 820, height: 700))
        w.minSize = NSSize(width: 760, height: 560)
        if let main = FullscreenOutput.switcherWindow {
            let f = main.frame
            w.setFrameOrigin(NSPoint(x: f.midX - 410, y: f.midY - 380))
        } else { w.center() }
        window = w
        NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: w, queue: .main) { _ in
            window = nil
        }
        SystemCheck.shared.run(recordFolder: recordFolder(engine))
        w.makeKeyAndOrderFront(nil)
    }

    static func close() { window?.close() }

    static var isShowing: Bool { window != nil }

    static func recordFolder(_ engine: SwitcherEngine) -> String {
        engine.outputs.first { $0.config.kind == .record }?.config.recordFolder ?? "~/Movies/HongMix"
    }
}

struct StartupCheckView: View {
    @EnvironmentObject var engine: SwitcherEngine
    @ObservedObject var check = SystemCheck.shared
    @ObservedObject var focus = FocusGuard.shared
    @ViewState private var showAtLaunch = SystemCheck.showAtLaunch
    let onClose: () -> Void

    var body: some View {
        let warnings = check.warnings(engine: engine)
        VStack(spacing: 0) {
            header
            if !warnings.isEmpty { warningBar(warnings) }
            ScrollView {
                VStack(spacing: 10) {
                    macPanel
                    networkPanel
                    HStack(alignment: .top, spacing: 10) {
                        remotePanel
                        devicesPanel
                    }
                }
                .padding(12)
            }
            Divider()
            footer
        }
        .background(Color(white: 0.11))
        .frame(minWidth: 760, minHeight: 560)
    }

    // MARK: header / warnings / footer

    private var header: some View {
        let m = check.mac
        return HStack(spacing: 8) {
            Image(systemName: "checklist").foregroundColor(.secondary)
            Text(L("시작 전 점검")).font(.system(size: 13, weight: .semibold))
            Text("· \(m.model)\(m.chip.isEmpty ? "" : " (\(m.chip) · \(m.memoryGB)GB)") · \(m.macOS) · HongMix \(AppInfo.version)")
                .font(.system(size: 11)).foregroundColor(.secondary).lineLimit(1).truncationMode(.middle)
            Spacer()
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
    }

    private func warningBar(_ w: [SystemCheck.Warning]) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundColor(.orange)
            (Text(Lf("확인 필요 %@건", "\(w.count)")).fontWeight(.semibold).foregroundColor(.orange)
             + Text(" · " + w.map { $0.text }.joined(separator: " · ")))
                .font(.system(size: 12))
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background(Color.orange.opacity(0.14))
        .overlay(Rectangle().fill(Color.orange.opacity(0.7)).frame(height: 1), alignment: .bottom)
    }

    private var footer: some View {
        HStack(spacing: 14) {
            Toggle(L("실행할 때마다 보기"), isOn: Binding(get: { showAtLaunch },
                                                    set: { showAtLaunch = $0; SystemCheck.showAtLaunch = $0 }))
            Toggle(L("인터넷 속도 측정"), isOn: Binding(get: { check.internetCheck }, set: { check.internetCheck = $0 }))
                .help(L("속도 측정과 외부 IP 확인은 Cloudflare 속도 측정 서버에 접속합니다. 끄면 맥과 내부 네트워크 정보만 봅니다."))
            Spacer()
            Button(L("다시 검사")) { check.run(recordFolder: StartupCheckWindow.recordFolder(engine)) }
            Button(L("닫기")) { onClose() }.keyboardShortcut(.cancelAction)
        }
        .toggleStyle(.checkbox)
        .font(.system(size: 12))
        .padding(.horizontal, 12).padding(.vertical, 8)
    }

    // MARK: Mac

    private var macPanel: some View {
        let u = check.usage, m = check.mac
        let memFree = max(0, u.memTotal - u.memUsed)
        return Panel(title: L("이 맥")) {
            HStack(alignment: .top, spacing: 0) {
                Donut(value: u.cpu, label: L("CPU 사용"), detail: Lf("%@코어 (P %@ · E %@)", "\(m.perfCores + m.effCores)", "\(m.perfCores)", "\(m.effCores)"),
                      color: Self.loadColor(u.cpu))
                Donut(value: u.gpu, label: L("GPU 사용"), detail: m.gpuCores.map { Lf("%@코어", "\($0)") } ?? "—",
                      color: Self.loadColor(u.gpu ?? 0))
                Donut(value: u.memTotal > 1 ? memFree / u.memTotal : nil, label: L("메모리 여유"),
                      detail: String(format: "%.1f / %.0f GB", memFree / 1_073_741_824, u.memTotal / 1_073_741_824),
                      color: Self.freeColor(u.memTotal > 1 ? memFree / u.memTotal : 1))
                Donut(value: u.diskTotal > 1 ? u.diskFree / u.diskTotal : nil, label: L("디스크 여유"),
                      detail: "\(SystemCheck.bytes(u.diskFree))\(u.diskName.isEmpty ? "" : " · \(u.diskName)")",
                      color: Self.freeColor(u.diskTotal > 1 ? u.diskFree / u.diskTotal : 1))
                Donut(value: u.battery.map { Double($0) / 100 }, label: L("배터리"),
                      detail: batteryDetail(u), color: u.battery == nil ? .gray : (u.onAC ? .green : .orange))
                VStack(alignment: .leading, spacing: 0) {
                    Row(L("전원"), u.battery == nil ? L("전원 어댑터") : (u.onAC ? (u.charging ? L("연결됨 · 충전 중") : L("연결됨")) : L("연결 안 됨 · 확인 요망")),
                        tint: u.battery != nil && !u.onAC ? .orange : .green, tag: u.battery != nil && !u.onAC)
                    Row(L("방해 금지"), !focus.installed ? L("승인 필요") : (focus.isOn ? L("켜짐") : L("꺼짐")),
                        tint: focus.isOn ? .orange : .secondary, tag: focus.isOn)
                    Row("Neural Engine", m.neuralCores.map { Lf("%@코어", "\($0)") } ?? "—", tint: .primary)
                    Row(L("발열"), thermalText(u.thermal), tint: u.thermal == .nominal || u.thermal == .fair ? .green : .orange)
                }
                .frame(width: 210)
            }
        }
    }

    private func batteryDetail(_ u: SystemCheck.Usage) -> String {
        guard u.battery != nil else { return L("배터리 없음") }
        if u.onAC { return u.charging ? L("충전 중") : L("전원 연결") }
        if let m = u.minutesLeft { return Lf("약 %@시간 %@분", "\(m / 60)", "\(m % 60)") }
        return L("배터리 사용 중")
    }

    private func thermalText(_ t: ProcessInfo.ThermalState) -> String {
        switch t {
        case .nominal: return L("정상")
        case .fair: return L("약간 따뜻함")
        case .serious: return L("뜨거움")
        case .critical: return L("매우 뜨거움")
        @unknown default: return "—"
        }
    }

    static func loadColor(_ v: Double) -> Color { v > 0.85 ? .red : v > 0.65 ? .orange : .green }
    static func freeColor(_ v: Double) -> Color { v < 0.1 ? .red : v < 0.2 ? .orange : .green }

    // MARK: Network

    private var networkPanel: some View {
        Panel(title: L("네트워크 (모든 연결)")) {
            VStack(spacing: 0) {
                HStack(spacing: 8) {
                    Text(L("네트워크 연결")).frame(width: 190, alignment: .leading)
                    Text(L("할당된 IP")).frame(width: 120, alignment: .leading)
                    Text(L("링크 속도")).frame(width: 80, alignment: .leading)
                    Text(L("인터넷 (받기 / 보내기 / 지연)")).frame(maxWidth: .infinity, alignment: .leading)
                }
                .font(.system(size: 11)).foregroundColor(.secondary).padding(.bottom, 4)
                if check.ifaces.isEmpty {
                    Text(L("네트워크 연결 없음")).font(.system(size: 12)).foregroundColor(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 4)
                }
                ForEach(check.ifaces) { i in
                    Divider().opacity(0.4)
                    HStack(spacing: 8) {
                        HStack(spacing: 5) {
                            Image(systemName: i.kind == .wifi ? (i.ip == nil ? "wifi.slash" : "wifi") : "cable.connector")
                                .foregroundColor(i.ip != nil ? .green : (i.cableOut ? .orange : .secondary))
                                .frame(width: 16)
                            Text(i.name).lineLimit(1).truncationMode(.middle)
                        }
                        .frame(width: 190, alignment: .leading)
                        Text(i.ip ?? "—").font(.system(size: 11, design: .monospaced))
                            .foregroundColor(i.ip == nil ? .secondary : .primary)
                            .frame(width: 120, alignment: .leading)
                        Text(i.linkMbps.map { $0 >= 1000 ? "\($0 / 1000) Gbps" : "\($0) Mbps" } ?? "—")
                            .foregroundColor(i.linkMbps == nil ? .secondary : .primary)
                            .frame(width: 80, alignment: .leading)
                        internetCell(i).frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .font(.system(size: 12))
                    .padding(.vertical, 5)
                }
                Divider().opacity(0.4)
                HStack(spacing: 8) {
                    Text(L("외부 IP")).foregroundColor(.secondary).frame(width: 190, alignment: .leading)
                    Text(check.publicIP ?? "—").font(.system(size: 11, design: .monospaced)).frame(width: 120, alignment: .leading)
                    Text("").frame(width: 80)
                    Text(streamLine).foregroundColor(.secondary).frame(maxWidth: .infinity, alignment: .leading)
                }
                .font(.system(size: 12)).padding(.vertical, 5)
                speedBar
                if check.ifaces.contains(where: { $0.expensive }) {
                    Text(L("핫스팟(데이터 요금이 드는 연결)은 데이터를 아끼려고 속도 측정을 건너뜁니다."))
                        .font(.system(size: 10)).foregroundColor(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading).padding(.top, 4)
                }
            }
        }
    }

    @ViewBuilder private func internetCell(_ i: SystemCheck.Iface) -> some View {
        if i.ip == nil {
            Text(i.kind == .ethernet ? (i.cableOut ? L("케이블 연결 안 됨") : L("IP 없음")) : L("연결 안 됨"))
                .foregroundColor(i.cableOut ? .orange : .secondary)
        } else if i.selfAssigned {
            Text(L("인터넷 연결 안 됨 · 자동 할당 IP")).foregroundColor(.secondary)
        } else if !check.internetCheck {
            Text(L("측정 안 함")).foregroundColor(.secondary)
        } else if i.testing && i.internet == nil && i.down == nil {
            Text(L("확인 중…")).foregroundColor(.secondary)
        } else if i.internet == false {
            Text(L("인터넷 연결 안 됨")).foregroundColor(.secondary)
        } else if i.internet == true && i.expensive {
            Text(Lf("핫스팟 · 속도 측정 건너뜀 · %@", latencyText(i))).foregroundColor(.secondary)
        } else if i.down != nil || i.up != nil || i.internet == true {
            Text("\(i.down.map(SystemCheck.mbps) ?? "…") / \(i.up.map(SystemCheck.mbps) ?? "…") · \(latencyText(i))")
                .foregroundColor(i.testing ? .orange : .green)
        } else {
            Text("—").foregroundColor(.secondary)
        }
    }

    private func latencyText(_ i: SystemCheck.Iface) -> String {
        i.latencyMs.map { String(format: "%.0f ms", $0) } ?? "— ms"
    }

    private var streamLine: String {
        let kbps = SystemCheck.streamKbps(engine)
        guard kbps > 0 else { return L("송출 설정 없음") }
        let need = SystemCheck.mbps(Double(kbps) / 1000)
        guard let up = check.ifaces.compactMap({ $0.up }).max(), !check.speedRunning else { return Lf("송출 %@", need) }
        return up * 1000 >= Double(kbps) * 1.5 ? Lf("송출 %@ → 보내기 여유 충분", need) : Lf("송출 %@ → 보내기 속도 부족", need)
    }

    private var speedBar: some View {
        let total = max(1, check.ifaces.filter { $0.ip != nil && !$0.selfAssigned }.count)
        let done = check.ifaces.filter { $0.ip != nil && !$0.selfAssigned && !$0.testing && ($0.internet != nil) }.count
        return HStack(spacing: 8) {
            GeometryReader { g in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.white.opacity(0.1))
                    Capsule().fill(check.speedRunning ? Color.orange : Color.green)
                        .frame(width: g.size.width * (check.speedRunning ? Double(done) / Double(total) : 1))
                }
            }
            .frame(height: 4)
            Text(!check.internetCheck ? L("인터넷 속도 측정 꺼짐")
                 : check.speedRunning ? Lf("속도 측정 중… %@초", String(format: "%.1f", check.speedSeconds))
                 : Lf("속도 측정 완료 · %@초", String(format: "%.1f", check.speedSeconds)))
                .font(.system(size: 11)).foregroundColor(.secondary)
                .frame(width: 170, alignment: .trailing)
        }
        .padding(.top, 6)
    }

    // MARK: Remote / devices

    private var remotePanel: some View {
        let ip = check.primaryIP ?? "127.0.0.1"
        let http = engine.apiStatus.contains("8088")
        return Panel(title: L("원격 제어 연결 주소")) {
            VStack(spacing: 0) {
                Row(L("웹 API · 웹 리모트"), http ? "http://\(ip):8088" : L("사용 안 됨"), mono: true)
                Row("Companion (vMix TCP)", "\(ip) : 8099", mono: true)
                Row(L("상태"), engine.apiStatus.isEmpty ? "—" : engine.apiStatus, tint: http ? .green : .orange)
            }
        }
        .frame(maxWidth: .infinity)
    }

    private var devicesPanel: some View {
        let ptz = engine.inputs.filter { $0.config.ptz != nil }
        let ptzOK = ptz.filter { PTZManager.shared.controller(for: $0).link.isConnected }.count
        let mic = AVCaptureDevice.authorizationStatus(for: .audio)
        let screens = NSScreen.screens
        let res = Set(screens.map { "\(Int($0.frame.width))×\(Int($0.frame.height))" }).sorted().joined(separator: ", ")
        return Panel(title: L("장비")) {
            VStack(spacing: 0) {
                Row(L("PTZ 카메라"), ptz.isEmpty ? L("없음") : Lf("%@ / %@ 응답", "\(ptzOK)", "\(ptz.count)"),
                    tint: ptz.isEmpty ? .secondary : (ptzOK == ptz.count ? .green : .orange))
                Row(L("모니터"), Lf("%@대 (%@)", "\(screens.count)", res))
                Row(L("마이크 권한"), mic == .authorized ? L("허용") : (mic == .notDetermined ? L("아직 묻지 않음") : L("거부됨")),
                    tint: mic == .authorized ? .green : .orange)
                Row(L("별도 Spaces"), SystemCheck.separateSpaces ? L("켜짐") : L("꺼짐"),
                    tint: SystemCheck.separateSpaces || screens.count < 2 ? .green : .orange)
            }
        }
        .frame(maxWidth: .infinity)
    }
}

// MARK: - Pieces

private struct Panel<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.system(size: 11)).foregroundColor(.secondary)
            content
        }
        .padding(.horizontal, 12).padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color(white: 0.165)))
    }
}

private struct Row: View {
    let label: String
    let value: String
    var tint: Color = .primary
    var tag = false
    var mono = false

    init(_ label: String, _ value: String, tint: Color = .primary, tag: Bool = false, mono: Bool = false) {
        self.label = label; self.value = value; self.tint = tint; self.tag = tag; self.mono = mono
    }

    var body: some View {
        HStack(spacing: 8) {
            Text(label).foregroundColor(.secondary).lineLimit(1)
            Spacer(minLength: 6)
            Text(value)
                .font(mono ? .system(size: 11, design: .monospaced) : .system(size: 12))
                .foregroundColor(tint)
                .lineLimit(1).truncationMode(.middle)
                .padding(.horizontal, tag ? 6 : 0).padding(.vertical, tag ? 1 : 0)
                .background(tag ? RoundedRectangle(cornerRadius: 4).fill(tint.opacity(0.16)) : nil)
        }
        .font(.system(size: 12))
        .padding(.vertical, 4)
    }
}

private struct Donut: View {
    let value: Double?
    let label: String
    let detail: String
    let color: Color

    var body: some View {
        VStack(spacing: 4) {
            ZStack {
                Circle().stroke(Color.white.opacity(0.1), lineWidth: 7)
                Circle().trim(from: 0, to: CGFloat(max(0, min(1, value ?? 0))))
                    .stroke(color, style: StrokeStyle(lineWidth: 7, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                Text(value.map { "\(Int(($0 * 100).rounded()))%" } ?? "—").font(.system(size: 13, weight: .semibold).monospacedDigit())
            }
            .frame(width: 62, height: 62)
            Text(label).font(.system(size: 12))
            Text(detail).font(.system(size: 10)).foregroundColor(.secondary)
                .lineLimit(2).multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity)
    }
}
