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
        return (Locale.preferredLanguages.first ?? "ko").hasPrefix("ko") ? .ko : .en
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
    return AppLanguage.english[s] ?? s
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
