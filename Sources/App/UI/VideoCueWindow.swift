import SwiftUI
import AppKit
import UniformTypeIdentifiers
import QuickLookThumbnailing

/// Window "Video Cue": the cue list (drop files), GO / STOP / PANIC, what plays and what's next, and the
/// selected cue's settings. Space = GO and Esc = STOP while this window is in front.
struct VideoCueWindow: View {
    @EnvironmentObject var engine: SwitcherEngine
    @ObservedObject var cue = VideoCueEngine.shared
    @ViewState private var editing: Int? = nil

    private var input: InputSource? { engine.inputs.first { $0 is VideoCueInput } }

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            VStack(alignment: .leading, spacing: 12) {
                preview
                nowNext
                keys
                Spacer(minLength: 0)
            }
            .padding(14)
            .frame(width: 440)
            Divider()
            VStack(spacing: 0) {
                cueList
                if let i = editing, cue.list.cues.indices.contains(i) {
                    Divider()
                    CueInspector(c: $cue.list.cues[i], playing: cue.deckCue.contains(i),
                                 outputs: engine.inputs.filter { $0 is VideoCueInput }.map { ($0.id, $0.name) })
                }
            }
        }
        .frame(minWidth: 960, minHeight: 600)
        .background(AppLook.hardware ? Theme.window : Color(white: 0.08))
    }

    // MARK: Left: picture, now / next, keys

    @ViewBuilder private var preview: some View {
        if let input {
            MonitorView(fps: 30) { [weak input] in input?.monitorFrame() }
                .aspectRatio(16.0 / 9.0, contentMode: .fit)
                .overlay(RoundedRectangle(cornerRadius: 4).stroke(cue.live != nil ? Theme.live : Color.white.opacity(0.2), lineWidth: 1.5))
        } else {
            VStack(spacing: 8) {
                Text(L("스위처에 Video Cue 입력이 아직 없습니다.")).foregroundColor(.secondary)
                Button(L("Video Cue 입력 추가")) {
                    engine.addInput(InputConfig(kind: .videoCue, name: "Video Cue"))
                }
            }
            .frame(maxWidth: .infinity)
            .aspectRatio(16.0 / 9.0, contentMode: .fit)
            .background(Color.black)
        }
    }

    private func name(_ i: Int?) -> String {
        guard let i, cue.list.cues.indices.contains(i) else { return "—" }
        return "\(i + 1). \(cue.list.cues[i].displayName)"
    }

    private var nowNext: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(L("재생 중")).textCase(.uppercase).font(.system(size: 10, weight: .bold)).foregroundColor(.secondary).frame(width: 64, alignment: .leading)
                Text(name(cue.live.flatMap { cue.deckCue[$0] })).font(.system(size: 15, weight: .semibold)).lineLimit(1)
            }
            // only this text redraws 10×/s
            TimelineView(.periodic(from: .now, by: 0.1)) { _ in
                Text(cue.remaining.map { "−" + Self.clock($0) } ?? Self.clock(0))
                    .font(.system(size: 54, weight: .bold, design: .monospaced))
                    .foregroundColor(cue.remaining.map { $0 < 10 ? Theme.live : .white } ?? Color.white.opacity(0.18))
            }
            HStack(alignment: .firstTextBaseline) {
                Text(L("다음")).textCase(.uppercase).font(.system(size: 10, weight: .bold)).foregroundColor(.secondary).frame(width: 64, alignment: .leading)
                Text(name(cue.selected)).font(.system(size: 15, weight: .semibold)).foregroundColor(Theme.preview).lineLimit(1)
            }
        }
    }

    /// Space/Esc pressed while typing in a field (the inspector's name, a number) belong to the field, not the show.
    private func typingField() -> NSTextView? {
        guard NSApp.currentEvent?.type == .keyDown,
              let field = NSApp.keyWindow?.firstResponder as? NSTextView, field.isFieldEditor else { return nil }
        return field
    }

    private var keys: some View {
        VStack(spacing: 8) {
            Button {
                if let field = typingField() { field.insertText(" ", replacementRange: field.selectedRange()); return }
                cue.go()
            } label: {
                Text("GO").font(.system(size: 34, weight: .heavy)).foregroundColor(.white)
                    .frame(maxWidth: .infinity, minHeight: 84)
                    .replayKey(Color(red: 0.16, green: 0.55, blue: 0.25), radius: 8)
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.space, modifiers: [])
            .disabled(!cue.list.cues.indices.contains(cue.selected))
            .help(L("다음 큐 시작 (스페이스)"))
            HStack(spacing: 8) {
                key("◀", help: L("이전 큐 선택")) { cue.previous() }
                key("STOP", help: L("현재 큐를 페이드아웃 (Esc)")) {
                    if let field = typingField() { field.window?.makeFirstResponder(nil); return }   // Esc ends the typing
                    cue.stop()
                }
                    .keyboardShortcut(.cancelAction)
                key("▶", help: L("다음 큐 선택")) { cue.next() }
            }
            key("PANIC", fill: Theme.live, help: L("모두 즉시 검은 화면 · 무음")) { cue.panic() }
        }
    }

    private func key(_ title: String, fill: Color = ReplayKey.neutral, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title).font(.system(size: 14, weight: .bold)).foregroundColor(.white)
                .frame(maxWidth: .infinity, minHeight: 36)
                .replayKey(fill, radius: 6)
        }
        .buttonStyle(.plain)
        .help(help)
    }

    static func clock(_ s: Double) -> String {
        let t = max(0, s)
        return String(format: "%d:%02d.%d", Int(t) / 60, Int(t) % 60, Int((t * 10).truncatingRemainder(dividingBy: 10)))
    }

    // MARK: Right: the cue list

    private var cueList: some View {
        VStack(spacing: 0) {
            HStack {
                Text(L("큐 목록")).font(.system(size: 11, weight: .bold)).foregroundColor(.secondary)
                Spacer()
                BackgroundButton(background: $cue.list.background)
                Button(L("파일 추가…")) { addFiles() }
            }
            .padding(10)
            ScrollView {
                LazyVStack(spacing: 2) {
                    ForEach(Array(cue.list.cues.enumerated()), id: \.element.id) { i, c in row(i, c) }
                    if cue.list.cues.isEmpty {
                        Text(L("영상, 이미지, 오디오 파일을 여기로 끌어다 놓으세요."))
                            .foregroundColor(.secondary).padding(30)
                    }
                }
                .padding(.horizontal, 8)
            }
            .onDrop(of: [.fileURL], isTargeted: nil) { providers in
                for p in providers {
                    _ = p.loadObject(ofClass: URL.self) { url, _ in
                        if let url { DispatchQueue.main.async { cue.add(paths: [url.path]) } }
                    }
                }
                return true
            }
        }
    }

    private func row(_ i: Int, _ c: VideoCue) -> some View {
        let live = cue.live.flatMap { cue.deckCue[$0] } == i
        let next = cue.selected == i
        return HStack(spacing: 8) {
            Text("\(i + 1)").font(.system(size: 12, weight: .bold).monospacedDigit()).frame(width: 26, alignment: .trailing)
            Button { cue.select(i); cue.go() } label: {
                Image(systemName: "play.fill").font(.system(size: 11)).foregroundColor(live ? .white : Theme.preview)
                    .frame(width: 26, height: 22).replayKey(ReplayKey.neutral, radius: 4)
            }
            .buttonStyle(.plain)
            .help(L("이 큐 바로 시작"))
            Button { cue.list.cues[i].endAction = c.endAction == .loop ? .hold : .loop } label: {
                Image(systemName: "repeat").font(.system(size: 11, weight: .bold))
                    .foregroundColor(c.endAction == .loop ? .white : .secondary)
                    .frame(width: 26, height: 22)
                    .replayKey(c.endAction == .loop ? Theme.accent : ReplayKey.neutral, radius: 4)
            }
            .buttonStyle(.plain)
            .help(L("이 큐 반복 재생 (끄면 마지막 화면 유지)"))
            CueThumb(path: c.path, symbol: c.kind == .video ? "film" : c.kind == .still ? "photo" : "music.note")
            Text(c.displayName).lineLimit(1).frame(maxWidth: .infinity, alignment: .leading)
            if c.fadeIn > 0 || c.fadeOut > 0 {
                Text(String(format: "↗%.1f ↘%.1f", c.fadeIn, c.fadeOut)).font(.caption.monospacedDigit()).foregroundColor(.secondary)
            }
            Text(c.endAction.label).font(.caption).foregroundColor(.secondary).frame(width: 110, alignment: .trailing)
        }
        .padding(.horizontal, 8).padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: 4).fill(live ? Theme.live.opacity(0.35) : editing == i ? Color.white.opacity(0.10) : Color.white.opacity(0.03)))
        .overlay(RoundedRectangle(cornerRadius: 4).stroke(next ? Theme.preview : .clear, lineWidth: 1.5))
        .contentShape(Rectangle())
        .onTapGesture { editing = i; cue.select(i) }
        .contextMenu {
            Button(L("삭제")) {
                if editing == i { editing = nil } else if let e = editing, e > i { editing = e - 1 }
                cue.remove(at: i)
            }.disabled(cue.deckCue != [nil, nil])
        }
    }

    private func addFiles() {
        let p = NSOpenPanel()
        p.allowsMultipleSelection = true
        p.allowedContentTypes = [.movie, .image, .audio]
        if p.runModal() == .OK { cue.add(paths: p.urls.map(\.path)) }
    }
}

