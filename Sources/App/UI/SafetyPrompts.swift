import AppKit

/// Asks before an input is closed from its tile ✕ or the tile menu (GitHub #5: inputs lost by accident).
/// "Don't ask again" turns it off; Settings › General › "Ask before closing an input" turns it back on.
/// Undo still restores the last closed input. API / Companion `RemoveInput` never asks.
enum InputCloseConfirm {
    static let key = "confirmInputClose"
    static var enabled: Bool { UserDefaults.standard.object(forKey: key) as? Bool ?? true }

    static func alert(_ name: String) -> NSAlert {
        let a = NSAlert()
        a.messageText = Lf("입력 '%@'을(를) 닫을까요?", name)
        a.informativeText = L("닫은 입력은 위쪽 Undo로 되돌릴 수 있습니다.")
        a.addButton(withTitle: L("닫기")).hasDestructiveAction = true
        a.addButton(withTitle: L("취소"))
        a.showsSuppressionButton = true
        a.suppressionButton?.title = L("다시 묻지 않기")
        return a
    }

    static func close(_ input: InputSource, engine: SwitcherEngine) {
        guard enabled else { engine.requestRemove(input); return }
        let a = alert(input.name)
        let done: (NSApplication.ModalResponse) -> Void = { r in
            guard r == .alertFirstButtonReturn else { return }
            if a.suppressionButton?.state == .on { UserDefaults.standard.set(false, forKey: key) }
            engine.requestRemove(input)
        }
        if let w = NSApp.keyWindow ?? FullscreenOutput.switcherWindow ?? NSApp.mainWindow, w.attachedSheet == nil {
            a.beginSheetModal(for: w, completionHandler: done)
        } else {
            done(a.runModal())
        }
    }
}

/// After a crash, the next launch says so and shows the crash report, so it can be attached to a
/// GitHub issue (GitHub #6 came without one). Only HongMix's own reports newer than the previous launch
/// count — a helper (web engine) crash, a force-quit or a power cut shows nothing.
enum CrashNotice {
    static let lastLaunchKey = "lastLaunchTime"

    static func checkOnLaunch() {
        let d = UserDefaults.standard
        let last = d.double(forKey: lastLaunchKey)
        d.set(Date().timeIntervalSince1970, forKey: lastLaunchKey)
        guard last > 0, let report = newestReport(after: last) else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 8) {     // after the launch screen
            let a = alert((report as NSString).lastPathComponent)
            if a.runModal() == .alertFirstButtonReturn {
                NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: report)])
            }
        }
    }

    static func alert(_ file: String) -> NSAlert {
        let a = NSAlert()
        a.messageText = L("HongMix가 지난번에 예기치 않게 종료되었습니다")
        a.informativeText = Lf("충돌 보고서가 저장되어 있습니다. GitHub 이슈에 이 파일을 첨부해 주시면 원인을 찾는 데 큰 도움이 됩니다.\n\n%@", file)
        a.addButton(withTitle: L("보고서 보기"))
        a.addButton(withTitle: L("닫기"))
        return a
    }

    /// Newest `HongMix-….ips` / `.crash` in ~/Library/Logs/DiagnosticReports modified after `time`.
    static func newestReport(after time: Double) -> String? {
        let dir = (NSHomeDirectory() as NSString).appendingPathComponent("Library/Logs/DiagnosticReports")
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: dir) else { return nil }
        let fm = FileManager.default
        return names
            .filter { $0.hasPrefix("HongMix-") && ($0.hasSuffix(".ips") || $0.hasSuffix(".crash")) }
            .map { (dir as NSString).appendingPathComponent($0) }
            .compactMap { p -> (String, Double)? in
                guard let m = (try? fm.attributesOfItem(atPath: p))?[.modificationDate] as? Date else { return nil }
                return (p, m.timeIntervalSince1970)
            }
            .filter { $0.1 > time }
            .max { $0.1 < $1.1 }?.0
    }
}
