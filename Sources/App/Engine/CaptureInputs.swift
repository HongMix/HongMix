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
        // onScreenWindowsOnly must be false: windows on another desktop or in a full-screen Space
        // (e.g. Chrome in full screen) are not "on screen" and were missing from the list.
        SCShareableContent.getExcludingDesktopWindows(true, onScreenWindowsOnly: false) { content, error in
            var t = CaptureTargets()
            if let c = content {
                t.displays = c.displays.enumerated().map { item in
                    Display(id: item.element.displayID,
                            name: Lf("디스플레이 %@ (%@×%@)", "\(item.offset + 1)", "\(item.element.width)", "\(item.element.height)"))
                }
                // Normal app windows only (layer 0): drops menu bar items, widgets, Notification Center.
                t.windows = c.windows
                    .filter { $0.windowLayer == 0 && ($0.title ?? "").isEmpty == false
                              && ($0.owningApplication?.applicationName ?? "").isEmpty == false
                              && $0.frame.width > 80 && $0.frame.height > 60 }
                    .sorted { a, b in
                        if a.isOnScreen != b.isOnScreen { return a.isOnScreen }
                        return (a.owningApplication?.applicationName ?? "")
                            .localizedCaseInsensitiveCompare(b.owningApplication?.applicationName ?? "") == .orderedAscending
                    }
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
        owner?.streamStopped(stream, error: error)
    }
}

/// Sound of a Desktop Capture input. Runs on its own SCStream (audio only, tiny ignored video) so a
/// sound problem never interrupts the picture, and the filter can be app-based rather than window-based.
/// All state is touched only on the stream's audio queue.
private final class ScreenAudioOutput: NSObject, SCStreamOutput, SCStreamDelegate {
    weak var owner: ScreenCaptureInput?
    /// Reused AudioBufferList storage and interleaved scratch: grown on the first buffers only,
    /// then no allocation in steady state.
    private var ablStorage: UnsafeMutableRawPointer?
    private var ablCapacity = 0
    private var scratch: UnsafeMutablePointer<Float>?
    private var scratchFrames = 0
    private var reportedFormat = false

    deinit {
        ablStorage?.deallocate()
        scratch?.deallocate()
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        // The audio stream also delivers (2×2, 1 fps) screen frames; they are only there to keep SCK quiet.
        guard type == .audio, sampleBuffer.isValid, let owner = owner,
              let fmt = CMSampleBufferGetFormatDescription(sampleBuffer),
              let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(fmt)?.pointee else { return }
        let frames = CMSampleBufferGetNumSamples(sampleBuffer)
        let channels = Int(asbd.mChannelsPerFrame)
        let isFloat = asbd.mFormatFlags & kAudioFormatFlagIsFloat != 0
        let bits = Int(asbd.mBitsPerChannel)
        guard frames > 0, channels > 0, asbd.mFormatID == kAudioFormatLinearPCM,
              (isFloat && bits == 32) || (!isFloat && bits == 16),
              abs(asbd.mSampleRate - 48000) < 1 else {
            // The mixer runs at 48 kHz float; SCK honours the requested format, so this is only a guard.
            if !reportedFormat {
                reportedFormat = true
                owner.audioFormatUnsupported(Lf("오디오 형식을 지원하지 않음 (%@ Hz)", "\(Int(asbd.mSampleRate))"))
            }
            return
        }

        // Ask for the needed AudioBufferList size once per layout (non-interleaved = one buffer per channel).
        var needed = 0
        CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sampleBuffer, bufferListSizeNeededOut: &needed, bufferListOut: nil, bufferListSize: 0,
            blockBufferAllocator: nil, blockBufferMemoryAllocator: nil, flags: 0, blockBufferOut: nil)
        guard needed > 0 else { return }
        if needed > ablCapacity {
            ablStorage?.deallocate()
            ablStorage = UnsafeMutableRawPointer.allocate(byteCount: needed, alignment: 16)
            ablCapacity = needed
        }
        guard let storage = ablStorage else { return }
        let abl = storage.bindMemory(to: AudioBufferList.self, capacity: 1)
        var block: CMBlockBuffer?
        guard CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sampleBuffer, bufferListSizeNeededOut: nil, bufferListOut: abl, bufferListSize: needed,
            blockBufferAllocator: nil, blockBufferMemoryAllocator: nil, flags: 0, blockBufferOut: &block) == noErr
        else { return }

        if frames > scratchFrames {
            scratch?.deallocate()
            scratch = UnsafeMutablePointer<Float>.allocate(capacity: frames * 2)
            scratchFrames = frames
        }
        guard let out = scratch else { return }
        let buffers = UnsafeMutableAudioBufferListPointer(abl)
        let interleaved = asbd.mFormatFlags & kAudioFormatFlagIsNonInterleaved == 0
        // Sample `ch` of frame `i`, whatever the layout. Channels beyond 2 are dropped, mono is doubled.
        func sample(_ ch: Int, _ i: Int) -> Float {
            let c = min(ch, channels - 1)
            let buf: AudioBuffer
            let index: Int
            if interleaved {
                guard buffers.count > 0 else { return 0 }
                buf = buffers[0]; index = i * channels + c
            } else {
                guard c < buffers.count else { return 0 }
                buf = buffers[c]; index = i
            }
            guard let data = buf.mData, (index + 1) * (bits / 8) <= Int(buf.mDataByteSize) else { return 0 }
            return isFloat ? data.assumingMemoryBound(to: Float.self)[index]
                           : Float(data.assumingMemoryBound(to: Int16.self)[index]) / 32768
        }
        if isFloat && !interleaved && channels >= 2 && buffers.count >= 2,
           let l = buffers[0].mData?.assumingMemoryBound(to: Float.self),
           let r = buffers[1].mData?.assumingMemoryBound(to: Float.self),
           Int(buffers[0].mDataByteSize) >= frames * 4, Int(buffers[1].mDataByteSize) >= frames * 4 {
            // Common SCK case: planar Float32 stereo.
            for i in 0..<frames { out[i * 2] = l[i]; out[i * 2 + 1] = r[i] }
        } else {
            for i in 0..<frames { out[i * 2] = sample(0, i); out[i * 2 + 1] = sample(1, i) }
        }
        owner.noteAudioFrame()
        owner.audio.write(out, frames: frames)
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        owner?.audioStreamStopped(stream, error: error)
    }
}

