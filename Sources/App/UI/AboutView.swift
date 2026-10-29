import SwiftUI
import AppKit

/// Settings › General: language.
struct GeneralSettings: View {
    @AppStorage(AppLanguage.defaultsKey) private var language = AppLanguage.current.rawValue

    var body: some View {
        Form {
            Picker(L("언어 / Language"), selection: Binding(get: { language }, set: { v in
                if let l = AppLanguage(rawValue: v) { AppLanguage.set(l) }
                language = v
            })) {
                ForEach(AppLanguage.allCases) { Text($0.label).tag($0.rawValue) }
            }
            .pickerStyle(.radioGroup)
            Text(L("바꾸면 화면이 바로 새 언어로 바뀝니다. 송출·녹화는 그대로 계속됩니다."))
                .font(.caption).foregroundColor(.secondary)
        }
        .formStyle(.grouped)
    }
}

/// Settings › About: credits, contact — and a little secret (click the icon 7 times).
struct AboutView: View {
    @ViewState private var taps = 0
    @ViewState private var showSecret = false

    var body: some View {
        VStack(spacing: 14) {
            Spacer(minLength: 6)
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 96, height: 96)
                .rotationEffect(.degrees(showSecret ? 360 : 0))
                .animation(.spring(response: 0.6, dampingFraction: 0.6), value: showSecret)
                .onTapGesture {
                    taps += 1
                    if taps >= 7 { showSecret = true; taps = 0 }
                }
            Text("HongMix").font(.system(size: 26, weight: .heavy))
            Text("Version \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.2") (Apple Silicon)").font(.caption).foregroundColor(.secondary)

            if showSecret {
                VStack(spacing: 6) {
                    Text("You found it.").font(.headline)
                    Text("HongMix was made by Hong Seunghoon for his friends —\nthe people who fill every broadcast with good times.\nThank you for being one of them.")
                        .multilineTextAlignment(.center)
                    Text("나는 방송을 사랑하고, 기술을 사랑합니다.\n당신들의 의견을 존중합니다.")
                        .multilineTextAlignment(.center).padding(.top, 4)
                    Text("I love broadcasting, and I love technology.\nI respect your opinions.")
                        .font(.callout).multilineTextAlignment(.center).foregroundColor(.secondary)
                    Text("— 홍승훈 Hong Seunghoon").font(.caption).foregroundColor(.secondary)
                }
                .padding(12)
                .frame(maxWidth: 460)
                .background(RoundedRectangle(cornerRadius: 10).fill(Color.accentColor.opacity(0.18)))
                .transition(.scale.combined(with: .opacity))
                .onTapGesture { withAnimation { showSecret = false } }
            }

            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 6) {
                GridRow {
                    Text(L("만든 사람")).foregroundColor(.secondary)
                    Text(L("홍승훈 (Hong Seunghoon) · 대한민국 Korea"))
                }
                GridRow {
                    Text(L("만든 날")).foregroundColor(.secondary)
                    Text("2026-10-28")
                }
                GridRow {
                    Text(L("문의")).foregroundColor(.secondary)
                    // assembled at run time so the address isn't searchable in the public source (spam)
                    let mail = ["honhpd123", "gmail.com"].joined(separator: "@")
                    Link(mail, destination: URL(string: "mailto:" + mail + "?subject=HongMix")!)
                }
                GridRow {
                    Text(L("오픈소스")).foregroundColor(.secondary)
                    HStack(spacing: 8) {
                        Text(String(cString: mc_core_version()))
                        if let u = Bundle.main.url(forResource: "THIRD-PARTY-NOTICES", withExtension: "txt") {
                            Button(L("고지 보기")) { NSWorkspace.shared.open(u) }.buttonStyle(.link)
                        }
                    }
                }
            }
            .font(.system(size: 12))

            Spacer(minLength: 4)
            Text("NDI® is a registered trademark of Vizrt NDI AB. Blackmagic Design, DeckLink and Desktop Video are trademarks of Blackmagic Design Pty. Ltd. This product uses FFmpeg libraries under the LGPL v3. Web Browser inputs use the Chromium Embedded Framework (BSD) and Chromium (see CREDITS.html in the app's Resources). vMix is a trademark of StudioCoast Pty Ltd; HongMix is an independent product and is not affiliated with it.")
                .font(.caption2)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 30)
                .padding(.bottom, 10)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .animation(.easeInOut(duration: 0.3), value: showSecret)
    }
}
