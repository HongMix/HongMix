import Foundation
import CoreGraphics
import CoreText
import AppKit

/// Look of the live captions (Tools › Captions › Caption look). Sizes are pixels on a 1080-line frame.
/// Presets follow the broadcast layouts used for Korean parliamentary hearings: right column (4 lines),
/// bottom "cinema" (2 lines), bottom band (3 lines). The video is never resized.
struct CaptionStyle: Codable, Equatable {
    var preset = "bottom"            // right | bottom | band | custom
    var left = 8.0, top = 72.0, width = 84.0, height = 25.0     // % of the frame
    var lines = 2
    var lineChars = 31               // Hangul characters per line (Latin counts half)
    var fontSize = 38.0              // px @1080
    var letterSpacing = 0.0          // px @1080
    var lineHeight = 135.0           // % of font size
    var rowGap = 6.0                 // px @1080 between lines
    var scaleX = 100.0               // % glyph width
    var align = "center"             // left | center
    var background = "line"          // line | box | band | none
    var bgOpacity = 76.0
    var bgColor = "#000000"
    var textColor = "#FFFFFF"
    var outline = false
    var labelShow = true
    var labelText = L("AI 자막")
    var labelSize = 22.0
    var labelPos = "rows"            // rows (just above the captions) | box (top-left of the area) | custom
    var labelX = 8.0, labelY = 68.0  // % (custom)
    var animationMs = 420.0
    var showDraft = true
    var fontName = "Apple SD Gothic Neo"
    var translationOnly = false

    init() {}
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = CaptionStyle()
        preset = c.value(.preset, d.preset)
        left = c.value(.left, d.left); top = c.value(.top, d.top)
        width = c.value(.width, d.width); height = c.value(.height, d.height)
        lines = c.value(.lines, d.lines); lineChars = c.value(.lineChars, d.lineChars)
        fontSize = c.value(.fontSize, d.fontSize); letterSpacing = c.value(.letterSpacing, d.letterSpacing)
        lineHeight = c.value(.lineHeight, d.lineHeight); rowGap = c.value(.rowGap, d.rowGap)
        scaleX = c.value(.scaleX, d.scaleX); align = c.value(.align, d.align)
        background = c.value(.background, d.background); bgOpacity = c.value(.bgOpacity, d.bgOpacity)
        bgColor = c.value(.bgColor, d.bgColor); textColor = c.value(.textColor, d.textColor)
        outline = c.value(.outline, d.outline)
        labelShow = c.value(.labelShow, d.labelShow); labelText = c.value(.labelText, d.labelText)
        labelSize = c.value(.labelSize, d.labelSize)
        labelPos = c.value(.labelPos, d.labelPos)
        labelX = c.value(.labelX, d.labelX); labelY = c.value(.labelY, d.labelY)
        animationMs = c.value(.animationMs, d.animationMs); showDraft = c.value(.showDraft, d.showDraft)
        fontName = c.value(.fontName, d.fontName); translationOnly = c.value(.translationOnly, d.translationOnly)
    }

    /// Line width in display units (Hangul / CJK = 2, Latin = 1).
    var lineUnits: Int { max(8, lineChars * 2) }

    /// Layout presets (geometry, lines, size). Colours, font, letter spacing stay as the operator set them.
    func applying(preset key: String) -> CaptionStyle {
        var s = self
        s.preset = key
        switch key {
        case "right":
            (s.left, s.top, s.width, s.height) = (64, 18, 32, 70)
            (s.lines, s.lineChars, s.fontSize, s.rowGap, s.lineHeight) = (4, 14, 31, 4, 132)
            (s.background, s.bgOpacity, s.labelSize, s.align) = ("line", 78, 23, "left")
        case "band":
            (s.left, s.top, s.width, s.height) = (5, 78, 90, 21)
            (s.lines, s.lineChars, s.fontSize, s.rowGap, s.lineHeight) = (3, 34, 37, 5, 135)
            (s.background, s.bgOpacity, s.labelSize, s.align) = ("band", 82, 22, "center")
        case "bottom":
            (s.left, s.top, s.width, s.height) = (8, 72, 84, 25)
            (s.lines, s.lineChars, s.fontSize, s.rowGap, s.lineHeight) = (2, 31, 38, 6, 135)
            (s.background, s.bgOpacity, s.labelSize, s.align) = ("line", 76, 22, "center")
        default: break
        }
        return s
    }

    static func charUnits(_ u: Unicode.Scalar) -> Int {
        switch u.value {
        case 0x1100...0x11FF, 0x2E80...0xA4CF, 0xAC00...0xD7A3, 0xF900...0xFAFF, 0xFE30...0xFE4F,
             0xFF00...0xFF60, 0xFFE0...0xFFE6: return 2
        default: return 1
        }
    }
    static func units(_ s: String) -> Int { s.unicodeScalars.reduce(0) { $0 + charUnits($1) } }

    /// Word wrap by display width; words longer than a line are split by character.
    static func wrap(_ text: String, units limit: Int) -> [String] {
        let words = text.split(whereSeparator: { $0 == " " || $0 == "\n" }).map(String.init)
        var out: [String] = []
        var line = ""
        for w in words {
            let cand = line.isEmpty ? w : line + " " + w
            if units(cand) <= limit { line = cand; continue }
            if !line.isEmpty { out.append(line); line = "" }
            for ch in w {
                if !line.isEmpty && units(line + String(ch)) > limit { out.append(line); line = "" }
                line.append(ch)
            }
        }
        if !line.isEmpty { out.append(line) }
        return out
    }

    /// Korean-capable fonts installed on this Mac (picker in the caption settings).
    static var fontChoices: [String] {
        let wanted = ["Apple SD Gothic Neo", "Pretendard", "Noto Sans KR", "Noto Sans CJK KR", "Nanum Gothic",
                      "NanumSquare", "NanumBarunGothic", "Spoqa Han Sans Neo", "Helvetica Neue"]
        let have = Set(NSFontManager.shared.availableFontFamilies)
        return wanted.filter { have.contains($0) }
    }
}