final class ScreenCaptureInput: InputSource {
    private var stream: SCStream?
    private let output = ScreenStreamOutput()
    private let queue = DispatchQueue(label: "screen.capture", qos: .userInteractive)
    /// The input is supposed to be capturing (cleared by stop()) — drives the permission retry.
    private var active = false
    private var retryScheduled = false
    /// Capture is running: ScreenCaptureKit only sends frames when the picture changes, so a still
    /// screen must not count as "signal lost" (that showed black / No Signal until the screen moved).
    private let runLock = NSLock()
    private var _running = false
    private var running: Bool {
        get { runLock.lock(); defer { runLock.unlock() }; return _running }
        set { runLock.lock(); _running = newValue; runLock.unlock() }
    }
    override var linkAlive: Bool { running }
    /// macOS shows its own Screen Recording prompt once per launch at most.
    private static var askedThisLaunch = false

    // Sound (config.captureAudio). Separate stream, guarded by `queue` like `stream`.
    private var audioStream: SCStream?
    private let audioOutput = ScreenAudioOutput()
    private let audioQueue = DispatchQueue(label: "screen.capture.audio", qos: .userInteractive)
    private var audioRetryScheduled = false              // main
    /// Status shown while the picture runs (main); audio notes are appended to it.
    private var videoLabel = ""
    private var audioLabel = ""                          // main: "Sound: …" while the sound runs
    /// Bundle ID of the captured window's app ("" for display capture), for the UI's
    /// "Relaunch Chrome" hint (see ChromeKeepAlive.needsRelaunch). Set on main.
    private(set) var capturedAppBundleID = ""

    /// Without Screen Recording permission: ask macOS once (prompt + adds HongMix to the list),
    /// then keep retrying, so the input starts by itself as soon as the operator switches it on —
    /// no need to delete and re-add the input.
    private func waitForPermission(_ detail: String?) {
        if !ScreenCaptureInput.askedThisLaunch {
            ScreenCaptureInput.askedThisLaunch = true
            DispatchQueue.main.async { _ = CGRequestScreenCaptureAccess() }
        }
        var msg = L("화면 기록 권한이 필요합니다 (시스템 설정 → 개인정보 보호 및 보안 → 화면 및 시스템 오디오 녹음 → HongMix 켜기). 켠 뒤 HongMix를 다시 실행하세요.")
        if let d = detail, !d.isEmpty { msg += " · " + d }
        postStatus(Int32(MC_STATE_ERROR), msg)
        scheduleRetry()
    }

