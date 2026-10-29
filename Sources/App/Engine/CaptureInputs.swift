import Foundation
import AppKit
import AVFoundation
import CoreVideo
import CoreMedia
import ScreenCaptureKit
import WebKit
import Metal
import IOSurface

// MARK: - Desktop / window capture (ScreenCaptureKit)

/// Shareable displays and windows for the Add Input window.
struct CaptureTargets {
    struct Display: Identifiable, Hashable {
        let id: UInt32
        let name: String
    }
    struct Window: Identifiable, Hashable {
        let id: UInt32
        let app: String
        let title: String
    }
    var displays: [Display] = []
    var windows: [Window] = []

    static func load(_ done: @escaping (CaptureTargets, String?) -> Void) {
        SCShareableContent.getExcludingDesktopWindows(true, onScreenWindowsOnly: true) { content, error in
            var t = CaptureTargets()
            if let c = content {
                t.displays = c.displays.enumerated().map { item in
                    Display(id: item.element.displayID,
                            name: Lf("디스플레이 %@ (%@×%@)", "\(item.offset + 1)", "\(item.element.width)", "\(item.element.height)"))
                }
                t.windows = c.windows
                    .filter { ($0.title ?? "").isEmpty == false && $0.frame.width > 80 && $0.frame.height > 60 }
                    .map { Window(id: $0.windowID, app: $0.owningApplication?.applicationName ?? "", title: $0.title ?? "") }
            }
            DispatchQueue.main.async {
                done(t, error.map { _ in L("화면 기록 권한이 필요합니다: 시스템 설정 → 개인정보 보호 및 보안 → 화면 및 시스템 오디오 녹음") })
            }
        }
    }
}

private final class ScreenStreamOutput: NSObject, SCStreamOutput, SCStreamDelegate {
    weak var owner: ScreenCaptureInput?

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, sampleBuffer.isValid else { return }
        if let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false)
            as? [[SCStreamFrameInfo: Any]],
           let raw = attachments.first?[.status] as? Int,
           let status = SCFrameStatus(rawValue: raw), status != .complete {
            return
        }
        if let pb = CMSampleBufferGetImageBuffer(sampleBuffer) { owner?.video.store(pb) }
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        owner?.postStatus(Int32(MC_STATE_ERROR), Lf("캡처 중지됨: %@", "\(error.localizedDescription)"))
    }
}

final class ScreenCaptureInput: InputSource {
    private var stream: SCStream?
    private let output = ScreenStreamOutput()
    private let queue = DispatchQueue(label: "screen.capture", qos: .userInteractive)

    override func start() {
        guard stream == nil else { return }
        output.owner = self
        let wantDisplay = config.screenDisplayID
        let wantWindow = config.screenWindowID
        let fps = max(1, min(60, config.captureFPS))
        let cursor = config.showCursor
        postStatus(Int32(MC_STATE_CONNECTING), L("화면 캡처 준비 중"))
        SCShareableContent.getExcludingDesktopWindows(false, onScreenWindowsOnly: false) { [weak self] content, error in
            guard let self = self else { return }
            guard let content = content else {
                self.postStatus(Int32(MC_STATE_ERROR), L("화면 기록 권한이 필요합니다 (시스템 설정 → 개인정보 보호 및 보안)"))
                _ = error
                return
            }
            let filter: SCContentFilter
            var pixelW = 1920, pixelH = 1080
            var label = ""
            if wantWindow != 0, let w = content.windows.first(where: { $0.windowID == wantWindow }) {
                filter = SCContentFilter(desktopIndependentWindow: w)
                pixelW = Int(w.frame.width * 2)
                pixelH = Int(w.frame.height * 2)
                label = "\(w.owningApplication?.applicationName ?? "") — \(w.title ?? "")"
            } else if let d = content.displays.first(where: { $0.displayID == wantDisplay }) ?? content.displays.first {
                filter = SCContentFilter(display: d, excludingWindows: [])
                if let mode = CGDisplayCopyDisplayMode(d.displayID) {
                    pixelW = mode.pixelWidth
                    pixelH = mode.pixelHeight
                } else {
                    pixelW = d.width * 2
                    pixelH = d.height * 2
                }
                label = Lf("디스플레이 %@×%@", "\(d.width)", "\(d.height)")
            } else {
                self.postStatus(Int32(MC_STATE_ERROR), L("캡처할 화면/창을 찾을 수 없음"))
                return
            }
            // keep within 4K to bound GPU/memory cost
            let scale = min(1.0, 3840.0 / Double(max(pixelW, 1)), 2160.0 / Double(max(pixelH, 1)))
            let cfg = SCStreamConfiguration()
            cfg.width = max(2, Int(Double(pixelW) * scale) & ~1)
            cfg.height = max(2, Int(Double(pixelH) * scale) & ~1)
            cfg.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(fps))
            cfg.pixelFormat = kCVPixelFormatType_32BGRA
            cfg.showsCursor = cursor
            cfg.queueDepth = 5
            let s = SCStream(filter: filter, configuration: cfg, delegate: self.output)
            do {
                try s.addStreamOutput(self.output, type: .screen, sampleHandlerQueue: self.queue)
            } catch {
                self.postStatus(Int32(MC_STATE_ERROR), Lf("캡처 출력 추가 실패: %@", "\(error.localizedDescription)"))
                return
            }
            s.startCapture { err in
                if let err = err {
                    self.postStatus(Int32(MC_STATE_ERROR), Lf("캡처 시작 실패: %@", "\(err.localizedDescription)"))
                } else {
                    self.postStatus(Int32(MC_STATE_RUNNING), label)
                }
            }
            self.queue.async { self.stream = s }
        }
    }

    override func stop() {
        let s = queue.sync { () -> SCStream? in
            let s = stream
            stream = nil
            return s
        }
        s?.stopCapture { _ in }
        video.clear()
    }
}

