import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// Finder → HongMix: dropping files creates inputs by type (or replaces a tile's source).
///  • video / audio → Video input (one per file; ⌥ Option with several files → one List input)
///  • image → Image · folder of pictures → Photos · PDF → PDF Slides
enum FileDrop {
    static let dropTypes: [UTType] = [.fileURL, .utf8PlainText, .plainText]

    private static let imageExts: Set<String> = ["png", "jpg", "jpeg", "heic", "heif", "tif", "tiff", "gif", "bmp", "webp"]

    static func isMedia(_ u: URL) -> Bool {
        guard let t = UTType(filenameExtension: u.pathExtension.lowercased()) else { return false }
        return t.conforms(to: .audiovisualContent) || t.conforms(to: .movie) || t.conforms(to: .audio)
            || ["mxf", "mkv", "ts", "m2ts", "webm", "flv"].contains(u.pathExtension.lowercased())
    }

    static func isImage(_ u: URL) -> Bool {
        if imageExts.contains(u.pathExtension.lowercased()) { return true }
        return UTType(filenameExtension: u.pathExtension.lowercased())?.conforms(to: .image) ?? false
    }

    static func isDirectory(_ u: URL) -> Bool {
        var d: ObjCBool = false
        return FileManager.default.fileExists(atPath: u.path, isDirectory: &d) && d.boolValue
    }

    /// Input for one dropped item (nil = not supported).
    static func config(for u: URL) -> InputConfig? {
        let name = (u.lastPathComponent as NSString).deletingPathExtension
        if isDirectory(u) {
            let hasPictures = ((try? FileManager.default.contentsOfDirectory(atPath: u.path)) ?? [])
                .contains { isImage(URL(fileURLWithPath: $0)) }
            guard hasPictures else { return nil }
            var c = InputConfig(kind: .photos, name: u.lastPathComponent)
            c.slides.path = u.path
            return c
        }
        if u.pathExtension.lowercased() == "pdf" {
            var c = InputConfig(kind: .pdfSlides, name: name)
            c.slides.path = u.path
            return c
        }
        if isImage(u) {
            var c = InputConfig(kind: .image, name: u.lastPathComponent)
            c.imagePath = u.path
            return c
        }
        if isMedia(u) {
            var c = InputConfig(kind: .media, name: u.lastPathComponent)
            c.loop = InputConfig.newVideoLoop
            c.url = u.path
            return c
        }
        return nil
    }

    /// New inputs for a drop on the empty input area.
    static func configs(for urls: [URL], asList: Bool) -> (configs: [InputConfig], skipped: [String]) {
        let media = urls.filter { !isDirectory($0) && isMedia($0) }
        var out: [InputConfig] = []
        var skipped: [String] = []
        var rest = urls
        if asList && media.count > 1 {
            var c = InputConfig(kind: .media, name: "List (\(media.count))")
            c.loop = InputConfig.newVideoLoop
            c.playlist = media.map(\.path)
            c.url = media[0].path
            out.append(c)
            rest.removeAll { u in media.contains(u) }
        }
        for u in rest {
            if let c = config(for: u) { out.append(c) } else { skipped.append(u.lastPathComponent) }
        }
        return (out, skipped)
    }