    /// macOS stopped the stream (screen locked, display changed, "Stop" in the menu-bar sharing item,
    /// capture service restarted …). Before, the input stayed dead until it was removed and re-added.
    fileprivate func streamStopped(_ s: SCStream, error: Error) {
        let mine = queue.sync { () -> Bool in
            guard stream === s else { return false }
            stream = nil
            return true
        }
        guard mine else { return }
        running = false
        postStatus(Int32(MC_STATE_ERROR), Lf("캡처 중지됨: %@ — 다시 시작합니다", "\(error.localizedDescription)"))
        scheduleRetry(after: 2)
    }

    private func scheduleRetry(after delay: Double = 3) {
        DispatchQueue.main.async {
            guard self.active, !self.retryScheduled else { return }
            self.retryScheduled = true
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                guard let self = self else { return }
                self.retryScheduled = false
                if self.active && self.queue.sync(execute: { self.stream == nil }) { self.begin() }
            }
        }
    }

    override func start() {
        active = true
        begin()
    }

    private func begin() {
        guard queue.sync(execute: { stream == nil }) else { return }
        // Check silently first: every ScreenCaptureKit call without permission makes macOS show
        // its "would like to record" alert again. Retries only poll this (no alert).
        guard CGPreflightScreenCaptureAccess() else {
            waitForPermission(nil)
            return
        }
        output.owner = self
        let wantDisplay = config.screenDisplayID
        let wantWindow = config.screenWindowID
        let fps = max(1, min(60, config.captureFPS))
        let cursor = config.showCursor
        postStatus(Int32(MC_STATE_CONNECTING), L("화면 캡처 준비 중"))
        SCShareableContent.getExcludingDesktopWindows(false, onScreenWindowsOnly: false) { [weak self] content, error in
            guard let self = self else { return }
            guard let content = content else {
                // Permission missing (or not yet effective): show the real reason and keep retrying.
                let granted = CGPreflightScreenCaptureAccess()
                let reason = error.map { "\($0.localizedDescription)" }
                if granted {
                    self.postStatus(Int32(MC_STATE_ERROR), Lf("화면 목록을 가져오지 못함: %@ — 다시 시도 중", reason ?? "-"))
                    self.scheduleRetry()
                } else {
                    self.waitForPermission(reason)
                }
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
                let owner = w.owningApplication?.bundleIdentifier ?? ""
                DispatchQueue.main.async { self.capturedAppBundleID = owner }
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
            self.queue.sync { self.stream = s }     // recorded before start so a fast failure can clear it
            s.startCapture { err in
                if let err = err {
                    self.postStatus(Int32(MC_STATE_ERROR), Lf("캡처 시작 실패: %@", "\(err.localizedDescription)"))
                    self.queue.async { if self.stream === s { self.stream = nil } }
                    if !CGPreflightScreenCaptureAccess() { self.waitForPermission(err.localizedDescription) } else { self.scheduleRetry() }
                } else {
                    self.running = true
                    self.postStatus(Int32(MC_STATE_RUNNING), label)
                    DispatchQueue.main.async {
                        self.videoLabel = label
                        guard self.config.captureAudio else { return }
                        // The picture restarted on its own: the sound stream may still be running.
                        if self.queue.sync(execute: { self.audioStream != nil }), !self.audioLabel.isEmpty {
                            self.postStatus(Int32(MC_STATE_RUNNING), label + " · " + self.audioLabel)
                        } else {
                            self.beginAudio()
                        }
                    }
                }
            }
        }
    }

    // MARK: Sound

    /// Starts the audio-only stream (main thread). SCK's audio filtering is per application
    /// (WWDC22 "Meet ScreenCaptureKit": a single-window filter yields all audio of the window's app),
    /// so the filter is built from apps, not windows:
    ///  • display capture → every app except HongMix (plus excludesCurrentProcessAudio) = whole Mac;
    ///  • window capture  → only the window's owning app, on any display, so the sound keeps flowing
    ///    while the window is minimised, covered or on another Space.
    private func beginAudio() {
        guard active, config.captureAudio, queue.sync(execute: { audioStream == nil }) else { return }
        audioOutput.owner = self
        let wantDisplay = config.screenDisplayID
        let wantWindow = config.screenWindowID
        SCShareableContent.getExcludingDesktopWindows(false, onScreenWindowsOnly: false) { [weak self] content, error in
            guard let self = self else { return }
            guard let content = content else {
                self.audioNote(Lf("오디오 캡처 시작 실패: %@", error?.localizedDescription ?? "-"), retry: true)
                return
            }
            let me = Bundle.main.bundleIdentifier ?? "com.hongseunghoon.HongMix"
            let display = content.displays.first(where: { $0.displayID == wantDisplay }) ?? content.displays.first
            let filter: SCContentFilter
            let what: String
            if wantWindow != 0 {
                guard let w = content.windows.first(where: { $0.windowID == wantWindow }),
                      let app = w.owningApplication else {
                    self.audioNote(L("오디오: 이 창의 앱을 알 수 없어 소리를 캡처할 수 없음"), retry: false)
                    return
                }
                if app.bundleIdentifier == me {
                    self.audioNote(L("HongMix 자신의 창은 소리를 캡처하지 않습니다 (되먹임 방지)"), retry: false)
                    return
                }
                if let d = display {
                    filter = SCContentFilter(display: d, including: [app], exceptingWindows: [])
                } else {
                    // No SCDisplay (all displays asleep/locked): the window filter is also app-level audio.
                    filter = SCContentFilter(desktopIndependentWindow: w)
                }
                what = Lf("소리: %@", app.applicationName)
            } else {
                guard let d = display else {
                    self.audioNote(L("오디오: 디스플레이를 찾을 수 없음"), retry: true)
                    return
                }
                // HongMix and its helper processes (embedded browser) must never be captured → no feedback.
                let ours = content.applications.filter { $0.bundleIdentifier == me || $0.bundleIdentifier.hasPrefix(me + ".") }
                filter = SCContentFilter(display: d, excludingApplications: ours, exceptingWindows: [])
                what = L("소리: Mac 전체 (HongMix 제외)")
            }
            let cfg = SCStreamConfiguration()
            cfg.capturesAudio = true
            cfg.sampleRate = 48000
            cfg.channelCount = 2
            cfg.excludesCurrentProcessAudio = true
            // Video can't be switched off on macOS 14; keep it negligible.
            cfg.width = 2
            cfg.height = 2
            cfg.minimumFrameInterval = CMTime(value: 1, timescale: 1)
            cfg.queueDepth = 3
            cfg.showsCursor = false
            let s = SCStream(filter: filter, configuration: cfg, delegate: self.audioOutput)
            do {
                try s.addStreamOutput(self.audioOutput, type: .audio, sampleHandlerQueue: self.audioQueue)
                // Without a screen output SCK logs "stream output NOT found" for every dropped frame.
                try s.addStreamOutput(self.audioOutput, type: .screen, sampleHandlerQueue: self.audioQueue)
            } catch {
                self.audioNote(Lf("오디오 캡처 시작 실패: %@", "\(error.localizedDescription)"), retry: false)
                return
            }
            let claimed = self.queue.sync { () -> Bool in
                guard self.active, self.audioStream == nil else { return false }
                self.audioStream = s
                return true
            }
            guard claimed else { return }
            s.startCapture { err in
                if let err = err {
                    self.queue.async { if self.audioStream === s { self.audioStream = nil } }
                    self.audioNote(Lf("오디오 캡처 시작 실패: %@", "\(err.localizedDescription)"), retry: true)
                    return
                }
                // stop() may have run while starting.
                if !self.queue.sync(execute: { self.audioStream === s }) { s.stopCapture { _ in }; return }
                self.noteAudioTrack(true)
                DispatchQueue.main.async {
                    self.audioLabel = what
                    if self.running { self.postStatus(Int32(MC_STATE_RUNNING), self.videoLabel + " · " + what) }
                }
            }
        }
    }

    /// Audio problems never stop the picture: show them next to the running label and retry the sound only.
    private func audioNote(_ message: String, retry: Bool) {
        DispatchQueue.main.async { [weak self] in
            guard let self = self, self.active else { return }
            if self.running { self.postStatus(Int32(MC_STATE_RUNNING), self.videoLabel + " · " + message) }
            guard retry, !self.audioRetryScheduled else { return }
            self.audioRetryScheduled = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
                guard let self = self else { return }
                self.audioRetryScheduled = false
                self.beginAudio()
            }
        }
    }

    fileprivate func audioStreamStopped(_ s: SCStream, error: Error) {
        let mine = queue.sync { () -> Bool in
            guard audioStream === s else { return false }
            audioStream = nil
            return true
        }
        guard mine else { return }
        audio.clear()
        DispatchQueue.main.async { self.audioLabel = "" }
        audioNote(Lf("오디오 캡처 중지됨: %@ — 다시 시작합니다", "\(error.localizedDescription)"), retry: true)
    }

    fileprivate func audioFormatUnsupported(_ message: String) {
        audioNote(message, retry: false)
    }

    override func stop() {
        active = false
        running = false
        let (s, a) = queue.sync { () -> (SCStream?, SCStream?) in
            let pair = (stream, audioStream)
            stream = nil
            audioStream = nil
            return pair
        }
        s?.stopCapture { _ in }
        a?.stopCapture { _ in }
        video.clear()
        audio.clear()
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
            owner.noteAudioFrame()
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
            owner.noteAudioFrame()
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
        noteAudioFrame()
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
                owner.noteAudioFrame()
                owner.audio.write(base.assumingMemoryBound(to: Float.self), frames: min(frames, floats / 2))
            }
        }
    }
}