// MARK: - Web browser input (WKWebView rendered off-screen)

private final class BrowserNavDelegate: NSObject, WKNavigationDelegate {
    weak var owner: BrowserInput?

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        owner?.postStatus(Int32(MC_STATE_RUNNING), webView.url?.absoluteString ?? "")
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        owner?.postStatus(Int32(MC_STATE_ERROR), Lf("로드 실패: %@", "\(error.localizedDescription)"))
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        owner?.postStatus(Int32(MC_STATE_ERROR), Lf("로드 실패: %@", "\(error.localizedDescription)"))
    }
}

/// Page audio → mixer. The injected script reroutes every <video>/<audio> element through Web Audio
/// (so nothing plays on the Mac's speakers, like vMix) and posts 48 kHz stereo PCM as base64 Int16.
private final class BrowserAudioBridge: NSObject, WKScriptMessageHandler {
    weak var owner: BrowserInput?
    private var scratch = [Float]()

    static let script = """
    (() => {
      if (window.__bmAudio) return; window.__bmAudio = true;
      const AC = window.AudioContext || window.webkitAudioContext; if (!AC) return;
      let ctx; try { ctx = new AC({ sampleRate: 48000 }); } catch (e) { ctx = new AC(); }
      const proc = ctx.createScriptProcessor(2048, 2, 2);
      const mute = ctx.createGain(); mute.gain.value = 0;
      proc.connect(mute); mute.connect(ctx.destination);
      window.__bmStats = { calls: 0, posts: 0, hooked: 0, err: '' };
      window.__bmCtx = ctx;
      proc.onaudioprocess = (e) => {
        window.__bmStats.calls++;
        const b = e.inputBuffer, L = b.getChannelData(0), R = b.numberOfChannels > 1 ? b.getChannelData(1) : L;
        const n = L.length; let peak = 0;
        const s = new Int16Array(n * 2);
        for (let i = 0; i < n; i++) {
          let l = L[i], r = R[i];
          const a = Math.abs(l) + Math.abs(r); if (a > peak) peak = a;
          l = l < -1 ? -1 : l > 1 ? 1 : l; r = r < -1 ? -1 : r > 1 ? 1 : r;
          s[2 * i] = l * 32767; s[2 * i + 1] = r * 32767;
        }
        if (peak < 1e-6) return;
        const u8 = new Uint8Array(s.buffer); let bin = '';
        for (let i = 0; i < u8.length; i += 4096) bin += String.fromCharCode.apply(null, u8.subarray(i, i + 4096));
        try { window.webkit.messageHandlers.bmAudio.postMessage({ r: ctx.sampleRate, d: btoa(bin) }); window.__bmStats.posts++; }
        catch (e) { window.__bmStats.err = String(e); }
      };
      const hooked = new WeakSet();
      const hook = (el) => {
        if (!el || hooked.has(el)) return; hooked.add(el);
        try { ctx.createMediaElementSource(el).connect(proc); window.__bmStats.hooked++; }
        catch (e) { window.__bmStats.err = String(e); }
      };
      const scan = () => document.querySelectorAll('video,audio').forEach(hook);
      document.addEventListener('play', (e) => { hook(e.target); ctx.resume(); }, true);
      new MutationObserver(scan).observe(document.documentElement, { childList: true, subtree: true });
      scan();
      setInterval(() => { if (ctx.state !== 'running') ctx.resume(); }, 1000);
    })();
    """