extension VideoCue.EndAction {
    var label: String {
        switch self {
        case .hold: return L("마지막 화면 유지")
        case .black: return L("검은 화면으로")
        case .loop: return L("반복")
        case .next: return L("다음 큐 자동 시작")
        }
    }
}

/// Settings of one cue (changes apply from its next GO).
private struct CueInspector: View {
    @Binding var c: VideoCue
    let playing: Bool
    let outputs: [(id: UUID, name: String)]

    var body: some View {
        Form {
            TextField(L("이름"), text: $c.name, prompt: Text(c.displayName))
            if c.kind == .still {
                DecimalField(L("표시 시간 (0 = 다음 GO까지)"), value: $c.stillSeconds, in: 0...3600, unit: L("초"), step: 1, digits: 1)
            } else {
                DecimalField(L("시작 지점"), value: $c.inPoint, in: 0...86400, unit: L("초"), step: 1, digits: 1)
                DecimalField(L("끝 지점 (0 = 파일 끝)"), value: $c.outPoint, in: 0...86400, unit: L("초"), step: 1, digits: 1)
            }
            DecimalField(L("페이드 인"), value: $c.fadeIn, in: 0...30, unit: L("초"), step: 0.5, digits: 1)
            DecimalField(L("페이드 아웃"), value: $c.fadeOut, in: 0...30, unit: L("초"), step: 0.5, digits: 1)
            Picker(L("끝나면"), selection: $c.endAction) {
                ForEach(VideoCue.EndAction.allCases, id: \.self) { Text($0.label).tag($0) }
            }
            if playing {
                Text(L("재생 중인 큐의 변경은 다음 GO부터 적용됩니다.")).font(.caption).foregroundColor(.secondary)
            }
            if c.kind != .audio {
                Section(L("화면")) {
                    Picker(L("화면 맞춤"), selection: $c.fit) {
                        Text(L("맞추기")).tag(VideoCue.Fit.fit)
                        Text(L("꽉 채우기 (잘림)")).tag(VideoCue.Fit.fill)
                        Text(L("늘리기")).tag(VideoCue.Fit.stretch)
                    }
                    .pickerStyle(.segmented)
                    DecimalField(L("줌"), value: $c.zoom, in: 0.1...5, step: 0.05, digits: 2)
                    DecimalField(L("가로 이동 (Pan X)"), value: $c.panX, in: -2...2, step: 0.01, digits: 2)
                    DecimalField(L("세로 이동 (Pan Y)"), value: $c.panY, in: -2...2, step: 0.01, digits: 2)
                }
                Section(L("크롭 (가장자리에서 잘라낼 비율)")) {
                    DecimalField(L("왼쪽"), value: percent(\.cropL), in: 0...90, unit: "%", step: 1)
                    DecimalField(L("오른쪽"), value: percent(\.cropR), in: 0...90, unit: "%", step: 1)
                    DecimalField(L("위"), value: percent(\.cropT), in: 0...90, unit: "%", step: 1)
                    DecimalField(L("아래"), value: percent(\.cropB), in: 0...90, unit: "%", step: 1)
                }
            }
            if outputs.count > 1 {
                Section(L("이 큐를 보여줄 출력")) {
                    ForEach(outputs, id: \.id) { o in
                        Toggle(o.name, isOn: Binding(get: { c.shows(on: o.id) },
                                                     set: { on in c.hiddenOn.removeAll { $0 == o.id }; if !on { c.hiddenOn.append(o.id) } }))
                    }
                }
            }
        }
        .formStyle(.grouped)
        .frame(height: 360)
    }