struct CaptionRow: Equatable {
    enum Kind { case final, draft, translation }
    var id: Int
    var text: String
    var kind: Kind = .final
}

struct CaptionFrame: Equatable {
    var rows: [CaptionRow]
    var style: CaptionStyle
}

/// Lays out and draws caption rows (top-left origin, y down — the title renderer's flipped context).
enum CaptionRenderer {
    struct Placed { var row: CaptionRow; var rect: CGRect; var textSize: CGSize }

    private static func font(_ st: CaptionStyle, size: CGFloat) -> CTFont {
        let base = CTFontCreateWithName(st.fontName as CFString, size, nil)
        return CTFontCreateCopyWithSymbolicTraits(base, size, nil, .boldTrait, .boldTrait) ?? base
    }

    private static func color(_ hex: String, alpha: Double = 1) -> CGColor {
        HexColor.cgColor(hex).copy(alpha: CGFloat(max(0, min(1, alpha)))) ?? HexColor.cgColor(hex)
    }

    static func attributed(_ row: CaptionRow, _ st: CaptionStyle, k: CGFloat, stroke: Bool = false) -> NSAttributedString {
        let size = CGFloat(st.fontSize) * k
        var align = st.align == "center" ? CTTextAlignment.center : .left
        let lh = size * CGFloat(st.lineHeight) / 100
        var minH = lh, maxH = lh
        let ps: CTParagraphStyle = withUnsafeBytes(of: &align) { a in
            withUnsafeBytes(of: &minH) { mn in
                withUnsafeBytes(of: &maxH) { mx in
                    let settings = [
                        CTParagraphStyleSetting(spec: .alignment, valueSize: MemoryLayout<CTTextAlignment>.size, value: a.baseAddress!),
                        CTParagraphStyleSetting(spec: .minimumLineHeight, valueSize: MemoryLayout<CGFloat>.size, value: mn.baseAddress!),
                        CTParagraphStyleSetting(spec: .maximumLineHeight, valueSize: MemoryLayout<CGFloat>.size, value: mx.baseAddress!),
                    ]
                    return CTParagraphStyleCreate(settings, settings.count)
                }
            }
        }
        let fg: CGColor
        switch row.kind {
        case .draft: fg = HexColor.cgColor("#BCE4FF")
        case .translation: fg = HexColor.cgColor("#FFD966")
        case .final: fg = HexColor.cgColor(st.textColor)
        }
        var attrs: [NSAttributedString.Key: Any] = [
            NSAttributedString.Key(kCTFontAttributeName as String): font(st, size: size),
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): fg,
            NSAttributedString.Key(kCTKernAttributeName as String): CGFloat(st.letterSpacing) * k,
            NSAttributedString.Key(kCTParagraphStyleAttributeName as String): ps,
        ]
        if stroke {
            attrs[NSAttributedString.Key(kCTStrokeColorAttributeName as String)] = CGColor(gray: 0, alpha: 1)
            attrs[NSAttributedString.Key(kCTStrokeWidthAttributeName as String)] = 14.0
        }
        return NSAttributedString(string: row.text, attributes: attrs)
    }

    static func box(_ st: CaptionStyle, W: CGFloat, H: CGFloat) -> CGRect {
        CGRect(x: W * CGFloat(st.left) / 100, y: H * CGFloat(st.top) / 100,
               width: W * CGFloat(st.width) / 100, height: H * CGFloat(min(st.height, 100 - st.top)) / 100)
    }

    static func labelHeight(_ st: CaptionStyle, k: CGFloat) -> CGFloat {
        st.labelShow && !st.labelText.isEmpty ? CGFloat(st.labelSize) * k * 1.25 + 14 * k : 0
    }
    /// Space the label takes at the top of the caption area (none when it is placed freely).
    static func labelReserve(_ st: CaptionStyle, k: CGFloat) -> CGFloat {
        st.labelPos == "custom" ? 0 : labelHeight(st, k: k)
    }

    /// Rows stacked from the bottom of the box upward (newest at the bottom). Rows that don't fit are dropped.
    static func layout(_ f: CaptionFrame, W: CGFloat, H: CGFloat) -> [Placed] {
        let st = f.style
        let k = H / 1080
        let b = box(st, W: W, H: H)
        let padX = 9 * k, padY = 4 * k, gap = CGFloat(st.rowGap) * k
        let sx = CGFloat(max(50, st.scaleX)) / 100
        let avail = max(20, (b.width - 2 * padX) / sx)
        let topLimit = b.minY + labelReserve(st, k: k) + 5 * k
        var y = b.maxY
        var out: [Placed] = []
        for row in f.rows.reversed() {
            let fs = CTFramesetterCreateWithAttributedString(attributed(row, st, k: k))
            var sz = CTFramesetterSuggestFrameSizeWithConstraints(fs, CFRange(location: 0, length: 0), nil,
                                                                  CGSize(width: avail, height: .greatestFiniteMagnitude), nil)
            sz.width = min(avail, ceil(sz.width) + 2)
            sz.height = ceil(sz.height)
            let rowW = sz.width * sx + 2 * padX, rowH = sz.height + 2 * padY
            if y - rowH < topLimit - 0.5 { break }
            let x = st.align == "center" ? b.midX - rowW / 2 : b.minX
            out.append(Placed(row: row, rect: CGRect(x: x, y: y - rowH, width: rowW, height: rowH), textSize: sz))
            y -= rowH + gap
        }
        return out.reversed()
    }

    /// Background behind all rows (box / band modes) and the "AI 자막" label.
    /// `firstRow`: the top caption row (the label sits just above it in "rows" mode).
    static func drawChrome(_ st: CaptionStyle, rowsVisible: Bool, firstRow: CGRect? = nil, in cg: CGContext, W: CGFloat, H: CGFloat) {
        guard rowsVisible else { return }
        let k = H / 1080
        let b = box(st, W: W, H: H)
        let bg = color(st.bgColor, alpha: st.bgOpacity / 100)
        if st.background == "box" {
            cg.setFillColor(bg)
            cg.addPath(CGPath(roundedRect: b, cornerWidth: 8 * k, cornerHeight: 8 * k, transform: nil))
            cg.fillPath()
        } else if st.background == "band" {
            cg.setFillColor(bg)
            cg.fill(CGRect(x: 0, y: b.minY - H * 0.006, width: W, height: H - b.minY + H * 0.006))
        }
        if st.labelShow, !st.labelText.isEmpty {
            let size = CGFloat(st.labelSize) * k
            let lf = font(st, size: size)
            let line = CTLineCreateWithAttributedString(NSAttributedString(string: st.labelText, attributes: [
                NSAttributedString.Key(kCTFontAttributeName as String): lf,
                NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(gray: 1, alpha: 1)]))
            let tw = CTLineGetBoundsWithOptions(line, .useOpticalBounds).width
            let lw = tw + 30 * k, lh = labelHeight(st, k: k) - 5 * k
            var r = CGRect(x: b.minX, y: b.minY, width: lw, height: lh)
            switch st.labelPos {
            case "custom":
                r.origin = CGPoint(x: W * CGFloat(st.labelX) / 100, y: H * CGFloat(st.labelY) / 100)
            case "box":
                break
            default:   // rows: just above the top caption line, at its left edge
                if let f = firstRow { r.origin = CGPoint(x: f.minX, y: f.minY - lh - 4 * k) }
            }
            cg.setFillColor(color("#1E5AA8", alpha: 0.86))
            cg.addPath(CGPath(roundedRect: r, cornerWidth: 5 * k, cornerHeight: 5 * k, transform: nil))
            cg.fillPath()
            cg.saveGState()
            cg.translateBy(x: r.minX + 15 * k, y: r.midY + CTFontGetAscent(lf) * 0.36)
            cg.scaleBy(x: 1, y: -1)
            cg.textPosition = .zero
            CTLineDraw(line, cg)
            cg.restoreGState()
        }
    }

    /// One row at `rect` (its final size), drawn with `alpha`.
    static func drawRow(_ p: Placed, st: CaptionStyle, rect: CGRect, alpha: CGFloat, in cg: CGContext, H: CGFloat) {
        let k = H / 1080
        let padX = 9 * k, padY = 4 * k
        let sx = CGFloat(max(50, st.scaleX)) / 100
        cg.saveGState()
        cg.setAlpha(alpha)
        if st.background == "line" {
            cg.setFillColor(color(st.bgColor, alpha: st.bgOpacity / 100))
            cg.addPath(CGPath(roundedRect: rect, cornerWidth: 3 * k, cornerHeight: 3 * k, transform: nil))
            cg.fillPath()
        }
        if p.row.kind == .draft {
            cg.setFillColor(HexColor.cgColor("#62BCFF"))
            cg.fill(CGRect(x: rect.minX, y: rect.minY, width: 3 * k, height: rect.height))
        }
        // text: CTFrame in a local unflipped space, scaled horizontally
        let textRect = CGRect(x: 0, y: 0, width: p.textSize.width, height: p.textSize.height)
        cg.translateBy(x: rect.minX + padX, y: rect.minY + padY + p.textSize.height)
        cg.scaleBy(x: sx, y: -1)
        if st.background == "none" || st.outline {
            cg.setShadow(offset: CGSize(width: 0, height: -2 * k), blur: 6 * k, color: CGColor(gray: 0, alpha: 0.85))
        }
        if st.outline {
            let fs = CTFramesetterCreateWithAttributedString(attributed(p.row, st, k: k, stroke: true))
            CTFrameDraw(CTFramesetterCreateFrame(fs, CFRange(), CGPath(rect: textRect, transform: nil), nil), cg)
            cg.setShadow(offset: .zero, blur: 0, color: nil)
        }
        let fs = CTFramesetterCreateWithAttributedString(attributed(p.row, st, k: k))
        CTFrameDraw(CTFramesetterCreateFrame(fs, CFRange(), CGPath(rect: textRect, transform: nil), nil), cg)
        cg.restoreGState()
    }
}