    func userContentController(_ uc: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let owner = owner, let dict = message.body as? [String: Any], let b64 = dict["d"] as? String,
              let data = Data(base64Encoded: b64) else { return }
        let rate = (dict["r"] as? Double) ?? 48000
        let count = data.count / 2            // Int16 samples (interleaved stereo)
        guard count >= 2 else { return }
        let frames = count / 2
        if scratch.count < count { scratch = [Float](repeating: 0, count: count) }
        data.withUnsafeBytes { raw in
            let src = raw.bindMemory(to: Int16.self)
            for i in 0..<count { scratch[i] = Float(src[i]) / 32768 }
        }
        if abs(rate - 48000) < 1 {
            scratch.withUnsafeBufferPointer { owner.audio.write($0.baseAddress!, frames: frames) }
        } else {
            // simple linear resample to 48 kHz (only if WebKit ignored the requested rate)
            let outFrames = Int(Double(frames) * 48000 / rate)
            var out = [Float](repeating: 0, count: outFrames * 2)
            for o in 0..<outFrames {
                let pos = Double(o) * rate / 48000
                let i = min(frames - 1, Int(pos)), j = min(frames - 1, i + 1)
                let f = Float(pos - Double(i))
                out[2 * o] = scratch[2 * i] * (1 - f) + scratch[2 * j] * f
                out[2 * o + 1] = scratch[2 * i + 1] * (1 - f) + scratch[2 * j + 1] * f
            }
            out.withUnsafeBufferPointer { owner.audio.write($0.baseAddress!, frames: outFrames) }
        }
    }
}

/// Video: ScreenCaptureKit captures the browser's own (hidden) window on the GPU — real 60 fps
/// IOSurface frames instead of slow WebKit snapshots.
private final class BrowserStreamOutput: NSObject, SCStreamOutput, SCStreamDelegate {
    weak var owner: BrowserInput?
    var onFailure: (() -> Void)?

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, sampleBuffer.isValid else { return }
        if let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false)
            as? [[SCStreamFrameInfo: Any]],
           let raw = attachments.first?[.status] as? Int,
           let status = SCFrameStatus(rawValue: raw), status != .complete {
            return
        }
        if let pb = CMSampleBufferGetImageBuffer(sampleBuffer) { owner?.video.store(pb) }
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        DispatchQueue.main.async { self.onFailure?() }
    }
}

/// Off-screen browser window that can still take keyboard focus (borderless windows normally can't).
final class BrowserHostWindow: NSWindow {
    var onEscape: (() -> Void)?
    var onKeyChange: ((Bool) -> Void)?
    override var canBecomeKey: Bool { true }
    override func sendEvent(_ event: NSEvent) {
        if event.type == .keyDown && event.keyCode == 53 {   // Esc returns the keyboard to the switcher
            onEscape?()
            return
        }
        super.sendEvent(event)
    }
    override func becomeKey() {
        super.becomeKey()
        onKeyChange?(true)
    }
    override func resignKey() {
        super.resignKey()
        onKeyChange?(false)
    }
}