    private func percent(_ k: WritableKeyPath<VideoCue, Double>) -> Binding<Double> {
        Binding(get: { c[keyPath: k] * 100 }, set: { c[keyPath: k] = $0 / 100 })
    }
}

/// The list's fallback picture (what shows when no cue does): none (black), a colour, a still or a looping video.
private struct BackgroundButton: View {
    @Binding var background: CueBackground?
    @ViewState private var open = false

    var body: some View {
        Button { open.toggle() } label: {
            Label(L("배경"), systemImage: background == nil ? "rectangle" : "rectangle.inset.filled")
        }
        .help(L("큐가 없을 때 보이는 화면: 색, 이미지 또는 반복 영상"))
        .popover(isPresented: $open, arrowEdge: .bottom) {
            Form {
                Picker(L("배경"), selection: Binding(get: { background?.kind }, set: { k in
                    guard let k else { background = nil; return }
                    var b = background ?? CueBackground(); b.kind = k; background = b
                })) {
                    Text(L("배경 없음 (검은 화면)")).tag(CueBackground.Kind?.none)
                    Text(L("색")).tag(CueBackground.Kind?.some(.color))
                    Text(L("이미지")).tag(CueBackground.Kind?.some(.image))
                    Text(L("비디오")).tag(CueBackground.Kind?.some(.video))
                }
                if let b = background {
                    if b.kind == .color {
                        ColorPicker(L("색"), selection: Binding(get: { Self.color(b.color) }, set: { background?.color = Self.hex($0) }),
                                    supportsOpacity: false)
                    } else {
                        HStack {
                            Text(b.path.isEmpty ? "—" : (b.path as NSString).lastPathComponent).lineLimit(1).truncationMode(.middle)
                            Spacer()
                            Button(L("파일 선택…")) { choose(b.kind) }
                        }
                    }
                }
            }
            .formStyle(.grouped)
            .frame(width: 340)
        }
    }

