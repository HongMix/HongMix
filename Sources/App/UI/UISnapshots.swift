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
        // 2.1.2 / 2.1.3
        case "lang-en", "lang-ko":          // switch the UI language (same as Settings › General)
            let l: AppLanguage = name.lowercased() == "lang-en" ? .en : .ko
            AppLanguage.set(l)
            UserDefaults.standard.set(l.rawValue, forKey: AppLanguage.defaultsKey)
            return nil
        case "remote":          // Settings › Network › Remote control (build 110)
            return view(Form { RemoteControlSection() }.formStyle(.grouped).environmentObject(engine)
                            .frame(width: 640, height: 460), size: NSSize(width: 640, height: 460), to: path)
        case "cleanup":
            return view(MacCleanupPanel().padding(10).frame(width: 800), size: nil, to: path)
        case "healthbanner":
            let fake = SystemHealth.Alert(time: Date(), culprits: [
                SystemHealth.Culprit(pid: 0, name: "WidgetRenderer_Activities",
                                     path: "/System/Library/CoreServices/WidgetRenderer_Activities.app/Contents/MacOS/WidgetRenderer_Activities", cpu: 196)])
            return view(VStack(spacing: 0) { TopBar(); SystemHealthBanner(preview: fake) }
                            .environmentObject(engine).padding(4).background(Color(white: 0.09)),
                        size: NSSize(width: 1500, height: 72), to: path)
        case "encoding":
            var c = OutputConfig.defaultConfig(kind: .stream)
            c.proto = .srt; c.srtHost = "203.0.113.10"; c.cbr = true
            return view(OutputEditor(output: OutputChannel(config: c)).environmentObject(engine).frame(width: 620, height: 1000),
                        size: NSSize(width: 620, height: 1000), to: path)
        default:
            // "inputmonitor-<n>": open the monitor window of input n (captured from the screen — it shows video)
            // "props-<n>-<tab>": Input Settings of input n on a tab (3 = Position, 6 = Layers) — 2.1.4
            let parts = name.lowercased().split(separator: "-")
            // "editor-<n>": the source / connection editor of input n (SRT list, link advice) — 2.2.1
            if parts.count == 2, parts[0] == "editor", let n = Int(parts[1]), n >= 1, n <= engine.inputs.count {
                let i = engine.inputs[n - 1]
                return window(InputEditorSheet(kind: i.kind, editing: i).environmentObject(engine)
                                .frame(width: 820, height: 640), size: NSSize(width: 820, height: 640), title: "Snapshot props")
            }
            // "props-<n>-6-all": Layers tab with every layer selected (align panel) — 2.1.8
            if parts.count == 4, parts[0] == "props", parts[3] == "all", let n = Int(parts[1]), let t = Int(parts[2]),
               t == 6, n >= 1, n <= engine.inputs.count {
                LayersEditor.snapshotSelectAll = true
                return window(InputPropertiesSheet(input: engine.inputs[n - 1], initialTab: t).environmentObject(engine)
                                .frame(width: 1240, height: 860), size: NSSize(width: 1240, height: 860), title: "Snapshot props")
            }
            if parts.count == 3, parts[0] == "props", let n = Int(parts[1]), let t = Int(parts[2]),
               n >= 1, n <= engine.inputs.count {
                return window(InputPropertiesSheet(input: engine.inputs[n - 1], initialTab: t).environmentObject(engine)
                                .frame(width: 1240, height: 860), size: NSSize(width: 1240, height: 860), title: "Snapshot props")
            }
            // "layers-<n>": Layers editor of input n, layer 1 selected, Crop mode — 2.1.4
            if parts.count == 2, parts[0] == "layers", let n = Int(parts[1]), n >= 1, n <= engine.inputs.count {
                return window(LayersEditor(input: engine.inputs[n - 1], previewCropMode: true).environmentObject(engine)
                                .padding(12).frame(width: 1240, height: 860), size: NSSize(width: 1240, height: 860), title: "Snapshot layers")
            }
            if name.lowercased().hasPrefix("inputmonitor-"), let n = Int(name.dropFirst(13)),
               n >= 1, n <= engine.inputs.count {
                InputMonitorWindow.show(engine.inputs[n - 1], engine: engine)
                return nil
            }
            return "Unknown view \(name)"
        }
    }

    private static var keep: [NSWindow] = []

    /// Views with live video (Metal) can't be drawn offscreen: open a real window titled `title`; the
    /// tester captures it by window id (screencapture -l) and closes it (File › Close Window).
    private static func window<V: View>(_ v: V, size: NSSize, title: String) -> String? {
        let w = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.titled, .closable],
                         backing: .buffered, defer: false)
        w.title = title
        w.appearance = NSAppearance(named: .darkAqua)
        w.isReleasedWhenClosed = false
        w.contentView = NSHostingView(rootView: v.preferredColorScheme(.dark))
        w.center()
        w.makeKeyAndOrderFront(nil)
        keep.append(w)
        NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: w, queue: .main) { _ in
            keep.removeAll { $0 === w }
        }
        return nil
    }

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