    /// Loads dropped file URLs (main queue completion).
    static func loadURLs(_ providers: [NSItemProvider], _ done: @escaping ([URL]) -> Void) {
        let g = DispatchGroup()
        let lock = NSLock()
        var urls: [(Int, URL)] = []
        for (k, p) in providers.enumerated() where p.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
            g.enter()
            _ = p.loadObject(ofClass: URL.self) { u, _ in
                if let u = u, u.isFileURL { lock.lock(); urls.append((k, u)); lock.unlock() }
                g.leave()
            }
        }
        g.notify(queue: .main) { done(urls.sorted { $0.0 < $1.0 }.map(\.1)) }
    }

    /// Drop on the input area → add inputs (after `afterNumber` when dropped on a tile, else at the end).
    static func add(_ providers: [NSItemProvider], engine: SwitcherEngine, afterNumber: Int? = nil) -> Bool {
        guard providers.contains(where: { $0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) }) else { return false }
        let asList = NSEvent.modifierFlags.contains(.option)
        loadURLs(providers) { urls in
            let r = configs(for: urls, asList: asList)
            for (k, c) in r.configs.enumerated() {
                engine.addInput(c)
                if let n = afterNumber, n + k < engine.inputs.count - 1 {
                    engine.moveInput(from: engine.inputs.count - 1, to: n + k)
                }
            }
            var msg = r.configs.isEmpty ? "" : Lf("파일에서 입력 %@개 추가", "\(r.configs.count)")
            if !r.skipped.isEmpty {
                msg += (msg.isEmpty ? "" : " · ") + Lf("지원하지 않는 파일: %@", r.skipped.prefix(3).joined(separator: ", "))
            }
            if !msg.isEmpty { engine.lastMessage = msg }
        }
        return true
    }

    /// Drop on a tile: files are added as new inputs right after it (the grid is often full, so tiles are
    /// the drop area too); with ⌘ held the first file replaces this input's source instead (settings kept,
    /// asks first when on air). A dragged tile (its UUID string) reorders.
    static func dropOnTile(_ providers: [NSItemProvider], input: InputSource, number: Int, engine: SwitcherEngine) -> Bool {
        if providers.contains(where: { $0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) }) {
            if NSEvent.modifierFlags.contains(.command) {
                loadURLs(providers) { urls in
                    guard let u = urls.first else { return }
                    replace(input, with: u, engine: engine)
                }
                return true
            }
            return add(providers, engine: engine, afterNumber: number)
        }
        guard let p = providers.first(where: { $0.canLoadObject(ofClass: NSString.self) }) else { return false }
        _ = p.loadObject(ofClass: NSString.self) { s, _ in
            guard let s = s as? String, let id = UUID(uuidString: s) else { return }
            DispatchQueue.main.async {
                guard let from = engine.inputs.firstIndex(where: { $0.id == id }) else { return }
                engine.moveInput(from: from, to: number - 1)
            }
        }
        return true
    }

    static func replace(_ input: InputSource, with u: URL, engine: SwitcherEngine) {
        guard let new = config(for: u) else {
            engine.lastMessage = Lf("지원하지 않는 파일: %@", u.lastPathComponent)
            return
        }
        // Always confirm: replacing an input's file is destructive (and a stray ⌘ while dropping must
        // never swap a source silently). On air → stronger wording.
        let onAir = engine.programID == input.id || engine.overlayIDs.contains(input.id)
        let a = NSAlert()
        a.alertStyle = onAir ? .critical : .warning
        a.messageText = onAir ? Lf("%@ 입력이 방송 중입니다", input.name)
                              : Lf("%@번 입력 \"%@\"의 파일을 바꿀까요?", "\(engine.number(of: input))", input.name)
        a.informativeText = onAir ? Lf("%@(으)로 바꾸면 방송 화면이 바로 바뀝니다. 바꿀까요?", u.lastPathComponent)
                                  : Lf("%@(으)로 바꿉니다. 위치·색보정·오디오 설정은 그대로 유지됩니다.", u.lastPathComponent)
        a.addButton(withTitle: L("취소"))     // default (Return) = cancel
        a.addButton(withTitle: L("바꾸기"))
        guard a.runModal() == .alertSecondButtonReturn else { return }
        // keep everything the operator set on the input (position, colour, key, audio, layers …); swap the source
        var c = input.currentConfig()
        c.kind = new.kind
        c.url = new.url
        c.playlist = []
        c.imagePath = new.imagePath
        c.slides.path = new.slides.path
        c.name = new.name
        engine.replaceInput(input, with: c)
        engine.lastMessage = Lf("%@ 입력의 파일을 바꿨습니다", c.name)
    }
}