final class BrowserInput: InputSource {
    private let navDelegate = BrowserNavDelegate()
    private var window: BrowserHostWindow?
    /// vMix BrowserMouseEnabled / BrowserKeyboardEnabled: interact with the page from the Preview / Output monitors.
    @Published var mouseEnabled = true
    @Published var keyboardEnabled = true
    /// True while keystrokes go to the page (after clicking it in a monitor). Esc or clicking elsewhere ends it.
    @Published private(set) var keyboardFocused = false
    private(set) var webView: WKWebView?
    private var timer: Timer?
    private var closeObserver: NSObjectProtocol?
    private let audioBridge = BrowserAudioBridge()
    private let streamOutput = BrowserStreamOutput()
    private var stream: SCStream?
    private let captureQueue = DispatchQueue(label: "browser.capture", qos: .userInteractive)
    /// Below the desktop picture: on screen for WindowServer/WebKit (no throttling), invisible to the user.
    private static let hiddenLevel = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopWindow)) - 1)
    private var busy = false
    private var pool: CVPixelBufferPool?

    override var alphaPremultiplied: Bool { true }

    override func start() {
        DispatchQueue.main.async { self.startOnMain() }
    }

    // MARK: Embedded Chromium engine (preferred: no permissions, GPU frames, audio to the mixer)

    /// Handle of the embedded Chromium browser (nil = WebKit fallback).
    private var engine: OpaquePointer?
    var usesEngine: Bool { engine != nil }
    private var enginePool: CVPixelBufferPool?
    private var enginePoolSize = (0, 0)
    private let blitQueue = MetalContext.shared.device.makeCommandQueue()
    private var audioScratch = [Float]()
    private(set) var pageTitle = ""
    var pageSize: CGSize { CGSize(width: max(320, config.browserWidth), height: max(180, config.browserHeight)) }

    private func startEngine() -> Bool {
        guard mc_web_available() != 0 else { return false }
        let w = Int32(max(320, config.browserWidth)), h = Int32(max(180, config.browserHeight))
        var cb = mc_web_callbacks()
        cb.user = Unmanaged.passUnretained(self).toOpaque()
        cb.on_frame = { user, surf, w, h in
            guard let user = user, let surf = surf else { return }
            Unmanaged<BrowserInput>.fromOpaque(user).takeUnretainedValue().engineFrame(surf, Int(w), Int(h))
        }
        cb.on_cpu_frame = { user, data, w, h, stride in
            guard let user = user, let data = data else { return }
            Unmanaged<BrowserInput>.fromOpaque(user).takeUnretainedValue()
                .video.ingest(bgra: data, width: Int(w), height: Int(h), stride: Int(stride))
        }
        cb.on_audio = { user, planes, channels, frames, rate in
            guard let user = user, let planes = planes, frames > 0 else { return }
            Unmanaged<BrowserInput>.fromOpaque(user).takeUnretainedValue()
                .engineAudio(planes, Int(channels), Int(frames), Int(rate))
        }
        cb.on_status = { user, state, msg in
            guard let user = user else { return }
            let me = Unmanaged<BrowserInput>.fromOpaque(user).takeUnretainedValue()
            let text = msg.map { String(cString: $0) } ?? ""
            switch state {
            case 0: me.postStatus(Int32(MC_STATE_CONNECTING), Lf("불러오는 중: %@", "\(text)"))
            case 1: me.postStatus(Int32(MC_STATE_RUNNING), text); me.captureMode = "engine"
            case 2: me.postStatus(Int32(MC_STATE_ERROR), text)
            default:
                if text.hasPrefix("__bm:") {
                    me.onJSResult?(String(text.dropFirst(5)))
                } else {
                    me.pageTitle = text
                }
            }
        }
        var url = config.browserURL.trimmingCharacters(in: .whitespaces)
        if url.isEmpty { url = "about:blank" } else if !url.contains("://") && !url.hasPrefix("about:") { url = "https://" + url }
        let fps = Int32(max(24, min(60, VideoSlot.programFPS.rounded(.up))))
        guard let h0 = mc_web_open(url, w, h, fps, config.browserTransparent ? 1 : 0, cb) else { return false }
        engine = h0
        captureMode = "engine"
        postStatus(Int32(MC_STATE_CONNECTING), Lf("불러오는 중: %@", "\(url)"))
        return true
    }

    /// GPU copy of Chromium's pooled IOSurface into our own buffer (must finish inside the callback).
    private func engineFrame(_ surfPtr: UnsafeMutableRawPointer, _ w: Int, _ h: Int) {
        guard w > 0, h > 0 else { return }
        let ctx = MetalContext.shared
        let surf = Unmanaged<IOSurface>.fromOpaque(surfPtr).takeUnretainedValue()
        if enginePool == nil || enginePoolSize != (w, h) {
            enginePool = PixelBufferFactory.makePool(width: w, height: h, minimumCount: 4)
            enginePoolSize = (w, h)
        }
        guard let pool = enginePool, let pb = PixelBufferFactory.makeBuffer(pool: pool),
              let dst = ctx.writableTexture(for: pb), let q = blitQueue else { return }
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: w, height: h, mipmapped: false)
        d.usage = [.shaderRead]
        d.storageMode = .shared
        guard let src = ctx.device.makeTexture(descriptor: d, iosurface: surf, plane: 0),
              let cmd = q.makeCommandBuffer(), let blit = cmd.makeBlitCommandEncoder() else { return }
        blit.copy(from: src, sourceSlice: 0, sourceLevel: 0, sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
                  sourceSize: MTLSize(width: min(w, dst.width), height: min(h, dst.height), depth: 1),
                  to: dst, destinationSlice: 0, destinationLevel: 0, destinationOrigin: MTLOrigin(x: 0, y: 0, z: 0))
        blit.endEncoding()
        cmd.commit()
        cmd.waitUntilCompleted()
        video.store(pb)
    }

    /// Chromium audio thread: planar float → interleaved stereo → mixer.
    private func engineAudio(_ planes: UnsafePointer<UnsafePointer<Float>?>, _ channels: Int, _ frames: Int, _ rate: Int) {
        guard let l = planes[0] else { return }
        let r = channels > 1 ? (planes[1] ?? l) : l
        if audioScratch.count < frames * 2 { audioScratch = [Float](repeating: 0, count: frames * 2) }
        for i in 0..<frames {
            audioScratch[2 * i] = l[i]
            audioScratch[2 * i + 1] = r[i]
        }
        audioScratch.withUnsafeBufferPointer { audio.write($0.baseAddress!, frames: frames) }
        _ = rate   // requested 48 kHz from Chromium
    }

    /// Diagnostics (API BrowserEvalJS): result arrives through the page title.
    var onJSResult: ((String) -> Void)?
    func evalJS(_ code: String, result: @escaping (String) -> Void) {
        if let e = engine {
            onJSResult = result
            let data = (try? JSONSerialization.data(withJSONObject: [code])) ?? Data()
            let arr = String(data: data, encoding: .utf8) ?? "[\"\"]"
            let js = "(function(){var __t=document.title;try{document.title='__bm:'+String(eval(\(arr)[0]));}catch(e){document.title='__bm:'+e;}setTimeout(function(){document.title=__t;},200);})();"
            mc_web_eval_js(e, js)
        } else if let web = webView {
            web.evaluateJavaScript(code) { r, err in
                result(r.map { "\($0)" } ?? err?.localizedDescription ?? "nil")
            }
        }
    }

    // Keyboard / IME from the monitors (embedded engine)
    func engineKey(type: Int32, macCode: Int, windowsCode: Int, char: UInt16, unmod: UInt16, mods: UInt) {
        guard let e = engine, keyboardEnabled else { return }
        mc_web_key(e, type, Int32(macCode), Int32(windowsCode), char, unmod, Int32(truncatingIfNeeded: mods))
    }
    func engineIMEComposition(_ text: String, selection: NSRange) {
        guard let e = engine else { return }
        mc_web_ime_set_composition(e, text, Int32(selection.location), Int32(selection.location + selection.length))
    }
    func engineIMECommit(_ text: String) {
        guard let e = engine else { return }
        mc_web_ime_commit(e, text)
    }
    func engineIMECancel() {
        if let e = engine { mc_web_ime_cancel(e) }
    }
    func engineEdit(_ cmd: Int32) {
        if let e = engine { mc_web_edit(e, cmd) }
    }
    func engineFocus(_ on: Bool) {
        if let e = engine { mc_web_focus(e, on ? 1 : 0) }
        keyboardFocused = on && usesEngine
    }

    private func startOnMain() {
        guard webView == nil, engine == nil else { return }
        video.followsProgramRate = true
        if !config.browserUseWebKit && startEngine() { return }
        let w = max(320, config.browserWidth), h = max(180, config.browserHeight)
        let wcfg = WKWebViewConfiguration()
        wcfg.mediaTypesRequiringUserActionForPlayback = []
        audioBridge.owner = self
        let ucc = WKUserContentController()
        ucc.add(audioBridge, name: "bmAudio")
        ucc.addUserScript(WKUserScript(source: BrowserAudioBridge.script, injectionTime: .atDocumentStart,
                                       forMainFrameOnly: false))
        wcfg.userContentController = ucc
        let web = WKWebView(frame: NSRect(x: 0, y: 0, width: w, height: h), configuration: wcfg)
        // keep rendering at full rate even though the window is hidden behind the desktop
        let occl = NSSelectorFromString("_setWindowOcclusionDetectionEnabled:")
        if web.responds(to: occl) { web.perform(occl, with: false as NSNumber) }
        navDelegate.owner = self
        web.navigationDelegate = navDelegate
        if config.browserTransparent { web.setValue(false, forKey: "drawsBackground") }
        // A fully transparent, click-through window keeps WebKit rendering (hidden/occluded views get throttled).
        let win = BrowserHostWindow(contentRect: NSRect(x: 0, y: 0, width: w, height: h),
                                    styleMask: [.borderless], backing: .buffered, defer: false)
        win.onEscape = { [weak self] in self?.releaseKeyboard() }
        win.onKeyChange = { [weak self] key in
            DispatchQueue.main.async { self?.keyboardFocused = key }
        }
        win.isReleasedWhenClosed = false
        win.contentView = web
        win.backgroundColor = .clear
        win.isOpaque = false
        win.alphaValue = 1
        win.level = BrowserInput.hiddenLevel
        win.ignoresMouseEvents = true
        win.hasShadow = false
        win.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        if let screen = NSScreen.main { win.setFrameOrigin(NSPoint(x: screen.frame.minX, y: screen.frame.minY)) }
        win.orderFrontRegardless()
        window = win
        webView = web
        pool = PixelBufferFactory.makePool(width: w, height: h, minimumCount: 3)
        navigate(config.browserURL)
        startWindowCapture(width: w, height: h)
    }

    /// "SCK" = GPU window capture (smooth), "snapshot" = slow fallback (no screen-recording permission).
    private(set) var captureMode = "starting"

    private func startSnapshotFallback() {
        guard timer == nil else { return }
        captureMode = "snapshot"
        postStatus(Int32(MC_STATE_RUNNING), L("⚠︎ 화면 기록 권한이 없어 느린 방식으로 표시 중 — 시스템 설정 → 개인정보 보호 및 보안 → 화면 및 시스템 오디오 녹음에서 HongMix 허용"))
        let fps = Double(max(1, min(30, config.captureFPS)))
        timer = Timer.scheduledTimer(withTimeInterval: 1 / fps, repeats: true) { [weak self] _ in self?.capture() }
    }

    private func startWindowCapture(width: Int, height: Int) {
        guard let win = window else { return }
        let windowID = CGWindowID(win.windowNumber)
        streamOutput.owner = self
        streamOutput.onFailure = { [weak self] in
            self?.stream = nil
            self?.startSnapshotFallback()
        }
        // give WindowServer a moment to register the window
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            SCShareableContent.getExcludingDesktopWindows(false, onScreenWindowsOnly: false) { content, _ in
                DispatchQueue.main.async {
                    guard let self = self else { return }
                    guard let content = content, let scw = content.windows.first(where: { $0.windowID == windowID }) else {
                        self.startSnapshotFallback()     // no screen-recording permission: slower path
                        return
                    }
                    let cfg = SCStreamConfiguration()
                    cfg.width = width & ~1
                    cfg.height = height & ~1
                    cfg.minimumFrameInterval = CMTime(seconds: 1 / max(24, min(60, VideoSlot.programFPS)), preferredTimescale: 60000)
                    cfg.pixelFormat = kCVPixelFormatType_32BGRA
                    cfg.showsCursor = false
                    cfg.queueDepth = 5
                    cfg.shouldBeOpaque = !self.config.browserTransparent
                    let st = SCStream(filter: SCContentFilter(desktopIndependentWindow: scw), configuration: cfg,
                                      delegate: self.streamOutput)
                    do {
                        try st.addStreamOutput(self.streamOutput, type: .screen, sampleHandlerQueue: self.captureQueue)
                    } catch {
                        self.startSnapshotFallback()
                        return
                    }
                    st.startCapture { err in
                        DispatchQueue.main.async {
                            if err != nil { self.stream = nil; self.startSnapshotFallback() } else { self.captureMode = "SCK" }
                        }
                    }
                    self.stream = st
                }
            }
        }
    }

    func navigate(_ urlString: String) {
        DispatchQueue.main.async {
            var s = urlString.trimmingCharacters(in: .whitespaces)
            if !s.contains("://") && !s.hasPrefix("about:") { s = "https://" + s }
            if let e = self.engine {
                mc_web_navigate(e, s)
                self.config.browserURL = s
                return
            }
            guard let url = URL(string: s), let web = self.webView else { return }
            if url.isFileURL {
                web.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
            } else {
                web.load(URLRequest(url: url))
            }
            self.config.browserURL = s
            self.postStatus(Int32(MC_STATE_CONNECTING), Lf("불러오는 중: %@", "\(s)"))
        }
    }

    /// Shows the page in a normal window so it can be clicked/typed into; hiding it returns to off-screen rendering.
    func showInteractive(_ on: Bool) {
        DispatchQueue.main.async {
            guard let win = self.window else { return }
            if on {
                win.styleMask = [.titled, .closable, .resizable]
                win.title = Lf("%@ — 브라우저 (창을 닫으면 숨김)", "\(self.name)")
                win.level = .normal
                win.alphaValue = 1
                win.ignoresMouseEvents = false
                win.isReleasedWhenClosed = false
                win.center()
                win.makeKeyAndOrderFront(nil)
                if self.closeObserver == nil {
                    self.closeObserver = NotificationCenter.default.addObserver(
                        forName: NSWindow.willCloseNotification, object: win, queue: .main) { [weak self] _ in
                        self?.showInteractive(false)
                    }
                }
            } else {
                if let o = self.closeObserver { NotificationCenter.default.removeObserver(o) }
                self.closeObserver = nil
                win.styleMask = [.borderless]
                win.level = BrowserInput.hiddenLevel
                win.ignoresMouseEvents = true
                win.orderFrontRegardless()
            }
        }
    }

    // MARK: Interaction from the monitors (vMix: click the browser in Preview to use mouse and keyboard)

    /// `point` is normalised (0…1, top-left origin) within the page.
    func forwardMouse(_ type: NSEvent.EventType, at point: CGPoint, clickCount: Int = 1,
                      modifiers: NSEvent.ModifierFlags = []) {
        guard mouseEnabled else { return }
        if let e = engine {
            let x = Int32(point.x * pageSize.width), y = Int32(point.y * pageSize.height)
            let m = Int32(truncatingIfNeeded: modifiers.rawValue)
            switch type {
            case .leftMouseDown, .rightMouseDown:
                mc_web_mouse_button(e, x, y, type == .rightMouseDown ? 2 : 0, 0, Int32(clickCount), m)
                if keyboardEnabled && type == .leftMouseDown { engineFocus(true) }
            case .leftMouseUp, .rightMouseUp:
                mc_web_mouse_button(e, x, y, type == .rightMouseUp ? 2 : 0, 1, Int32(clickCount), m)
            case .leftMouseDragged, .mouseMoved:
                mc_web_mouse_move(e, x, y, m | Int32(type == .leftMouseDragged ? 1 << 30 : 0), 0)
            default: break
            }
            return
        }
        guard let web = webView, let win = window else { return }
        let b = web.bounds
        let loc = NSPoint(x: point.x * b.width, y: (1 - point.y) * b.height)
        guard let ev = NSEvent.mouseEvent(with: type, location: loc, modifierFlags: modifiers,
                                          timestamp: ProcessInfo.processInfo.systemUptime,
                                          windowNumber: win.windowNumber, context: nil, eventNumber: 0,
                                          clickCount: clickCount, pressure: type == .leftMouseUp ? 0 : 1) else { return }
        switch type {
        case .leftMouseDown:
            web.mouseDown(with: ev)
            if keyboardEnabled { takeKeyboard() }
        case .leftMouseUp: web.mouseUp(with: ev)
        case .leftMouseDragged: web.mouseDragged(with: ev)
        case .rightMouseDown: web.rightMouseDown(with: ev)
        case .rightMouseUp: web.rightMouseUp(with: ev)
        case .mouseMoved: web.mouseMoved(with: ev)
        default: break
        }
        captureSoon()
    }

    func forwardScroll(dx: CGFloat, dy: CGFloat, at point: CGPoint) {
        guard mouseEnabled else { return }
        if let e = engine {
            mc_web_mouse_wheel(e, Int32(point.x * pageSize.width), Int32(point.y * pageSize.height),
                               Int32(dx.rounded()), Int32(dy.rounded()), 0)
            return
        }
        guard let web = webView, let win = window else { return }
        let b = web.bounds
        let loc = NSPoint(x: point.x * b.width, y: (1 - point.y) * b.height)
        // CGEvent is the only public way to build a scroll-wheel NSEvent
        guard let cg = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2,
                               wheel1: Int32(dy), wheel2: Int32(dx), wheel3: 0) else { return }
        cg.location = CGPoint(x: win.frame.minX + loc.x, y: (NSScreen.screens.first?.frame.height ?? 0) - (win.frame.minY + loc.y))
        guard let ev = NSEvent(cgEvent: cg) else { return }
        web.scrollWheel(with: ev)
        captureSoon()
    }

    /// Keystrokes now go straight to the page (the hidden browser window becomes the key window).
    func takeKeyboard() {
        if usesEngine { engineFocus(true); return }
        guard keyboardEnabled, let win = window, let web = webView else { return }
        win.makeKey()
        win.makeFirstResponder(web)
    }

    func releaseKeyboard() {
        if usesEngine { engineFocus(false); return }
        guard let win = window, win.isKeyWindow else { return }
        NSApp.windows.first { $0 !== win && $0.isVisible && $0.styleMask.contains(.titled) }?.makeKey()
    }

    /// Grab a fresh frame right after an interaction so the monitor feels immediate.
    private func captureSoon() {
        guard timer != nil else { return }       // ScreenCaptureKit already streams every change
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.03) { [weak self] in self?.capture() }
    }

    func reload() { DispatchQueue.main.async { if let e = self.engine { mc_web_reload(e) } else { self.webView?.reload() } } }
    func goBack() { DispatchQueue.main.async { if let e = self.engine { mc_web_back(e) } else { _ = self.webView?.goBack() } } }
    func goForward() { DispatchQueue.main.async { if let e = self.engine { mc_web_forward(e) } else { _ = self.webView?.goForward() } } }

    private func capture() {
        guard !busy, let web = webView, let pool = pool else { return }
        busy = true
        let snap = WKSnapshotConfiguration()
        snap.afterScreenUpdates = false
        snap.snapshotWidth = NSNumber(value: Double(web.bounds.width))
        web.takeSnapshot(with: snap) { [weak self] image, _ in
            guard let self = self else { return }
            self.busy = false
            guard let image = image,
                  let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil),
                  let pb = PixelBufferFactory.makeBuffer(pool: pool) else { return }
            CVPixelBufferLockBaseAddress(pb, [])
            if let base = CVPixelBufferGetBaseAddress(pb) {
                let w = CVPixelBufferGetWidth(pb), h = CVPixelBufferGetHeight(pb)
                memset(base, 0, CVPixelBufferGetBytesPerRow(pb) * h)
                let info = CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
                if let ctx = CGContext(data: base, width: w, height: h, bitsPerComponent: 8,
                                       bytesPerRow: CVPixelBufferGetBytesPerRow(pb),
                                       space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: info) {
                    ctx.interpolationQuality = .high
                    ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
                }
            }
            CVPixelBufferUnlockBaseAddress(pb, [])
            self.video.store(pb)
        }
    }

    override func stop() {
        let teardown = {
            if let e = self.engine {
                mc_web_close(e)
                self.engine = nil
            }
            self.timer?.invalidate()
            self.timer = nil
            self.stream?.stopCapture { _ in }
            self.stream = nil
            self.webView?.configuration.userContentController.removeScriptMessageHandler(forName: "bmAudio")
            self.webView?.stopLoading()
            self.window?.orderOut(nil)
            self.window?.contentView = nil
            self.webView = nil
            self.window = nil
            self.video.clear()
        }
        if Thread.isMainThread { teardown() } else { DispatchQueue.main.sync(execute: teardown) }
    }
}