final class AudioDeviceInput: InputSource {
    private var session: AVCaptureSession?            // queue
    private let delegate = AudioCaptureDelegate()
    private let queue = DispatchQueue(label: "audio.capture", qos: .userInteractive)
    /// Reopen when the interface is plugged back in / unplugged / the session fails.
    private let watch = CaptureDeviceWatch()
    private var active = false
    private var reopenPending = false                  // queue
    private var deviceLabel = ""

    private func reopen(after delay: Double) {
        queue.async {
            guard self.active, !self.reopenPending else { return }
            self.reopenPending = true
            self.queue.asyncAfter(deadline: .now() + delay) {
                self.reopenPending = false
                guard self.active else { return }
                if let s = self.session {
                    s.stopRunning()
                    self.session = nil
                }
                self.configure()
            }
        }
    }

    override func start() {
        guard queue.sync(execute: { session == nil }) else { return }
        active = true
        deviceLabel = name
        watch.start(ids: { [weak self] in
            guard let self = self, !self.config.audioDeviceID.isEmpty else { return [] }
            return [self.config.audioDeviceID]
        }, onChange: { [weak self] in self?.reopen(after: 0.5) })
        AVCaptureDevice.requestAccess(for: .audio) { granted in
            guard granted else {
                self.postStatus(Int32(MC_STATE_ERROR), L("마이크 권한이 거부됨 (시스템 설정 → 개인정보 보호)"))
                return
            }
            self.queue.async { self.configure() }
        }
    }

