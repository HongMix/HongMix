import SwiftUI
import AppKit

/// Test hook (API SnapshotView): renders a HongMix view or alert offscreen to a PNG, so layouts can be
/// checked (and release screenshots made) even when nobody is at the Mac or the screen is locked.
enum UISnapshots {
    static func render(_ name: String, to path: String, engine: SwitcherEngine) -> String? {
        switch name.lowercased() {
        case "focusapproval": return alert(FocusGuard.approvalAlert(), to: path)
        case "focusinfo": return alert(FocusGuard.infoAlert(), to: path)
        case "startup":
            return view(StartupCheckView(onClose: {}).environmentObject(engine), size: NSSize(width: 820, height: 700), to: path)
        case "display":
            return view(DisplaySettingsPanel().environmentObject(engine), size: nil, to: path)
        case "general":
            return view(GeneralSettings().frame(width: 640, height: 900), size: NSSize(width: 640, height: 900), to: path)
        case "topbar":
            return view(TopBar().environmentObject(engine).padding(4).background(Color(white: 0.09)),
                        size: NSSize(width: 1500, height: 44), to: path)
        case "banner":
            return view(VStack(spacing: 0) { TopBar(); ControlFocusBanner(forceShow: true) }
                            .environmentObject(engine).padding(4).background(Color(white: 0.09)),
                        size: NSSize(width: 1500, height: 72), to: path)
        default: return "Unknown view \(name)"
        }
    }

    private static var keep: [NSWindow] = []

    private static func view<V: View>(_ v: V, size: NSSize?, to path: String) -> String? {
        let host = NSHostingView(rootView: v.preferredColorScheme(.dark))
        let sz = size ?? host.fittingSize
        let w = NSWindow(contentRect: NSRect(x: -20000, y: -20000, width: sz.width, height: sz.height),
                         styleMask: [.borderless], backing: .buffered, defer: false)
        w.appearance = NSAppearance(named: .darkAqua)
        w.backgroundColor = NSColor(white: 0.11, alpha: 1)
        w.isReleasedWhenClosed = false
        w.contentView = host
        host.frame = NSRect(origin: .zero, size: sz)
        w.orderFrontRegardless()
        keep.append(w)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            host.layoutSubtreeIfNeeded()
            write(host, to: path)
            w.orderOut(nil)
            keep.removeAll { $0 === w }
        }
        return nil
    }

    private static func alert(_ a: NSAlert, to path: String) -> String? {
        a.window.appearance = NSAppearance(named: .darkAqua)
        a.layout()
        guard let v = a.window.contentView else { return "No alert view" }
        a.window.setFrameOrigin(NSPoint(x: -20000, y: -20000))
        a.window.orderFrontRegardless()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
            write(v, to: path)
            a.window.orderOut(nil)
        }
        return nil
    }

    private static func write(_ v: NSView, to path: String) {
        guard let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds) else { return }
        v.cacheDisplay(in: v.bounds, to: rep)
        try? FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
    }
}