// MARK: - Audio-only input (microphones, audio interfaces, Dante/AVB virtual devices …)

private final class AudioCaptureDelegate: NSObject, AVCaptureAudioDataOutputSampleBufferDelegate {
    weak var owner: AudioDeviceInput?
    private var scratch = [Float]()

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        guard let owner = owner, let block = CMSampleBufferGetDataBuffer(sampleBuffer) else { return }
        let frames = CMSampleBufferGetNumSamples(sampleBuffer)
        let bytes = CMBlockBufferGetDataLength(block)
        let floats = bytes / MemoryLayout<Float>.size
        guard frames > 0, floats > 0 else { return }
        if scratch.count < floats { scratch = [Float](repeating: 0, count: floats) }
        scratch.withUnsafeMutableBytes { raw in
            guard let base = raw.baseAddress else { return }
            if CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: bytes, destination: base) == kCMBlockBufferNoErr {
                owner.audio.write(base.assumingMemoryBound(to: Float.self), frames: min(frames, floats / 2))
            }
        }
    }
}

final class AudioDeviceInput: InputSource {
    private var session: AVCaptureSession?
    private let delegate = AudioCaptureDelegate()
    private let queue = DispatchQueue(label: "audio.capture", qos: .userInteractive)

    override func start() {
        guard session == nil else { return }
        AVCaptureDevice.requestAccess(for: .audio) { granted in
            guard granted else {
                self.postStatus(Int32(MC_STATE_ERROR), L("마이크 권한이 거부됨 (시스템 설정 → 개인정보 보호)"))
                return
            }
            self.queue.async { self.configure() }
        }
    }

    private func configure() {
        delegate.owner = self
        let s = AVCaptureSession()
        s.beginConfiguration()
        let dev = CameraInput.audioDevices().first(where: { $0.uniqueID == config.audioDeviceID })
            ?? AVCaptureDevice.default(for: .audio)
        guard let d = dev, let input = try? AVCaptureDeviceInput(device: d), s.canAddInput(input) else {
            s.commitConfiguration()
            postStatus(Int32(MC_STATE_ERROR), L("오디오 장치를 열 수 없음"))
            return
        }
        s.addInput(input)
        let out = AVCaptureAudioDataOutput()
        out.audioSettings = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: 48000,
            AVNumberOfChannelsKey: 2,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsNonInterleaved: false,
            AVLinearPCMIsBigEndianKey: false,
        ]
        out.setSampleBufferDelegate(delegate, queue: queue)
        if s.canAddOutput(out) { s.addOutput(out) }
        s.commitConfiguration()
        s.startRunning()
        session = s
        postStatus(Int32(MC_STATE_RUNNING), d.localizedName)
    }

    override func stop() {
        let s = session
        session = nil
        queue.sync { s?.stopRunning() }
        audio.clear()
    }
}
