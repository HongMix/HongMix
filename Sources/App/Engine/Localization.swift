import Foundation

/// App language. Korean is the source language (strings in code); English comes from Resources/en.json.
/// Switchable at runtime from Settings › General — views rebuild, no restart needed.
enum AppLanguage: String, CaseIterable, Identifiable {
    case ko, en
    var id: String { rawValue }
    var label: String { self == .ko ? L("한국어") : "English" }

    static let defaultsKey = "appLanguage"

    /// Current language (UserDefaults; first launch follows the Mac's language).
    static var current: AppLanguage = {
        if let s = UserDefaults.standard.string(forKey: defaultsKey), let l = AppLanguage(rawValue: s) { return l }
        // First launch: Korean if Korean is anywhere in the Mac's language list, otherwise English.
        return Locale.preferredLanguages.contains { $0.hasPrefix("ko") } ? .ko : .en
    }()

    static func set(_ l: AppLanguage) {
        current = l
        UserDefaults.standard.set(l.rawValue, forKey: defaultsKey)
    }

    static let english: [String: String] = {
        guard let url = Bundle.main.url(forResource: "en", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let d = try? JSONDecoder().decode([String: String].self, from: data) else { return [:] }
        return d
    }()
}

/// Localised string (key = the Korean source text).
func L(_ s: String) -> String {
    guard AppLanguage.current == .en else { return s }
    if let e = AppLanguage.english[s] { return e }
    return LocalizedTemplates.match(s) ?? s
}

/// Status text formatted in C ("연결 실패: Connection refused") has no exact key: match it against the
/// "%@" templates in en.json and fill the English template with the same parts. Results are cached.
private enum LocalizedTemplates {
    private static let lock = NSLock()
    private static var cache: [String: String?] = [:]
    private static let templates: [(NSRegularExpression, String)] = AppLanguage.english.compactMap { k, v in
        guard k.contains("%@"), !k.hasPrefix("%@") || k.count > 2 else { return nil }
        let parts = k.components(separatedBy: "%@").map { NSRegularExpression.escapedPattern(for: $0) }
        guard let re = try? NSRegularExpression(pattern: "^" + parts.joined(separator: "(.*?)") + "$",
                                                options: [.dotMatchesLineSeparators]) else { return nil }
        return (re, v)
    }.sorted { $0.0.pattern.count > $1.0.pattern.count }   // most specific template first

    static func match(_ s: String) -> String? {
        lock.lock(); defer { lock.unlock() }
        if let c = cache[s] { return c }
        var out: String?
        let ns = s as NSString
        for (re, en) in templates {
            guard let m = re.firstMatch(in: s, range: NSRange(location: 0, length: ns.length)) else { continue }
            var args = (1..<m.numberOfRanges).map { ns.substring(with: m.range(at: $0)) }
            args = args.map { AppLanguage.english[$0] ?? $0 }   // a translatable part (e.g. a nested status)
            var t = "", it = args.makeIterator(), rest = Substring(en)
            while let r = rest.range(of: "%@") { t += rest[..<r.lowerBound] + (it.next() ?? ""); rest = rest[r.upperBound...] }
            out = t + rest
            break
        }
        if cache.count > 2000 { cache.removeAll() }
        cache[s] = out
        return out
    }
}

/// Localised template with `%@` placeholders filled in order (`%%` = literal percent).
func Lf(_ template: String, _ args: String...) -> String {
    let t = L(template)
    var out = ""
    var it = args.makeIterator()
    var chars = Array(t)
    var i = 0
    while i < chars.count {
        if chars[i] == "%", i + 1 < chars.count {
            if chars[i + 1] == "@" { out += it.next() ?? ""; i += 2; continue }
            if chars[i + 1] == "%" { out += "%"; i += 2; continue }
        }
        out.append(chars[i]); i += 1
    }
    chars.removeAll()
    return out
}
