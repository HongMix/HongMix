import SwiftUI
import AppKit

/// Template picker with live thumbnails: built-in templates by category + the user's saved templates.
struct TitleGallery: View {
    @Binding var selection: TitleDocument?
    var onPick: (TitleDocument) -> Void = { _ in }
    @ObservedObject private var library = TitleLibrary.shared
    @ViewState private var category: String = L("전체")   // internal id (shown via L())

    private let columns = [GridItem(.adaptive(minimum: 168, maximum: 220), spacing: 10)]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Picker("", selection: $category) {
                Text(L("전체")).tag("전체")
                ForEach(TitleTemplate.Category.allCases) { Text(L($0.rawValue)).tag($0.rawValue) }
                if !library.templates.isEmpty { Text(L("내 템플릿")).tag("내 템플릿") }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            ScrollView {
                LazyVGrid(columns: columns, spacing: 10) {
                    if category == L("전체") || category == L("내 템플릿") {
                        ForEach(library.templates, id: \.name) { doc in
                            tile(doc, title: "★ " + doc.name)
                                .contextMenu {
                                    Button(L("삭제"), role: .destructive) { library.delete(doc.name) }
                                    Button(L("Finder에서 보기")) { NSWorkspace.shared.open(TitleLibrary.folder) }
                                }
                        }
                    }
                    ForEach(TitleTemplate.allCases.filter { category == L("전체") || $0.category.rawValue == category }) { t in
                        tile(TitleDocument(template: t), title: t.label)
                    }
                }
                .padding(2)
            }
            .frame(minHeight: 260)
            HStack {
                Button(L("템플릿 파일 가져오기…")) {
                    let p = NSOpenPanel()
                    p.allowsMultipleSelection = true
                    p.allowedContentTypes = [.json, .data]
                    if p.runModal() == .OK { for u in p.urls { _ = library.importFile(u) } }
                }
                Button(L("템플릿 폴더 열기")) { NSWorkspace.shared.open(TitleLibrary.folder) }
                Spacer()
                Text(L("타이틀 편집에서 '내 템플릿으로 저장'한 디자인이 ★로 표시됩니다."))
                    .font(.caption).foregroundColor(.secondary)
            }
        }
    }

    private func tile(_ doc: TitleDocument, title: String) -> some View {
        let selected = selection.map { $0.template == doc.template && $0.name == doc.name } ?? false
        return Button {
            selection = doc
            onPick(doc)
        } label: {
            VStack(spacing: 4) {
                TitleThumb(doc: doc)
                    .aspectRatio(16.0 / 9.0, contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: 4))
                    .overlay(RoundedRectangle(cornerRadius: 4)
                        .stroke(selected ? Color.accentColor : Color.white.opacity(0.15), lineWidth: selected ? 3 : 1))
                Text(title).font(.system(size: 11, weight: selected ? .bold : .regular)).lineLimit(1)
            }
        }
        .buttonStyle(.plain)
    }
}

/// Cached thumbnail of a title document.
struct TitleThumb: View {
    let doc: TitleDocument
    private static var cache: [String: NSImage] = [:]
    private static let images = TitleImageCache()

    var body: some View {
        if let img = Self.image(doc) {
            Image(nsImage: img).resizable()
        } else {
            Color.black
        }
    }

    static func image(_ doc: TitleDocument) -> NSImage? {
        let key = doc.template.rawValue + "|" + doc.name + "|\(doc.fields.hashValueish)"
        if let c = cache[key] { return c }
        guard let cg = TitleRenderer.thumbnail(doc, images: images) else { return nil }
        let img = NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
        cache[key] = img
        return img
    }
}

private extension Array where Element == TitleField {
    /// Cheap content key so edited user templates get fresh thumbnails.
    var hashValueish: Int {
        var h = Hasher()
        for f in self { h.combine(f.id); h.combine(f.text); h.combine(f.color); h.combine(f.x); h.combine(f.y) }
        return h.finalize()
    }
}