    /// "#RRGGBB" ↔ Color (the background deck is a ColorInput, which reads that spec).
    static func color(_ hex: String) -> Color {
        let v = UInt32(hex.dropFirst(), radix: 16) ?? 0
        return Color(red: Double(v >> 16 & 0xFF) / 255, green: Double(v >> 8 & 0xFF) / 255, blue: Double(v & 0xFF) / 255)
    }

    static func hex(_ color: Color) -> String {
        guard let c = NSColor(color).usingColorSpace(.sRGB) else { return "#000000" }
        return String(format: "#%02X%02X%02X", Int(c.redComponent * 255 + 0.5), Int(c.greenComponent * 255 + 0.5), Int(c.blueComponent * 255 + 0.5))
    }

    private func choose(_ kind: CueBackground.Kind) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = kind == .image ? [.image] : [.movie]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        background?.path = url.path
    }
}

/// Small pictures for the cue list: made once per file by Quick Look (off the main thread), then kept in memory,
/// so the list costs nothing while the show runs.
final class CueThumbs: ObservableObject {
    static let shared = CueThumbs()
    @Published private(set) var images: [String: NSImage] = [:]
    private var asked = Set<String>()

    func image(_ path: String) -> NSImage? {
        if images[path] == nil, asked.insert(path).inserted {
            let request = QLThumbnailGenerator.Request(fileAt: URL(fileURLWithPath: path), size: CGSize(width: 64, height: 36),
                                                       scale: 2, representationTypes: .thumbnail)
            QLThumbnailGenerator.shared.generateBestRepresentation(for: request) { rep, _ in
                guard let img = rep?.nsImage else { return }       // no picture (most audio): the row keeps its symbol
                DispatchQueue.main.async { self.images[path] = img }
            }
        }
        return images[path]
    }
}

/// A cue's thumbnail in the list, or its kind's symbol until (or unless) there is one.
private struct CueThumb: View {
    let path: String
    let symbol: String
    @ObservedObject private var thumbs = CueThumbs.shared

    var body: some View {
        ZStack {
            Color.black
            if let img = thumbs.image(path) {
                Image(nsImage: img).resizable().aspectRatio(contentMode: .fit)
            } else {
                Image(systemName: symbol).foregroundColor(.secondary)
            }
        }
        .frame(width: 64, height: 36)
        .clipShape(RoundedRectangle(cornerRadius: 2))
    }
}
