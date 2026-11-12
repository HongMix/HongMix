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
        var style = CaptionStyle()
        var engine = "auto"             // auto = SpeechAnalyzer (macOS 26+, long-form) · classic = SFSpeechRecognizer
        var minLineSeconds: Double = 1.5   // a new line pushes an old one out at most this often (0 = no pacing)
        var termsPath = ""              // glossary file ("" = built-in Korean list)
        var correctionsPath = ""        // corrections CSV ("" = built-in)
        var useGlossary = true

        init() {}
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            let d = Settings()
            language = c.value(.language, d.language)
            translateTo = c.value(.translateTo, d.translateTo)
            bus = c.value(.bus, d.bus)
            saveSRT = c.value(.saveSRT, d.saveSRT)
            clearAfter = c.value(.clearAfter, d.clearAfter)
            style = c.value(.style, d.style)
            engine = c.value(.engine, d.engine)
            minLineSeconds = c.value(.minLineSeconds, d.minLineSeconds)
            termsPath = c.value(.termsPath, d.termsPath)
            correctionsPath = c.value(.correctionsPath, d.correctionsPath)
            useGlossary = c.value(.useGlossary, d.useGlossary)
        }
    }

    @Published var settings = Settings() {
        didSet {
            save(); busIndex = settings.bus
            if settings.style != oldValue.style { revealedUpTo = (currentBase + 1) * 1000; rebuildRows() }
            if settings.translateTo != oldValue.translateTo { translationBroken = false; translationText = ""; translateGen += 1; pendingTranslation = nil }
            if settings.correctionsPath != oldValue.correctionsPath || settings.useGlossary != oldValue.useGlossary {
                loadCorrections()
            }
        }
    }
    /// Read by the render thread (plain Int; written on the main thread).
    private(set) var busIndex = 0
    @Published private(set) var running = false
    @Published private(set) var status = ""
    @Published private(set) var lastText = ""
    @Published private(set) var lastTranslation = ""

    static var languages: [(String, String)] { [("ko-KR", L("한국어")), ("en-US", "English"), ("es-ES", "Español"),
                                                ("ja-JP", "日本語"), ("zh-CN", "中文"), ("fr-FR", "Français"), ("de-DE", "Deutsch")] }
    static var targets: [(String, String)] { [("", L("번역 안 함")), ("en", "English"), ("ko", L("한국어")), ("es", "Español"),
                                              ("ja", "日本語"), ("zh-Hans", "中文"), ("fr", "Français"), ("de", "Deutsch")] }

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

    // caption rows (main thread)
    private var finals: [(seg: Int, text: String)] = []   // finished sentences (re-wrapped when the look changes)
    private var taskText = ""                     // transcript of the running recognition task
    private var committedChars = 0                // non-space characters of `taskText` already in `finals`
    private var lastVoice = Date.distantPast      // last time the audio itself was above the speech level
    private var currentBase = 1                   // segment number of the uncommitted text (row id = seg × 1000 + line)
    private var translationText = ""
    private var testClearWork: DispatchWorkItem?
    // recogniser health: never restart in a tight loop (each request costs the speech service a sandbox
    // extension; hundreds per second exhaust it and every request then fails with "Cannot allocate memory")
    private var onDevice = false                  // checked once per start (an XPC round trip — slow)
    private var analyzerBox: AnyObject?           // CaptionAnalyzerSession (macOS 26) while the new engine runs
    private var volatileText = ""                 // new engine: words not final yet
    private var corrections: [(String, String)] = []
    private var revealedUpTo = Int.min            // reading pace: newest row id allowed on screen
    private var lastReveal = Date.distantPast
    private var paceTimer: Timer?
    /// Engine in use (shown in the captions window).
    @Published private(set) var engineLabel = ""
    private var failures = 0
    private var restartWork: DispatchWorkItem?

    init() {
        if let d = UserDefaults.standard.data(forKey: "captionSettings"),
           let s = try? JSONDecoder().decode(Settings.self, from: d) { settings = s }
        busIndex = settings.bus
        CaptionEngine.latestFrame = CaptionFrame(rows: [], style: settings.style)
        loadCorrections()
        let t = Timer(timeInterval: 0.2, repeats: true) { [weak self] _ in self?.paceTick() }
        RunLoop.main.add(t, forMode: .common)
        paceTimer = t
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
        if pending.count > 48000 * 15 { pending.removeFirst(pending.count - 48000 * 15) }  // never grow unbounded
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
        if settings.engine != "classic", #available(macOS 26.0, *) {
            let lang = settings.language
            Task { @MainActor in
                if await CaptionAnalyzerSession.supports(lang) { self.beginAnalyzer() } else { self.beginClassic() }
            }
            return
        }
        beginClassic()
    }

    private var glossaryTerms: [String] { settings.useGlossary ? CaptionGlossary.terms(path: settings.termsPath) : [] }

    private func loadCorrections() {
        corrections = settings.useGlossary ? CaptionGlossary.corrections(path: settings.correctionsPath) : []
    }

    private func startCommon() {
        running = true
        sessionStart = Date()
        srtIndex = 0
        openSRT()
        lock.lock(); feeding = true; pending.removeAll(); lock.unlock()
        let t = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in self?.pumpAudio() }
        RunLoop.main.add(t, forMode: .common)
        pump = t
    }

    /// New engine: one continuous on-device session for the whole show.
    @available(macOS 26.0, *)
    private func beginAnalyzer() {
        guard !running else { return }
        failures = 0
        translationBroken = false
        let s = CaptionAnalyzerSession()
        s.onVolatile = { [weak self] t in self?.analyzerText(t, final: false, start: 0, end: 0) }
        s.onFinal = { [weak self] t, a, b in self?.analyzerText(t, final: true, start: a, end: b) }
        s.onError = { [weak self] msg in
            guard let self, self.running else { return }
            self.status = Lf("새 엔진 오류 — 기존 엔진으로 전환: %@", msg)
            self.switchToClassic()
        }
        analyzerBox = s
        startCommon()
        engineLabel = L("새 엔진 (장시간 · 맥 안에서 처리)")
        status = L("음성 인식 준비 중…")
        let lang = settings.language, terms = glossaryTerms
        Task { @MainActor in
            do {
                try await s.start(language: lang, terms: terms) { [weak self] st in self?.status = st }
                if self.running, self.analyzerBox === s { self.status = L("인식 중 (새 엔진 · 맥 안에서 처리)") }
            } catch {
                guard self.running, self.analyzerBox === s else { return }
                self.status = Lf("새 엔진을 시작하지 못해 기존 엔진으로 전환: %@", error.localizedDescription)
                self.switchToClassic()
            }
        }
    }

    private func switchToClassic() {
        if #available(macOS 26.0, *) { (analyzerBox as? CaptionAnalyzerSession)?.stop() }
        analyzerBox = nil
        volatileText = ""
        guard running, let r = SFSpeechRecognizer(locale: Locale(identifier: settings.language)), r.isAvailable else { return }
        recognizer = r
        onDevice = r.supportsOnDeviceRecognition
        engineLabel = L("기존 엔진")
        startTask()
    }

    private func analyzerText(_ raw: String, final: Bool, start: Double, end: Double) {
        guard running else { return }
        let t = CaptionGlossary.apply(raw, corrections)
        if CaptionEngine.wrongScript(t, language: settings.language) { return }
        lastSpeech = Date()
        if final {
            volatileText = ""
            if !t.isEmpty {
                finals.append((currentBase, t))
                currentBase += 1
                if finals.count > 12 { finals.removeFirst(finals.count - 12) }
                writeSRT(t, start: start, end: max(end, start + 0.5))
            }
        } else {
            volatileText = t
        }
        rebuildRows()
        textChanged(volatileText.isEmpty ? t : volatileText)
    }

    private func beginClassic() {
        guard let r = SFSpeechRecognizer(locale: Locale(identifier: settings.language)), r.isAvailable else {
            status = L("이 언어의 음성 인식을 쓸 수 없습니다")
            return
        }
        recognizer = r
        onDevice = r.supportsOnDeviceRecognition
        failures = 0
        translationBroken = false
        startCommon()
        engineLabel = L("기존 엔진")
        startTask()
        status = onDevice ? L("인식 중 (맥 안에서 처리)") : L("인식 중 (Apple 서버 사용)")
    }

    func stop() {
        guard running else { return }
        running = false
        pump?.invalidate(); pump = nil
        restartWork?.cancel(); restartWork = nil
        if #available(macOS 26.0, *) { (analyzerBox as? CaptionAnalyzerSession)?.stop() }
        analyzerBox = nil
        volatileText = ""
        lock.lock(); feeding = false; pending.removeAll(); lock.unlock()
        task?.cancel(); task = nil
        request?.endAudio(); request = nil
        try? srtFile?.close(); srtFile = nil
        clearRows()
        publish("", "")
        status = L("중지됨")
    }

    private func startTask() {
        guard let r = recognizer else { return }
        let req = SFSpeechAudioBufferRecognitionRequest()
        req.shouldReportPartialResults = true
        if onDevice { req.requiresOnDeviceRecognition = true }
        let terms = glossaryTerms
        if !terms.isEmpty { req.contextualStrings = Array(terms.prefix(100)) }
        req.addsPunctuation = true
        request = req
        taskStarted = Date()
        segmentStart = Date().timeIntervalSince(sessionStart)
        task = r.recognitionTask(with: req) { [weak self] result, error in
            guard let self = self else { return }
            DispatchQueue.main.async {
                if let res = result {
                    if self.failures > 0 {
                        self.failures = 0
                        self.status = self.onDevice ? L("인식 중 (맥 안에서 처리)") : L("인식 중 (Apple 서버 사용)")
                    }
                    let text = res.bestTranscription.formattedString
                    if CaptionEngine.wrongScript(text, language: self.settings.language) { return }
                    self.lastSpeech = Date()
                    self.show(text)
                    if res.isFinal {
                        self.commit(text)
                        self.commitPending()
                        self.restartTask()
                    }
                } else if let error, self.running {
                    self.recognitionFailed(error)
                }
            }
        }
    }

    /// A failed request is retried after a growing pause (0.5 s … 5 s); after many failures in a row the
    /// recogniser itself is recreated. Silence also ends requests with an error — that's normal and cheap.
    private func recognitionFailed(_ error: Error) {
        let ns = error as NSError
        task?.cancel(); task = nil
        request?.endAudio(); request = nil
        // 1110 = "no speech detected" (silence) and 216/301 = request cancelled: normal, restart shortly
        if [1110, 216, 301].contains(ns.code) {
            restartWork?.cancel()
            let w = DispatchWorkItem { [weak self] in
                guard let self, self.running else { return }
                self.taskText = ""
                self.committedChars = 0
                self.startTask()
            }
            restartWork = w
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: w)
            return
        }
        failures += 1
        let delay = min(5.0, 0.5 * pow(2.0, Double(max(0, failures - 1))))
        if failures >= 3 {
            let code = (error as NSError).code
            status = Lf("음성 인식이 응답하지 않아 다시 연결하는 중 (%@회, 오류 %@)", "\(failures)", "\(code)")
        }
        restartWork?.cancel()
        let w = DispatchWorkItem { [weak self] in
            guard let self, self.running else { return }
            if self.failures >= 8, self.failures % 8 == 0,
               let r = SFSpeechRecognizer(locale: Locale(identifier: self.settings.language)) {
                self.recognizer = r          // fresh recogniser (new connection to the speech service)
            }
            self.taskText = ""
            self.committedChars = 0
            self.startTask()
        }
        restartWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: w)
    }

    private func restartTask() {
        guard running else { return }
        taskText = ""
        committedChars = 0
        task?.finish(); task = nil
        request?.endAudio(); request = nil
        startTask()
    }

    private func pumpAudio() {
        // Audio is only taken when something can receive it: while the classic engine reconnects it
        // stays queued (up to 15 s) and is fed when the new request starts — nothing is lost.
        let sink = analyzerBox != nil || request != nil
        lock.lock()
        let level = pending.suffix(4800)
        let samples = sink ? pending : []
        if sink { pending.removeAll(keepingCapacity: true) }
        lock.unlock()
        if !level.isEmpty {
            var e: Float = 0
            for v in level { e += v * v }
            if sqrt(e / Float(level.count)) > 0.006 { lastVoice = Date() }      // ≈ −44 dBFS: someone is talking
        }
        if #available(macOS 26.0, *), let s = analyzerBox as? CaptionAnalyzerSession {
            if !samples.isEmpty { s.feed(samples) }
            if (!finals.isEmpty || !volatileText.isEmpty) && Date().timeIntervalSince(lastSpeech) > settings.clearAfter
                && Date().timeIntervalSince(lastVoice) > settings.clearAfter {
                clearRows()
                publish("", "")
            }
            return
        }
        if !samples.isEmpty, let req = request,
           let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)) {
            buf.frameLength = AVAudioFrameCount(samples.count)
            samples.withUnsafeBufferPointer { src in
                buf.floatChannelData![0].update(from: src.baseAddress!, count: samples.count)
            }
            req.append(buf)
        }
        // long utterances: finish the segment so the recogniser never hits its time limit
        if task != nil, Date().timeIntervalSince(taskStarted) > 50 {     // (not while a retry is waiting)
            commit(taskText)
            commitPending()
            restartTask()
        }
        // a real pause in the audio ends the line group: it moves up and the next words start a new line
        let quiet = Date().timeIntervalSince(lastVoice)
        if !pendingText.isEmpty && quiet > 0.7 && Date().timeIntervalSince(lastSpeech) > 0.4 { commitPending() }
        if (!finals.isEmpty || !lastText.isEmpty) && Date().timeIntervalSince(lastSpeech) > settings.clearAfter
            && Date().timeIntervalSince(lastVoice) > settings.clearAfter {
            clearRows()
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
    private var translationBroken = false        // a failed translation stops further attempts this session
    /// Translation target, or "" when off — translating into the spoken language counts as off.
    private var translateTarget: String {
        let t = settings.translateTo
        return t.isEmpty || settings.language.hasPrefix(t) ? "" : t
    }
    private func show(_ text: String) {
        // Korean spacing is often revised by the recogniser — count committed text by non-space characters
        taskText = text
        committedChars = min(committedChars, CaptionEngine.nonSpace(text))
        rebuildRows()
        textChanged(pendingText.isEmpty ? text : pendingText)
    }

    /// Recognised-now line in the window + translation of the newest text.
    private func textChanged(_ text: String) {
        let t = CaptionEngine.tail(text)
        publish(t, lastTranslation)
        guard !translateTarget.isEmpty, !translationBroken else { return }
        // A translation takes ~1–2 s and the recogniser revises its text several times a second. Cancelling the
        // running one for every revision meant nothing was ever shown while someone kept talking — so let it
        // finish, show it, then translate the newest text.
        if translating { pendingTranslation = t; return }
        startTranslation(t)
    }

    private var translating = false
    private var translationSession: Any?       // TranslationSession (macOS 26+)
    private var translationPair = ""
    private var pendingTranslation: String?
    private func startTranslation(_ t: String) {
        translating = true
        let gen = translateGen
        translate(t) { [weak self] tr in
            guard let self = self else { return }
            self.translating = false
            if gen == self.translateGen, let tr = tr {
                self.translationText = tr
                self.rebuildRows()
                self.publish(self.lastText, tr)
            }
            if let next = self.pendingTranslation, !self.translationBroken {
                self.pendingTranslation = nil
                self.startTranslation(next)
            }
        }
    }

    // MARK: rows (line-by-line captions)

    /// Words of the running task not yet moved into `finals`.
    private var pendingText: String {
        if analyzerBox != nil { return volatileText }
        return CaptionGlossary.apply(rawPendingText, corrections)
    }
    private var rawPendingText: String {
        var skip = committedChars
        var idx = taskText.startIndex
        while skip > 0, idx < taskText.endIndex {
            if !taskText[idx].isWhitespace { skip -= 1 }
            idx = taskText.index(after: idx)
        }
        return String(taskText[idx...]).trimmingCharacters(in: .whitespaces)
    }
    static func nonSpace(_ s: String) -> Int { s.reduce(0) { $0 + ($1.isWhitespace ? 0 : 1) } }

    /// The current lines move up as finished lines; the next words start a new line group.
    private func commitPending() {
        let text = pendingText
        guard !text.isEmpty else { return }
        finals.append((currentBase, text))
        currentBase += 1
        committedChars = CaptionEngine.nonSpace(taskText)
        if finals.count > 12 { finals.removeFirst(finals.count - 12) }
        rebuildRows()
    }

    private var paceBacklog = false
    private func paceTick() {
        if paceBacklog { rebuildRows() }
    }

    private func clearRows() {
        finals = []
        currentBase += 1
        committedChars = CaptionEngine.nonSpace(taskText)
        translationText = ""
        translateGen += 1           // a translation still running belongs to the cleared text
        pendingTranslation = nil
        rebuildRows()
    }

    /// Rows every caption input shows (newest last).
    private func rebuildRows() {
        let st = settings.style
        var rows: [CaptionRow]
        if st.translationOnly && !translateTarget.isEmpty {
            rows = CaptionStyle.wrap(translationText, units: st.lineUnits).enumerated()
                .map { CaptionRow(id: 1_000_000 + $0.offset, text: $0.element, kind: .translation) }
        } else {
            rows = []
            for f in finals {
                for (k, l) in CaptionStyle.wrap(f.text, units: st.lineUnits).enumerated() {
                    rows.append(CaptionRow(id: f.seg * 1000 + k, text: l))
                }
            }
            let cur = CaptionStyle.wrap(pendingText, units: st.lineUnits)
            for (k, l) in cur.enumerated() {
                let draft = st.showDraft && k == cur.count - 1
                rows.append(CaptionRow(id: currentBase * 1000 + k, text: l, kind: draft ? .draft : .final))
            }
            rows = paced(rows, lines: max(1, st.lines))
            if !translateTarget.isEmpty, !translationText.isEmpty, !rows.isEmpty,
               let last = CaptionStyle.wrap(translationText, units: st.lineUnits).last {
                rows = Array(rows.suffix(max(1, st.lines - 1)))
                rows.append(CaptionRow(id: -(currentBase * 1000 + 999), text: last, kind: .translation))
            }
        }
        let frame = CaptionFrame(rows: Array(rows.suffix(max(1, st.lines))), style: st)
        guard let e = engine else { return }
        for case let t as TitleInput in e.inputs where t.document.template == .liveCaptions { t.setCaptionFrame(frame) }
        currentFrame = frame
        CaptionEngine.latestFrame = frame
    }
    /// Reading pace: a new line may push the oldest line off screen at most every `minLineSeconds`
    /// (lines appear at once while there is room). A long backlog catches up so captions never lag far behind.
    private func paced(_ all: [CaptionRow], lines: Int) -> [CaptionRow] {
        let minT = settings.minLineSeconds
        guard minT > 0, !all.isEmpty else {
            revealedUpTo = max(revealedUpTo, all.last?.id ?? revealedUpTo)
            paceBacklog = false
            return all
        }
        let unrevealed = all.filter { $0.id > revealedUpTo }.count
        if unrevealed > lines * 2 {                     // far behind: jump so only `lines` rows are still queued
            revealedUpTo = all[all.count - 1 - lines].id
        }
        while let next = all.first(where: { $0.id > revealedUpTo }) {
            let shown = all.filter { $0.id <= revealedUpTo }.count
            if shown < lines {                          // room on screen: show right away
                revealedUpTo = next.id
            } else if Date().timeIntervalSince(lastReveal) >= minT {
                revealedUpTo = next.id
                lastReveal = Date()
            } else {
                break
            }
        }
        paceBacklog = all.contains { $0.id > revealedUpTo }
        return all.filter { $0.id <= revealedUpTo }
    }

    /// Last frame sent (new caption inputs pick it up).
    private(set) var currentFrame = CaptionFrame(rows: [], style: CaptionStyle())
    /// Main thread: the newest caption frame, for caption inputs created later (session load, Add Input).
    static var latestFrame = CaptionFrame(rows: [], style: CaptionStyle())

    /// Settings › "Send test sentence": shows a sample line group without recognition (style check).
    func sendTest() {
        // sample in the spoken language (Korean captions get a Korean sample even in the English UI)
        let ko = settings.language.hasPrefix("ko")
        let samples = ko ? ["위원님들께서 지금 여기 계시는 위원님들은 대부분 큰 지역 대도시에 있는 위원님들이신데",
                            "연락한 부분이 많이 있습니다. 자료를 다시 한번 확인해 주시기 바랍니다."]
                         : ["Most of the committee members here today represent large cities and major regions",
                            "There are many areas we contacted. Please check the documents once more."]
        let text = samples[currentBase % samples.count]
        finals.append((currentBase, text))
        currentBase += 1
        if finals.count > 12 { finals.removeFirst(finals.count - 12) }
        lastSpeech = Date()
        rebuildRows()
        testClearWork?.cancel()
        let w = DispatchWorkItem { [weak self] in
            guard let self, !self.running else { return }
            self.clearRows()
        }
        testClearWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + max(3, settings.clearAfter + 4), execute: w)
    }

    func clearCaptions() {
        clearRows()
        publish("", "")
    }

    /// Korean recognition that came back as only kana / hanzi is a wrong-language guess: drop it.
    static func wrongScript(_ text: String, language: String) -> Bool {
        guard language.hasPrefix("ko") else { return false }
        var hangul = 0, foreign = 0
        for u in text.unicodeScalars {
            if (0xAC00...0xD7A3).contains(u.value) { hangul += 1 }
            else if (0x3040...0x30FF).contains(u.value) || (0x3400...0x9FFF).contains(u.value) { foreign += 1 }
        }
        return foreign > 0 && (hangul == 0 || foreign > hangul)
    }

    private func translate(_ text: String, done: @escaping (String?) -> Void) {
        #if canImport(Translation)
        if #available(macOS 26.0, *) {
            let src = Locale.Language(identifier: String(settings.language.prefix(2)))
            let dst = Locale.Language(identifier: settings.translateTo)
            // one session per language pair (making one for every line added most of the delay)
            let pair = "\(settings.language.prefix(2))>\(settings.translateTo)"
            let session: TranslationSession
            if pair == translationPair, let s = translationSession as? TranslationSession { session = s }
            else {
                session = TranslationSession(installedSource: src, target: dst)
                translationSession = session
                translationPair = pair
            }
            Task {
                do {
                    let r = try await session.translate(text)
                    await MainActor.run { done(r.targetText) }
                } catch {
                    await MainActor.run {
                        if !self.translationBroken {
                            self.translationBroken = true
                            self.status = L("번역 실패 — 시스템 설정 › 일반 › 언어 및 지역 › 번역 언어에서 언어를 내려받으세요 (자막은 계속 표시)")
                        }
                        done(nil)
                    }
                }
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

    /// New engine: an SRT block with the recogniser's own audio times.
    private func writeSRT(_ text: String, start: Double, end: Double) {
        guard let fh = srtFile else { return }
        srtIndex += 1
        func ts(_ s: TimeInterval) -> String {
            let ms = Int((max(0, s) * 1000).rounded())
            return String(format: "%02d:%02d:%02d,%03d", ms / 3_600_000, ms / 60_000 % 60, ms / 1000 % 60, ms % 1000)
        }
        fh.write("\(srtIndex)\n\(ts(start)) --> \(ts(end))\n\(text)\n\n".data(using: .utf8)!)
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
