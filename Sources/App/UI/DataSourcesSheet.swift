import SwiftUI
import UniformTypeIdentifiers

/// vMix-style Data Sources manager: Google Sheets / CSV → title fields, row selection, auto next.
struct DataSourcesButton: View {
    @EnvironmentObject var engine: SwitcherEngine
    @ViewState private var show = false

    var body: some View {
        Button { show = true } label: {
            Text("Data")
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(.white)
                .padding(.horizontal, 12)
                .frame(height: 30)
                .background(Theme.button)
                .clipShape(RoundedRectangle(cornerRadius: 3))
        }
        .buttonStyle(.plain)
        .help(L("데이터 소스 — Google Sheets/CSV를 자막에 연결"))
        .sheet(isPresented: $show) { DataSourcesSheet(manager: engine.dataSources).environmentObject(engine) }
    }
}

struct DataSourcesSheet: View {
    @EnvironmentObject var engine: SwitcherEngine
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var manager: DataSourceManager
    @ViewState private var selected: UUID? = nil
    @ViewState private var newName = ""
    @ViewState private var newURL = ""

    init(manager: DataSourceManager) {
        self.manager = manager
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Data Sources").font(.headline)
                Spacer()
                Text(L("Google Sheets는 공유 → '링크가 있는 모든 사용자'로 설정한 뒤 주소를 붙여 넣으세요."))
                    .font(.caption).foregroundColor(.secondary)
            }
            .padding()
            HSplitView {
                VStack(alignment: .leading, spacing: 8) {
                    List(selection: $selected) {
                        ForEach(manager.sources) { s in
                            SourceRow(source: s).tag(s.id)
                        }
                    }
                    GroupBox(L("새 데이터 소스")) {
                        VStack(alignment: .leading, spacing: 6) {
                            TextField(L("이름 (예: Chips)"), text: $newName).textFieldStyle(.roundedBorder)
                            TextField(L("Google Sheets 링크 / CSV URL / 파일 경로"), text: $newURL).textFieldStyle(.roundedBorder)
                            HStack {
                                Button(L("파일 선택…")) {
                                    let p = NSOpenPanel()
                                    p.allowedContentTypes = [.commaSeparatedText, .tabSeparatedText, .plainText]
                                    if p.runModal() == .OK, let u = p.url {
                                        newURL = u.path
                                        if newName.isEmpty { newName = u.deletingPathExtension().lastPathComponent }
                                    }
                                }
                                Spacer()
                                Button(L("추가")) {
                                    let c = DataSourceConfig(name: newName.isEmpty ? "Data \(manager.sources.count + 1)" : newName,
                                                             url: newURL)
                                    manager.add(c)
                                    selected = c.id
                                    newName = ""
                                    newURL = ""
                                }
                                .disabled(newURL.trimmingCharacters(in: .whitespaces).isEmpty)
                                .keyboardShortcut(.defaultAction)
                            }
                        }
                        .padding(4)
                    }
                }
                .padding(8)
                .frame(minWidth: 280, idealWidth: 300, maxWidth: 340)

                Group {
                    if let id = selected, let s = manager.sources.first(where: { $0.id == id }) {
                        SourceDetail(source: s, manager: manager)
                    } else {
                        Text(L("왼쪽에서 데이터 소스를 선택하거나 추가하세요.")).foregroundColor(.secondary)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }
                .frame(minWidth: 620)
            }
            HStack {
                Text(L("API: DataSourceSelectRow Value=이름,,행 · DataSourceNextRow / PreviousRow Value=이름 (vMix 호환)"))
                    .font(.caption).foregroundColor(.secondary)
                Spacer()
                Button(L("닫기")) { dismiss() }
            }
            .padding()
        }
        .frame(minWidth: 980, minHeight: 640)
        .onAppear { if selected == nil { selected = manager.sources.first?.id } }
    }
}

private struct SourceRow: View {
    @ObservedObject var source: DataSource
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(source.config.name).font(.system(size: 13, weight: .semibold))
            Text(source.status).font(.system(size: 11)).foregroundColor(.secondary).lineLimit(1)
        }
        .padding(.vertical, 2)
    }
}

private struct SourceDetail: View {
    @EnvironmentObject var engine: SwitcherEngine
    @ObservedObject var source: DataSource
    @ObservedObject var manager: DataSourceManager
    @ViewState private var bindInput: UUID? = nil
    @ViewState private var bindField = ""
    @ViewState private var bindColumn = 0