    private func configure() {
        guard active, session == nil else { return }
        delegate.owner = self
        let s = AVCaptureSession()
        s.beginConfiguration()
        // A chosen interface that isn't connected must not fall back to the built-in mic.
        let dev = config.audioDeviceID.isEmpty
            ? AVCaptureDevice.default(for: .audio)
            : CameraInput.audioDevices().first(where: { $0.uniqueID == config.audioDeviceID })
        guard let d = dev else {
            s.commitConfiguration()
            postStatus(Int32(MC_STATE_ERROR), Lf("장치가 연결되지 않음: %@ — 연결되면 자동으로 다시 엽니다", deviceLabel))
            return
        }
        guard let input = try? AVCaptureDeviceInput(device: d), s.canAddInput(input) else {
            s.commitConfiguration()
            postStatus(Int32(MC_STATE_ERROR), L("오디오 장치를 열 수 없음 — 다시 시도 중"))
            reopen(after: 3)
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
        watch.watch(session: s) { [weak self] in
            self?.postStatus(Int32(MC_STATE_ERROR), L("오디오 장치 오류 — 다시 여는 중"))
            self?.reopen(after: 1)
        }
        postStatus(Int32(MC_STATE_RUNNING), d.localizedName)
    }

    override func stop() {
        active = false
        watch.stop()
        queue.sync {
            session?.stopRunning()
            session = nil
        }
        audio.clear()
    }
}
