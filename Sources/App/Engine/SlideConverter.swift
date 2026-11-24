import Foundation
import AppKit
import WebKit
import PDFKit
import CryptoKit

/// PowerPoint / Keynote / OpenDocument decks → PDF for the PDF Slides input, with nothing extra installed
/// (no Office, Keynote or LibreOffice needed — 2.3.3):
///  1. macOS Quick Look (`qlmanage -p`) lays the deck out as HTML, one `div.slide` per slide;
///  2. a hidden WKWebView prints each slide to its own PDF page (vector, at the deck's slide size).
/// Cached by path + modification time + size in ~/Library/Application Support/HongMix/SlideCache, so
/// re-saving the deck converts it again (the slide input's file watcher reloads it) and an unchanged
/// deck opens instantly. Animations / slide transitions are not kept (still pictures, like any PDF).
enum SlideConverter {
    static let deckExtensions: Set<String> = ["ppt", "pptx", "pps", "ppsx", "pot", "potx", "key", "odp"]

    static func isDeck(_ path: String) -> Bool {
        deckExtensions.contains((path as NSString).pathExtension.lowercased())
    }

    private static var cacheDir: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("HongMix/SlideCache", isDirectory: true)
    }

    private static func hash(_ s: String, _ n: Int) -> String {
        SHA256.hash(data: Data(s.utf8)).map { String(format: "%02x", $0) }.joined().prefix(n).description
    }

    /// Background thread only (waits for the main thread). Returns the PDF path, or an error message.
    static func pdf(for deckPath: String) -> (String?, String?) {
        let fm = FileManager.default
        let deck = (deckPath as NSString).expandingTildeInPath
        guard let attrs = try? fm.attributesOfItem(atPath: deck), let mod = attrs[.modificationDate] as? Date else {
            return (nil, L("프레젠테이션 파일을 열 수 없음"))
        }
        let size = (attrs[.size] as? NSNumber)?.int64Value ?? 0
        let deckKey = hash(deck, 12)
        let out = cacheDir.appendingPathComponent("\(deckKey)-\(hash("\(mod.timeIntervalSince1970)|\(size)", 12)).pdf")
        if fm.fileExists(atPath: out.path) { return (out.path, nil) }
        try? fm.createDirectory(at: cacheDir, withIntermediateDirectories: true)

        // 1. Quick Look → HTML
        let tmp = cacheDir.appendingPathComponent("ql-\(UUID().uuidString)", isDirectory: true)
        try? fm.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: tmp) }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/qlmanage")
        p.arguments = ["-p", "-o", tmp.path, deck]
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return (nil, L("macOS 미리보기를 실행할 수 없음")) }
        let deadline = Date().addingTimeInterval(90)
        while p.isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.1) }
        if p.isRunning { p.terminate(); return (nil, L("프레젠테이션 변환 시간이 초과됨")) }
        let preview = ((try? fm.contentsOfDirectory(atPath: tmp.path)) ?? [])
            .first { $0.hasSuffix(".qlpreview") }
            .map { tmp.appendingPathComponent($0).appendingPathComponent("Preview.html") }
        guard let html = preview, fm.fileExists(atPath: html.path) else {
            return (nil, L("이 프레젠테이션은 macOS 미리보기로 열 수 없습니다. PowerPoint·Keynote에서 PDF로 내보내서 쓰세요."))
        }

        // 2. HTML → one PDF page per slide (WebKit lives on the main thread)
        let sem = DispatchSemaphore(value: 0)
        var result: Data?
        DispatchQueue.main.async {
            let printer = HTMLSlidePrinter()
            printer.run(html: html, readAccess: tmp) { data in
                result = data
                sem.signal()
                _ = printer          // keep alive until done
            }
        }
        if sem.wait(timeout: .now() + 120) == .timedOut { return (nil, L("프레젠테이션 변환 시간이 초과됨")) }
        guard let data = result, (try? data.write(to: out)) != nil else {
            return (nil, L("이 프레젠테이션에서 슬라이드를 찾지 못했습니다. PowerPoint·Keynote에서 PDF로 내보내서 쓰세요."))
        }
        // older conversions of the same deck
        for f in (try? fm.contentsOfDirectory(atPath: cacheDir.path)) ?? []
        where f.hasPrefix(deckKey + "-") && f != out.lastPathComponent {
            try? fm.removeItem(at: cacheDir.appendingPathComponent(f))
        }
        return (out.path, nil)
    }
}