    private var titles: [TitleInput] { engine.inputs.compactMap { $0 as? TitleInput } }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                TextField(L("이름"), text: $source.config.name).textFieldStyle(.roundedBorder).frame(width: 160)
                TextField("URL", text: $source.config.url).textFieldStyle(.roundedBorder)
                Button(L("지금 새로고침")) { source.fetch { manager.apply() } }
                Button(role: .destructive) { manager.remove(source) } label: { Text(L("삭제")) }
            }
            HStack(spacing: 16) {
                NumberField(L("갱신 간격"), value: Binding(get: { Int(source.config.pollSeconds) },
                                                       set: { source.config.pollSeconds = Double($0) }), in: 1...3600, unit: L("초"))
                    .frame(width: 200)
                Toggle(L("첫 행은 제목"), isOn: $source.config.hasHeader)
                Spacer()
                Text(source.status).font(.caption).foregroundColor(.secondary)
            }
            // row control
            HStack(spacing: 8) {
                Button { manager.step(source, by: -1) } label: { Label(L("이전 행"), systemImage: "chevron.up") }
                Button { manager.step(source, by: 1) } label: { Label(L("다음 행"), systemImage: "chevron.down") }
                Text(Lf("선택 행: %@ / %@", "\(source.rows.isEmpty ? 0 : source.config.row + 1)", "\(source.rows.count)")).monospacedDigit()
                Spacer()
                Toggle(L("자동 다음 행"), isOn: $source.config.autoNext)
                NumberField(L("간격"), value: Binding(get: { Int(source.config.autoNextSeconds) },
                                                  set: { source.config.autoNextSeconds = Double($0) }), in: 1...600, unit: L("초"))
                    .frame(width: 150)
            }
            // table
            ScrollView([.horizontal, .vertical]) {
                Grid(alignment: .leading, horizontalSpacing: 0, verticalSpacing: 0) {
                    GridRow {
                        Text("#").bold().frame(width: 36, alignment: .leading).padding(4)
                        ForEach(Array(source.headers.enumerated()), id: \.offset) { c in
                            Text(c.element).bold().lineLimit(1).frame(width: 140, alignment: .leading).padding(4)
                        }
                    }
                    .background(Theme.panelDark)
                    ForEach(Array(source.rows.prefix(300).enumerated()), id: \.offset) { r in
                        GridRow {
                            Text("\(r.offset + 1)").monospacedDigit().frame(width: 36, alignment: .leading).padding(4)
                            ForEach(0..<max(source.headers.count, r.element.count), id: \.self) { c in
                                Text(c < r.element.count ? r.element[c] : "").lineLimit(1)
                                    .frame(width: 140, alignment: .leading).padding(4)
                            }
                        }
                        .background(r.offset == source.config.row ? Theme.live.opacity(0.55) : Color.clear)
                        .contentShape(Rectangle())
                        .onTapGesture { manager.select(source, row: r.offset) }
                    }
                }
                .font(.system(size: 12))
            }
            .frame(minHeight: 200)
            .background(Color.black.opacity(0.25))

            // bindings
            GroupBox(L("자막 연결 (선택 행의 열 → 타이틀 필드)")) {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(manager.bindings.filter { $0.sourceID == source.id }) { b in
                        HStack {
                            let t = engine.input(withID: b.inputID)
                            Text("\(t.map { "\(engine.number(of: $0)). \($0.name)" } ?? "(삭제된 입력)") · \(b.fieldID)")
                            Image(systemName: "arrow.left")
                            Text(source.headers.indices.contains(b.column) ? source.headers[b.column] : Lf("열 %@", "\(b.column + 1)"))
                                .bold()
                            Spacer()
                            Button(role: .destructive) { manager.bindings.removeAll { $0.id == b.id } } label: {
                                Image(systemName: "trash")
                            }
                            .buttonStyle(.borderless)
                        }
                    }
                    HStack {
                        Picker(L("타이틀"), selection: $bindInput) {
                            Text(L("선택")).tag(UUID?.none)
                            ForEach(titles) { t in Text("\(engine.number(of: t)). \(t.name)").tag(UUID?.some(t.id)) }
                        }
                        .frame(width: 220)
                        Picker(L("필드"), selection: $bindField) {
                            Text(L("선택")).tag("")
                            if let t = titles.first(where: { $0.id == bindInput }) {
                                ForEach(t.document.fields.filter { $0.kind == .text }) { f in Text(f.id).tag(f.id) }
                            }
                        }
                        .frame(width: 200)
                        Picker(L("열"), selection: $bindColumn) {
                            ForEach(Array(source.headers.enumerated()), id: \.offset) { c in Text(c.element).tag(c.offset) }
                        }
                        .frame(width: 180)
                        Button(L("연결")) {
                            guard let i = bindInput, !bindField.isEmpty else { return }
                            manager.bindings.append(DataBinding(inputID: i, fieldID: bindField, sourceID: source.id, column: bindColumn))
                            manager.apply()
                        }
                        .disabled(bindInput == nil || bindField.isEmpty)
                    }
                    if titles.isEmpty {
                        Text(L("먼저 Add Input → Title로 타이틀 입력을 추가하세요.")).font(.caption).foregroundColor(.secondary)
                    }
                }
                .padding(4)
            }
        }
        .padding(12)
    }
}
