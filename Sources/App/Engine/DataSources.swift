import Foundation
import Combine

/// vMix "Data Sources": a Google Sheet / CSV feeds title fields (chip counts, player names, scores…).
/// Sources are polled; each binding maps one column of the selected row to one title field.
struct DataSourceConfig: Codable, Identifiable, Equatable {
    var id = UUID()
    var name: String
    var url: String                       // Google Sheets link, http(s) CSV/TSV, or a local .csv/.tsv path
    var pollSeconds: Double = 5
    var hasHeader = true
    var row = 0                           // selected data row (0 = first row after the header)
    var autoNext = false
    var autoNextSeconds: Double = 10
}

struct DataBinding: Codable, Equatable, Hashable, Identifiable {
    var id = UUID()
    var inputID: UUID
    var fieldID: String
    var sourceID: UUID
    var column: Int
}

final class DataSource: ObservableObject, Identifiable {
    let id: UUID
    @Published var config: DataSourceConfig
    @Published private(set) var headers: [String] = []
    @Published private(set) var rows: [[String]] = []
    @Published private(set) var status = L("대기 중")
    fileprivate var lastFetch: Date = .distantPast
    fileprivate var lastAutoNext = Date()
    fileprivate var fetching = false

    init(_ c: DataSourceConfig) {
        id = c.id
        config = c
    }

    /// Google Sheets "…/spreadsheets/d/<id>/edit#gid=<gid>" → CSV export URL.
    static func resolvedURL(_ s: String) -> URL? {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.hasPrefix("/") || t.hasPrefix("~") { return URL(fileURLWithPath: (t as NSString).expandingTildeInPath) }
        guard var comps = URLComponents(string: t) else { return nil }
        if comps.host?.contains("docs.google.com") == true, comps.path.contains("/spreadsheets/d/"),
           let r = comps.path.range(of: "/spreadsheets/d/") {
            let rest = comps.path[r.upperBound...]
            let sheetID = rest.split(separator: "/").first.map(String.init) ?? ""
            var gid = "0"
            if let f = comps.fragment, let g = f.components(separatedBy: "gid=").last, !g.isEmpty { gid = g }
            if let g = comps.queryItems?.first(where: { $0.name == "gid" })?.value { gid = g }
            comps.path = "/spreadsheets/d/\(sheetID)/export"
            comps.queryItems = [URLQueryItem(name: "format", value: "csv"), URLQueryItem(name: "gid", value: gid)]
            comps.fragment = nil
        }
        return comps.url
    }

    /// RFC 4180 CSV (quotes, embedded commas/newlines); TSV when the text has tabs and no commas.
    static func parse(_ text: String) -> [[String]] {
        let sep: Character = (text.contains("\t") && !text.contains(",")) ? "\t" : ","
        var rows: [[String]] = []
        var row: [String] = []
        var field = ""
        var quoted = false
        var it = Array(text)
        if it.first == "\u{FEFF}" { it.removeFirst() }
        var i = 0
        while i < it.count {
            let c = it[i]
            if quoted {
                if c == "\"" {
                    if i + 1 < it.count && it[i + 1] == "\"" { field.append("\""); i += 1 } else { quoted = false }
                } else { field.append(c) }
            } else if c == "\"" {
                quoted = true
            } else if c == sep {
                row.append(field); field = ""
            } else if c == "\n" || c == "\r\n" || c == "\r" {
                row.append(field); field = ""
                rows.append(row); row = []
            } else {
                field.append(c)
            }
            i += 1
        }
        if !field.isEmpty || !row.isEmpty { row.append(field); rows.append(row) }
        return rows.filter { !($0.count == 1 && $0[0].isEmpty) }
    }

