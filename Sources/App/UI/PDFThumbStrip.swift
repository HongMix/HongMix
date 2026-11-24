import SwiftUI
import PDFKit

/// Page thumbnails of a PDF (first pages) with Prev / Next for an existing PDF Slides input.
struct PDFThumbStrip: View {
    let path: String
    var deck: SlideDeckInput?
    @ViewState private var thumbs: [NSImage] = []
    @ViewState private var pageCount = 0
    @ViewState private var loadedPath = ""
    @ViewState private var converting = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(Array(thumbs.enumerated()), id: \.offset) { i, img in
                        Image(nsImage: img).resizable().aspectRatio(contentMode: .fit).frame(height: 54)
                            .overlay(RoundedRectangle(cornerRadius: 3)
                                .stroke(deck?.currentIndex == i ? Color.accentColor : Color.secondary.opacity(0.3),
                                        lineWidth: deck?.currentIndex == i ? 2 : 0.5))
                            .onTapGesture { deck?.select(i) }
                    }
                }
            }
            HStack {
                if let d = deck {
                    Button { d.previous() } label: { Label(L("이전"), systemImage: "chevron.left") }
                    Text(Lf("슬라이드 %@ / %@", "\(d.currentIndex + 1)", "\(d.count)")).monospacedDigit()
                    Button { d.next() } label: { Label(L("다음"), systemImage: "chevron.right") }
                } else if converting {
                    ProgressView().controlSize(.small)
                    Text(L("프레젠테이션을 PDF로 변환하는 중…")).foregroundColor(.secondary)
                } else if pageCount > 0 {
                    Text(Lf("%@쪽", "\(pageCount)")).foregroundColor(.secondary)
                } else {
                    Text(L("PDF를 열 수 없음")).foregroundColor(.orange)
                }
            }
        }
        .onAppear(perform: load)
        .onChange(of: path) { _, _ in load() }
    }

    private func load() {
        guard path != loadedPath else { return }
        loadedPath = path
        let p = path
        converting = SlideConverter.isDeck(p)
        DispatchQueue.global(qos: .userInitiated).async {
            // a PowerPoint / Keynote deck is converted here already (cached), so OK opens it at once
            let file = SlideConverter.isDeck(p) ? SlideConverter.pdf(for: p).0 : p
            let doc = file.flatMap { PDFDocument(url: URL(fileURLWithPath: $0)) }
            let n = doc?.pageCount ?? 0
            var imgs: [NSImage] = []
            for i in 0..<min(n, 40) {
                if let page = doc?.page(at: i) { imgs.append(page.thumbnail(of: NSSize(width: 120, height: 90), for: .mediaBox)) }
            }
            DispatchQueue.main.async {
                guard loadedPath == p else { return }
                converting = false
                pageCount = n
                thumbs = imgs
            }
        }
    }
}
