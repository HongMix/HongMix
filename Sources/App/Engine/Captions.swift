import Foundation
import AVFoundation
import Speech
#if canImport(Translation)
import Translation
#endif

/// Live captions: on-device speech recognition of a mixer bus (Master or A–G), shown in every
/// "Live Captions" title input, optionally translated, and written to an .srt file for the VOD.
final class CaptionEngine: ObservableObject {
    struct Settings: Codable, Equatable {
        var language = "ko-KR"
        var translateTo = ""            // "" = off, else e.g. "en", "es", "ja"
        var bus = 0                     // 0 Master, 1…7 A…G
        var saveSRT = true
        var clearAfter: Double = 4      // seconds of silence before the caption disappears
    }

    @Published var settings = Settings() { didSet { save(); busIndex = settings.bus } }
    /// Read by the render thread (plain Int; written on the main thread).
    private(set) var busIndex = 0
    @Published private(set) var running = false
    @Published private(set) var status = ""
    @Published private(set) var lastText = ""
    @Published private(set) var lastTranslation = ""

    static let languages: [(String, String)] = [("ko-KR", L("한국어")), ("en-US", "English"), ("es-ES", "Español"),
                                                ("ja-JP", "日本語"), ("zh-CN", "中文"), ("fr-FR", "Français"), ("de-DE", "Deutsch")]
    static let targets: [(String, String)] = [("", L("번역 안 함")), ("en", "English"), ("ko", L("한국어")), ("es", "Español"),
                                              ("ja", "日本語"), ("zh-Hans", "中文"), ("fr", "Français"), ("de", "Deutsch")]