    func fetch(completion: @escaping () -> Void) {
        guard !fetching, let url = DataSource.resolvedURL(config.url) else {
            if DataSource.resolvedURL(config.url) == nil { status = L("주소를 해석할 수 없음") }
            return
        }
        fetching = true
        lastFetch = Date()
        let apply: (String?, String?) -> Void = { [weak self] text, err in
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.fetching = false
                if let text = text {
                    var all = DataSource.parse(text)
                    if self.config.hasHeader, !all.isEmpty { self.headers = all.removeFirst() } else {
                        self.headers = (0..<(all.map { $0.count }.max() ?? 0)).map { Lf("열 %@", "\($0 + 1)") }
                    }
                    if all != self.rows { self.rows = all }
                    let df = DateFormatter()
                    df.dateFormat = "HH:mm:ss"
                    self.status = Lf("%@행 · %@ 갱신", "\(all.count)", "\(df.string(from: Date()))")
                    completion()
                } else {
                    self.status = Lf("불러오기 실패: %@", "\(err ?? "")")
                }
            }
        }
        if url.isFileURL {
            DispatchQueue.global(qos: .utility).async {
                if let d = try? Data(contentsOf: url) {
                    apply(String(data: d, encoding: .utf8) ?? String(decoding: d, as: UTF8.self), nil)
                } else { apply(nil, L("파일 없음")) }
            }
        } else {
            var req = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 10)
            req.setValue("BraceletMix", forHTTPHeaderField: "User-Agent")
            URLSession.shared.dataTask(with: req) { d, resp, e in
                let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
                if let d = d, code < 400 {
                    apply(String(data: d, encoding: .utf8) ?? String(decoding: d, as: UTF8.self), nil)
                } else {
                    apply(nil, e?.localizedDescription ?? Lf("HTTP %@ — 시트를 '링크가 있는 모든 사용자'로 공유했는지 확인", "\(code)"))
                }
            }.resume()
        }
    }

    func value(column: Int) -> String? {
        guard rows.indices.contains(config.row), rows[config.row].indices.contains(column) else { return nil }
        return rows[config.row][column]
    }
}

final class DataSourceManager: ObservableObject {
    @Published var sources: [DataSource] = []
    @Published var bindings: [DataBinding] = []
    weak var engine: SwitcherEngine?
    private var timer: Timer?

    func start(engine: SwitcherEngine) {
        self.engine = engine
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.tick() }
    }

    private func tick() {
        let now = Date()
        for s in sources {
            if now.timeIntervalSince(s.lastFetch) >= max(1, s.config.pollSeconds) {
                s.fetch { [weak self] in self?.apply() }
            }
            if s.config.autoNext, now.timeIntervalSince(s.lastAutoNext) >= max(1, s.config.autoNextSeconds) {
                s.lastAutoNext = now
                step(s, by: 1, wrap: true)
            }
        }
    }

    /// Pushes the selected rows into the bound title fields (only when the text changed).
    func apply() {
        guard let engine = engine else { return }
        for b in bindings {
            guard let src = sources.first(where: { $0.id == b.sourceID }), let v = src.value(column: b.column),
                  let t = engine.input(withID: b.inputID) as? TitleInput,
                  let idx = t.document.fields.firstIndex(where: { $0.id == b.fieldID }) else { continue }
            if t.document.fields[idx].text != v {
                var doc = t.document
                doc.fields[idx].text = v
                t.document = doc
            }
        }
    }

    func add(_ c: DataSourceConfig) {
        let s = DataSource(c)
        sources.append(s)
        s.fetch { [weak self] in self?.apply() }
    }

    func remove(_ s: DataSource) {
        sources.removeAll { $0.id == s.id }
        bindings.removeAll { $0.sourceID == s.id }
    }

    func source(named n: String) -> DataSource? {
        sources.first { $0.config.name.caseInsensitiveCompare(n) == .orderedSame } ?? sources.first { $0.id.uuidString == n }
    }

    func select(_ s: DataSource, row: Int) {
        guard !s.rows.isEmpty else { s.config.row = max(0, row); return }
        s.config.row = max(0, min(s.rows.count - 1, row))
        apply()
    }

    func step(_ s: DataSource, by d: Int, wrap: Bool = false) {
        guard !s.rows.isEmpty else { return }
        var r = s.config.row + d
        if wrap { r = (r % s.rows.count + s.rows.count) % s.rows.count }
        select(s, row: r)
    }

    var configs: [DataSourceConfig] { sources.map { $0.config } }

    func load(_ cfgs: [DataSourceConfig], _ binds: [DataBinding]) {
        sources = cfgs.map { DataSource($0) }
        bindings = binds
        for s in sources { s.fetch { [weak self] in self?.apply() } }
    }
}
