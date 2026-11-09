import Foundation
import AVFoundation
import Speech

/// Long-form live recognition with macOS 26 SpeechAnalyzer + SpeechTranscriber: one continuous session
/// (no one-minute request limit, no restarts → no gaps), volatile (in-progress) and final results with
/// audio time ranges, and a glossary (contextual strings). All callbacks arrive on the main thread.
@available(macOS 26.0, *)
final class CaptionAnalyzerSession {
    var onVolatile: ((String) -> Void)?
    var onFinal: ((String, Double, Double) -> Void)?       // text, start s, end s (since session start)
    var onError: ((String) -> Void)?

    private var analyzer: SpeechAnalyzer?
    private var transcriber: SpeechTranscriber?
    private var continuation: AsyncStream<AnalyzerInput>.Continuation?
    private var resultsTask: Task<Void, Never>?
    private var format: AVAudioFormat?
    private var converter: AVAudioConverter?
    private let source = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48000, channels: 1, interleaved: false)!
    private let lock = NSLock()
    private var ready = false
    private var backlog: [Float] = []                      // audio that arrived while the model was loading

    static func supports(_ language: String) async -> Bool {
        guard SpeechTranscriber.isAvailable else { return false }
        let want = language.lowercased()
        return await SpeechTranscriber.supportedLocales.contains {
            $0.identifier(.bcp47).lowercased() == want || $0.identifier(.bcp47).lowercased().hasPrefix(String(want.prefix(2)))
        }
    }

    /// Prepares the model (downloads it on first use) and starts listening.
    func start(language: String, terms: [String], status: @escaping (String) -> Void) async throws {
        let t = SpeechTranscriber(locale: Locale(identifier: language), transcriptionOptions: [],
                                  reportingOptions: [.volatileResults, .fastResults], attributeOptions: [.audioTimeRange])
        if let req = try await AssetInventory.assetInstallationRequest(supporting: [t]) {
            await MainActor.run { status(L("음성 인식 모델 내려받는 중…")) }
            try await req.downloadAndInstall()
        }
        let fmt = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [t]) ?? source
        let (stream, cont) = AsyncStream.makeStream(of: AnalyzerInput.self, bufferingPolicy: .unbounded)
        let a = SpeechAnalyzer(modules: [t])
        if !terms.isEmpty {
            let ctx = AnalysisContext()
            ctx.contextualStrings = [.general: terms]
            try? await a.setContext(ctx)
        }
        try await a.prepareToAnalyze(in: fmt)
        transcriber = t
        analyzer = a
        format = fmt
        converter = fmt == source ? nil : AVAudioConverter(from: source, to: fmt)
        continuation = cont
        resultsTask = Task { [weak self] in
            do {
                for try await r in t.results {
                    let text = String(r.text.characters).trimmingCharacters(in: .whitespacesAndNewlines)
                    let start = r.range.start.seconds, end = (r.range.start + r.range.duration).seconds
                    await MainActor.run {
                        if r.isFinal { self?.onFinal?(text, start.isFinite ? start : 0, end.isFinite ? end : 0) }
                        else { self?.onVolatile?(text) }
                    }
                }
            } catch {
                let msg = error.localizedDescription
                await MainActor.run { self?.onError?(msg) }
            }
        }
        try await a.start(inputSequence: stream)
        lock.lock()
        ready = true
        let pending = backlog
        backlog = []
        lock.unlock()
        if !pending.isEmpty { feed(pending) }
    }

    /// Mono 48 kHz samples (main thread). Never dropped: kept while the model is still loading (max 30 s).
    func feed(_ samples: [Float]) {
        lock.lock()
        if !ready {
            backlog.append(contentsOf: samples)
            if backlog.count > 48000 * 30 { backlog.removeFirst(backlog.count - 48000 * 30) }
            lock.unlock()
            return
        }
        lock.unlock()
        guard let cont = continuation, !samples.isEmpty,
              let src = AVAudioPCMBuffer(pcmFormat: source, frameCapacity: AVAudioFrameCount(samples.count)) else { return }
        src.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { src.floatChannelData![0].update(from: $0.baseAddress!, count: samples.count) }
        guard let conv = converter, let fmt = format else { cont.yield(AnalyzerInput(buffer: src)); return }
        let cap = AVAudioFrameCount(Double(samples.count) * fmt.sampleRate / source.sampleRate + 64)
        guard let out = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: cap) else { return }
        var given = false
        var err: NSError?
        conv.convert(to: out, error: &err) { _, status in
            if given { status.pointee = .noDataNow; return nil }
            given = true
            status.pointee = .haveData
            return src
        }
        if err == nil, out.frameLength > 0 { cont.yield(AnalyzerInput(buffer: out)) }
    }

    func stop() {
        continuation?.finish()
        continuation = nil
        let a = analyzer
        analyzer = nil
        Task { try? await a?.finalizeAndFinishThroughEndOfInput() }
        resultsTask = nil
    }
}

/// Glossary (hints for the recogniser) and literal corrections ("국정 감사" → "국정감사").
/// Defaults ship in the app (Korean parliamentary / budget terms); the operator can pick other files.
enum CaptionGlossary {
    static func terms(path: String) -> [String] {
        let url = path.isEmpty ? Bundle.main.url(forResource: "caption-terms-ko", withExtension: "txt")
                               : URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
        guard let url, let s = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        return s.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("#") && !$0.hasPrefix("\u{FEFF}#") }
    }

    /// (original, corrected), longest first. CSV: original,corrected (header "원문,교정문" skipped).
    static func corrections(path: String) -> [(String, String)] {
        let url = path.isEmpty ? Bundle.main.url(forResource: "caption-corrections-ko", withExtension: "csv")
                               : URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
        guard let url, var s = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        if s.hasPrefix("\u{FEFF}") { s.removeFirst() }
        var rows: [(String, String)] = []
        for line in s.split(whereSeparator: \.isNewline) {
            let p = line.split(separator: ",", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            guard p.count == 2, !p[0].isEmpty, !p[1].isEmpty, p[0] != "원문", p[0].count <= 80, p[1].count <= 80 else { continue }
            rows.append((p[0], p[1]))
        }
        return rows.sorted { $0.0.count > $1.0.count }
    }

    /// Exact literal replacements only. A single Hangul word never changes inside a longer word
    /// ("감사" → "감사관" must not turn "감사합니다" into "감사관합니다").
    static func apply(_ text: String, _ rules: [(String, String)]) -> String {
        guard !rules.isEmpty, !text.isEmpty else { return text }
        var out = text
        for (orig, fix) in rules {
            let esc = NSRegularExpression.escapedPattern(for: orig)
            let left = (orig.first?.isLetter == true || orig.first?.isNumber == true) ? "(?<![가-힣A-Za-z0-9])" : ""
            var right = ""
            if !orig.contains(" "), let last = orig.unicodeScalars.last, (0xAC00...0xD7A3).contains(last.value) {
                right = "(?![가-힣A-Za-z0-9])"
            } else if let last = orig.last, last.isASCII, last.isLetter || last.isNumber {
                right = "(?![A-Za-z0-9])"
            }
            guard let re = try? NSRegularExpression(pattern: left + esc + right) else { continue }
            out = re.stringByReplacingMatches(in: out, range: NSRange(out.startIndex..., in: out),
                                              withTemplate: NSRegularExpression.escapedTemplate(for: fix))
        }
        return out
    }
}