    weak var engine: SwitcherEngine?
    private var recognizer: SFSpeechRecognizer?
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var taskStarted = Date()
    private var segmentStart: TimeInterval = 0
    private let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48000, channels: 1, interleaved: false)!

    // audio handed over from the render thread
    private let lock = NSLock()
    private var pending: [Float] = []
    private var feeding = false                  // render thread reads this (lock)
    private var pump: Timer?
    private var lastSpeech = Date()
    private var sessionStart = Date()
    private var srtIndex = 0
    private var srtFile: FileHandle?

    init() {
        if let d = UserDefaults.standard.data(forKey: "captionSettings"),
           let s = try? JSONDecoder().decode(Settings.self, from: d) { settings = s }
        busIndex = settings.bus
    }

    private func save() {
        if let d = try? JSONEncoder().encode(settings) { UserDefaults.standard.set(d, forKey: "captionSettings") }
    }

    // MARK: render thread

    /// Called every tick with the chosen bus (interleaved stereo); cheap copy, mono mixdown.
    func feed(_ p: UnsafePointer<Float>, frames n: Int) {
        lock.lock()
        defer { lock.unlock() }
        guard feeding else { return }
        if pending.count > 48000 * 5 { pending.removeFirst(pending.count - 48000 * 5) }   // never grow unbounded
        pending.reserveCapacity(pending.count + n)
        for i in 0..<n { pending.append((p[i * 2] + p[i * 2 + 1]) * 0.5) }
    }

    var feedBus: Int { busIndex }

    // MARK: control (main thread)

    func start() {
        guard !running else { return }
        SFSpeechRecognizer.requestAuthorization { auth in
            DispatchQueue.main.async {
                guard auth == .authorized else {
                    self.status = L("음성 인식 권한이 필요합니다 (시스템 설정 → 개인정보 보호 및 보안 → 음성 인식)")
                    return
                }
                self.begin()
            }
        }
    }

    private func begin() {
        guard let r = SFSpeechRecognizer(locale: Locale(identifier: settings.language)), r.isAvailable else {
            status = L("이 언어의 음성 인식을 쓸 수 없습니다")
            return
        }
        recognizer = r
        running = true
        sessionStart = Date()
        srtIndex = 0
        openSRT()
        lock.lock(); feeding = true; pending.removeAll(); lock.unlock()
        startTask()
        let t = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in self?.pumpAudio() }
        RunLoop.main.add(t, forMode: .common)
        pump = t
        status = r.supportsOnDeviceRecognition ? L("인식 중 (맥 안에서 처리)") : L("인식 중 (Apple 서버 사용)")
    }

    func stop() {
        guard running else { return }
        running = false
        pump?.invalidate(); pump = nil
        lock.lock(); feeding = false; pending.removeAll(); lock.unlock()
        task?.cancel(); task = nil
        request?.endAudio(); request = nil
        try? srtFile?.close(); srtFile = nil
        publish("", "")
        status = L("중지됨")
    }

    private func startTask() {
        guard let r = recognizer else { return }
        let req = SFSpeechAudioBufferRecognitionRequest()
        req.shouldReportPartialResults = true
        if r.supportsOnDeviceRecognition { req.requiresOnDeviceRecognition = true }
        req.addsPunctuation = true
        request = req
        taskStarted = Date()
        segmentStart = Date().timeIntervalSince(sessionStart)
        task = r.recognitionTask(with: req) { [weak self] result, error in
            guard let self = self else { return }
            DispatchQueue.main.async {
                if let res = result {
                    let text = res.bestTranscription.formattedString
                    self.lastSpeech = Date()
                    self.show(text)
                    if res.isFinal {
                        self.commit(text)
                        self.restartTask()
                    }
                } else if error != nil, self.running {
                    self.restartTask()
                }
            }
        }
    }

    private func restartTask() {
        guard running else { return }
        task?.finish(); task = nil
        request?.endAudio(); request = nil
        startTask()
    }

    private func pumpAudio() {
        lock.lock()
        let samples = pending
        pending.removeAll(keepingCapacity: true)
        lock.unlock()
        if !samples.isEmpty, let req = request,
           let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)) {
            buf.frameLength = AVAudioFrameCount(samples.count)
            samples.withUnsafeBufferPointer { src in
                buf.floatChannelData![0].update(from: src.baseAddress!, count: samples.count)
            }
            req.append(buf)
        }
        // long utterances: finish the segment so the recogniser never hits its time limit
        if Date().timeIntervalSince(taskStarted) > 50 {
            commit(lastText)
            restartTask()
        }
        if !lastText.isEmpty && Date().timeIntervalSince(lastSpeech) > settings.clearAfter {
            publish("", "")
        }
    }

    // MARK: output

    /// Last ~2 lines of the running transcript.
    private static func tail(_ s: String, max: Int = 90) -> String {
        guard s.count > max else { return s }
        let cut = s.suffix(max)
        if let sp = cut.firstIndex(of: " ") { return String(cut[cut.index(after: sp)...]) }
        return String(cut)
    }

    private var translateGen = 0
    private func show(_ text: String) {
        let t = CaptionEngine.tail(text)
        publish(t, lastTranslation)
        guard !settings.translateTo.isEmpty else { return }
        translateGen += 1
        let gen = translateGen
        translate(t) { [weak self] tr in
            guard let self = self, gen == self.translateGen, let tr = tr else { return }
            self.publish(self.lastText, tr)
        }
    }

    private func translate(_ text: String, done: @escaping (String?) -> Void) {
        #if canImport(Translation)
        if #available(macOS 26.0, *) {
            let src = Locale.Language(identifier: String(settings.language.prefix(2)))
            let dst = Locale.Language(identifier: settings.translateTo)
            Task {
                let session = TranslationSession(installedSource: src, target: dst)
                let r = try? await session.translate(text)
                await MainActor.run { done(r?.targetText) }
            }
            return
        }
        #endif
        done(nil)
    }

    private func publish(_ text: String, _ translation: String) {
        lastText = text
        lastTranslation = translation
        guard let e = engine else { return }
        for case let t as TitleInput in e.inputs where t.document.template == .liveCaptions {
            var doc = t.document
            if let i = doc.fields.firstIndex(where: { $0.id == "Caption.Text" }) { doc.fields[i].text = text }
            if let i = doc.fields.firstIndex(where: { $0.id == "Translation.Text" }) {
                doc.fields[i].text = translation
                doc.fields[i].visible = !translation.isEmpty
            }
            if let i = doc.fields.firstIndex(where: { $0.id == "Background.Fill" }) { doc.fields[i].visible = !text.isEmpty }
            if doc != t.document { t.document = doc }
        }
    }

    // MARK: SRT file

    private func openSRT() {
        guard settings.saveSRT else { return }
        let folder = ("~/Movies/HongMix" as NSString).expandingTildeInPath
        try? FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        let path = (folder as NSString).appendingPathComponent("captions_\(f.string(from: Date())).srt")
        FileManager.default.createFile(atPath: path, contents: nil)
        srtFile = FileHandle(forWritingAtPath: path)
    }

    private func commit(_ text: String) {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty, let fh = srtFile else { return }
        let end = Date().timeIntervalSince(sessionStart)
        srtIndex += 1
        func ts(_ s: TimeInterval) -> String {
            let ms = Int((s * 1000).rounded())
            return String(format: "%02d:%02d:%02d,%03d", ms / 3_600_000, ms / 60_000 % 60, ms / 1000 % 60, ms % 1000)
        }
        let block = "\(srtIndex)\n\(ts(segmentStart)) --> \(ts(max(end, segmentStart + 0.5)))\n\(t)\n\n"
        fh.write(block.data(using: .utf8)!)
        segmentStart = end
    }
}