/// Prints every `div.slide` of a Quick Look deck preview to its own PDF page. Main thread.
private final class HTMLSlidePrinter: NSObject, WKNavigationDelegate {
    private var web: WKWebView?
    private var window: NSWindow?
    private var completion: ((Data?) -> Void)?

    func run(html: URL, readAccess: URL, completion: @escaping (Data?) -> Void) {
        self.completion = completion
        let w = WKWebView(frame: NSRect(x: 0, y: 0, width: 1000, height: 800))
        w.navigationDelegate = self
        // off-screen window: WebKit lays out and paints only views that are in a window
        let win = NSWindow(contentRect: NSRect(x: -30000, y: -30000, width: 1000, height: 800),
                           styleMask: [.borderless], backing: .buffered, defer: false)
        win.isReleasedWhenClosed = false
        win.contentView = w
        win.orderFrontRegardless()
        web = w
        window = win
        w.loadFileURL(html, allowingReadAccessTo: readAccess)
        DispatchQueue.main.asyncAfter(deadline: .now() + 100) { [weak self] in self?.finish(nil) }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        let js = """
        (function(){
          var st=document.createElement('style');
          st.textContent='body{margin:0!important;background:#fff!important}div.slide{margin:0!important;box-shadow:none!important;-webkit-box-shadow:none!important}div.loading-slide{display:none!important}';
          document.head.appendChild(st);
          var r=[];document.querySelectorAll('div.slide').forEach(function(d){var b=d.getBoundingClientRect();
            r.push([b.left+window.scrollX,b.top+window.scrollY,b.width,b.height]);});
          return JSON.stringify({rects:r,w:document.documentElement.scrollWidth,h:document.documentElement.scrollHeight});
        })()
        """
        // give embedded pictures / fonts a moment, then measure with the page at its full height
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
            webView.evaluateJavaScript(js) { [weak self] r, _ in
                guard let self, let s = r as? String, let d = s.data(using: .utf8),
                      let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
                      let rects = o["rects"] as? [[Double]], !rects.isEmpty else { self?.finish(nil); return }
                let W = CGFloat(o["w"] as? Double ?? 1000), H = CGFloat(o["h"] as? Double ?? 800)
                self.window?.setContentSize(NSSize(width: max(W, 100), height: max(H, 100)))
                webView.frame = NSRect(x: 0, y: 0, width: max(W, 100), height: max(H, 100))
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    // re-measure after the resize (layout can shift by a few points)
                    webView.evaluateJavaScript(js) { r2, _ in
                        var final = rects
                        if let s2 = r2 as? String, let d2 = s2.data(using: .utf8),
                           let o2 = try? JSONSerialization.jsonObject(with: d2) as? [String: Any],
                           let r2s = o2["rects"] as? [[Double]], r2s.count == rects.count { final = r2s }
                        self.printSlides(final.map { CGRect(x: $0[0], y: $0[1], width: $0[2], height: $0[3]) },
                                         into: PDFDocument(), at: 0)
                    }
                }
            }
        }
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { finish(nil) }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { finish(nil) }

    private func printSlides(_ rects: [CGRect], into doc: PDFDocument, at i: Int) {
        guard let web else { return }
        guard i < rects.count else { finish(doc.pageCount > 0 ? doc.dataRepresentation() : nil); return }
        let cfg = WKPDFConfiguration()
        cfg.rect = rects[i]
        web.createPDF(configuration: cfg) { [weak self] res in
            if case .success(let data) = res, let one = PDFDocument(data: data), let page = one.page(at: 0) {
                doc.insert(page, at: doc.pageCount)
            }
            self?.printSlides(rects, into: doc, at: i + 1)
        }
    }

    private func finish(_ data: Data?) {
        guard let c = completion else { return }
        completion = nil
        web?.navigationDelegate = nil
        window?.orderOut(nil)
        window?.contentView = nil
        web = nil
        window = nil
        c(data)
    }
}
