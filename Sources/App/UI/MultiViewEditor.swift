import SwiftUI
import AppKit

extension SwitcherEngine {
    /// Output source for MultiView k (the first stays `.multiview`, so old sessions and the API keep working).
    func multiViewSource(_ k: Int) -> BusSource { k == 0 ? .multiview : .multiviewID(multiViews[k].id) }
    var multiViewSources: [BusSource] { multiViews.indices.map(multiViewSource) }

    /// Display name of a MultiView source (nil for other sources).
    func multiViewName(_ src: BusSource) -> String? {
        switch src {
        case .multiview: return multiViews.first?.name
        case .multiviewID(let id): return (multiViews.first { $0.id == id } ?? multiViews.first)?.name
        default: return nil
        }
    }
}

/// Window "MultiView": make several MultiViews, pick a layout and what each cell shows,
/// and send one straight to a monitor.
struct MultiViewEditor: View {
    @EnvironmentObject var engine: SwitcherEngine
    @ObservedObject var map = DisplayMap.shared
    @ViewState private var selected: UUID? = nil

    private var index: Int {
        if let s = selected, let k = engine.multiViews.firstIndex(where: { $0.id == s }) { return k }
        return 0
    }

    var body: some View {
        HStack(spacing: 0) {
            sidebar.frame(width: 210)
            Divider()
            editor(index).frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(minWidth: 860, minHeight: 600)
    }

    // MARK: Sidebar

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            List(selection: Binding<UUID?>(get: { engine.multiViews[index].id }, set: { selected = $0 })) {
                ForEach(Array(engine.multiViews.enumerated()), id: \.element.id) { k, mv in
                    HStack(spacing: 8) {
                        LayoutThumb(layout: mv.layout).frame(width: 32, height: 18)
                        Text(mv.name).lineLimit(1)
                    }
                    .tag(mv.id)
                    .contextMenu {
                        Button(L("복제")) { duplicate(k) }
                        Button(L("삭제"), role: .destructive) { delete(k) }.disabled(!canDelete(k))
                    }
                }
            }
            Divider()
            HStack(spacing: 4) {
                Button { add() } label: { Image(systemName: "plus") }
                    .help(L("새 MultiView"))
                Button { duplicate(index) } label: { Image(systemName: "plus.square.on.square") }
                    .help(L("복제"))
                Button { delete(index) } label: { Image(systemName: "minus") }
                    .disabled(!canDelete(index))
                    .help(index == 0 ? L("첫 번째 MultiView는 삭제할 수 없습니다")
                          : (canDelete(index) ? L("삭제") : L("출력에서 사용 중 — 먼저 출력의 소스를 바꾸세요")))
                Spacer()
            }
            .buttonStyle(.borderless)
            .padding(8)
        }
    }

    private func add() {
        let mv = MultiViewConfig(name: "MultiView \(engine.multiViews.count + 1)")
        engine.multiViews.append(mv)
        selected = mv.id
    }

    private func duplicate(_ k: Int) {
        var mv = engine.multiViews[k]
        mv.id = UUID()
        mv.name += " " + L("복사본")
        engine.multiViews.insert(mv, at: k + 1)
        selected = mv.id
    }

    /// The first one is the plain `.multiview` source; one that an output shows can't go (it would switch
    /// that output to another MultiView without warning).
    private func canDelete(_ k: Int) -> Bool {
        guard k > 0, engine.multiViews.indices.contains(k) else { return false }
        let src = engine.multiViewSource(k)
        let fs = FullscreenOutput.shared
        return !engine.busSources.contains(src)
            && !(fs.isShowing && fs.source == src)
            && !map.assignments.values.contains { $0.on && $0.source == src }
    }

    private func delete(_ k: Int) {
        guard canDelete(k) else { return }
        engine.multiViews.remove(at: k)
        selected = engine.multiViews[min(k, engine.multiViews.count - 1)].id
    }

    // MARK: Editor

    private func binding(_ k: Int) -> Binding<MultiViewConfig> {
        Binding(get: { engine.multiViews.indices.contains(k) ? engine.multiViews[k] : .standard() },
                set: { if engine.multiViews.indices.contains(k) { engine.multiViews[k] = $0 } })
    }

    @ViewBuilder private func editor(_ k: Int) -> some View {
        let mv = binding(k)
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                TextField(L("이름"), text: mv.name)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 260)
                Toggle(L("이름 표시"), isOn: mv.showLabels)
                Toggle(L("탈리 테두리 (빨강 = 방송 · 초록 = 미리보기)"), isOn: mv.showTally)
                Spacer()
            }

            VStack(alignment: .leading, spacing: 6) {
                Text(L("기본 레이아웃")).font(.system(size: 11, weight: .bold)).foregroundColor(.secondary)
                HStack(spacing: 8) {
                    ForEach(MultiViewLayoutKind.allCases) { l in
                        Button { mv.wrappedValue.setLayout(l) } label: {
                            VStack(spacing: 4) {
                                LayoutThumb(layout: l, highlight: mv.wrappedValue.layout == l)
                                    .frame(width: 72, height: 40.5)
                                Text(l.title).font(.system(size: 9)).lineLimit(2).multilineTextAlignment(.center)
                                    .frame(width: 84, height: 24, alignment: .top)
                            }
                        }
                        .buttonStyle(.plain)
                        .help(l.title)
                    }
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text(L("칸마다 보여줄 화면 (칸을 클릭해서 선택)")).font(.system(size: 11, weight: .bold)).foregroundColor(.secondary)
                    Spacer()
                    Button(L("기본값으로")) {
                        var v = mv.wrappedValue
                        v.slots = []
                        mv.wrappedValue = v
                    }
                    .help(L("Preview · Output을 큰 칸에, 나머지 칸은 입력 순서대로"))
                }
                CellCanvas(config: mv)
                    .aspectRatio(16.0 / 9.0, contentMode: .fit)
                    .frame(maxWidth: .infinity)
            }

            HStack(spacing: 10) {
                Text(L("화면에 보내기")).font(.system(size: 11, weight: .bold)).foregroundColor(.secondary)
                let src = engine.multiViewSource(k)
                // like Display ⚙ › Monitor outputs: not the switcher's screen, not the one the display output uses
                let fs = FullscreenOutput.shared
                let screens = NSScreen.screens.enumerated().filter {
                    $0.element != FullscreenOutput.switcherWindow?.screen && !(fs.isShowing && $0.element == fs.currentScreen)
                }
                if screens.isEmpty {
                    Text(L("스위처 외에 연결된 모니터가 없습니다")).font(.caption).foregroundColor(.secondary)
                }
                ForEach(screens, id: \.offset) { (n, s) in
                    let on = map.assignment(for: s).map { $0.on && $0.source == src } ?? false
                    Button {
                        map.set(source: on ? nil : src, for: s)
                    } label: {
                        Label("\(n + 1): \(s.localizedName)", systemImage: on ? "checkmark.rectangle.fill" : "rectangle")
                    }
                    .help(on ? L("이 모니터에서 끄기") : L("이 MultiView를 이 모니터에 전체화면으로"))
                }
                Spacer()
            }
            if engine.multiViewDivider > 1 {
                Label(Lf("렌더 부하 때문에 MultiView가 %@ fps로 돌고 있습니다 — 라이브 출력은 전체 프레임 유지",
                         String(format: "%.0f", engine.format.fps / Double(engine.multiViewDivider))),
                      systemImage: "speedometer")
                    .font(.caption).foregroundColor(.orange)
            }
            Text(L("Output 2–4(외부 출력 · NDI · 녹화)와 디스플레이 출력 ⚙에서도 이 MultiView를 고를 수 있습니다."))
                .font(.caption).foregroundColor(.secondary)
        }
        .padding(16)
    }
}

/// Small schematic of a layout (large cells tinted).
struct LayoutThumb: View {
    let layout: MultiViewLayoutKind
    var highlight = false

    var body: some View {
        GeometryReader { g in
            let rects = layout.rects(width: g.size.width, height: g.size.height)
            ZStack(alignment: .topLeading) {
                Rectangle().fill(Color.black.opacity(0.6))
                ForEach(rects.indices, id: \.self) { i in
                    let r = rects[i]
                    Rectangle()
                        .fill(i < layout.bigCount ? Color.accentColor.opacity(0.55) : Color.white.opacity(0.18))
                        .overlay(Rectangle().stroke(Color.black.opacity(0.8), lineWidth: 1))
                        .frame(width: r.width, height: r.height)
                        .offset(x: r.minX, y: r.minY)
                }
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 3))
        .overlay(RoundedRectangle(cornerRadius: 3).stroke(highlight ? Color.white : Color.white.opacity(0.15),
                                                          lineWidth: highlight ? 2 : 1))
    }
}

/// The layout at full size; each cell is a menu to choose what it shows.
private struct CellCanvas: View {
    @EnvironmentObject var engine: SwitcherEngine
    @Binding var config: MultiViewConfig
    @ViewState private var editing: Int? = nil

    var body: some View {
        GeometryReader { g in
            let rects = config.layout.rects(width: g.size.width, height: g.size.height)
            let names = cellNames()
            ZStack(alignment: .topLeading) {
                Rectangle().fill(Color.black)
                ForEach(rects.indices, id: \.self) { i in
                    let r = rects[i]
                    cell(i, title: names[i])
                        .frame(width: r.width - 4, height: r.height - 4)
                        .offset(x: r.minX + 2, y: r.minY + 2)
                }
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 4))
    }

    /// Label per cell, resolving "Auto" cells to the input they will show.
    private func cellNames() -> [String] {
        let targets = config.cellTargets(inputIDs: engine.inputs.map(\.id))
        return targets.indices.map { k in
            let isAuto = config.slot(k) == .auto
            switch targets[k] {
            case .preview: return "PREVIEW"
            case .program: return "OUTPUT"
            case .talent: return "TALENT DISPLAY"
            case .empty, .auto: return isAuto ? L("자동 (입력 없음)") : L("비어 있음")
            case .input(let id):
                guard let i = engine.input(withID: id) else { return L("입력 (없음)") }
                return (isAuto ? L("자동") + " · " : "") + "\(engine.number(of: i)). \(i.name)"
            }
        }
    }

    private func color(_ s: MultiViewSlot) -> Color {
        switch s {
        case .preview: return Theme.preview.opacity(0.55)
        case .program: return Theme.program.opacity(0.55)
        case .empty: return Color.white.opacity(0.04)
        case .auto: return Color.white.opacity(0.10)
        case .input: return Color.white.opacity(0.20)
        case .talent: return Color.purple.opacity(0.45)
        }
    }

    private func set(_ i: Int, _ s: MultiViewSlot) {
        var v = config
        var slots = v.resolvedSlots
        slots[i] = s
        v.slots = slots
        config = v
    }

    private func cell(_ i: Int, title: String) -> some View {
        let s = config.slot(i)
        return ZStack {
            color(s)
            VStack(spacing: 2) {
                Text("\(i + 1)").font(.system(size: 9, weight: .bold)).foregroundColor(.white.opacity(0.5))
                Text(title).font(.system(size: 11, weight: .semibold)).foregroundColor(.white)
                    .lineLimit(2).multilineTextAlignment(.center).padding(.horizontal, 4)
            }
        }
        .overlay(Rectangle().stroke(editing == i ? Color.white : Color.white.opacity(0.25), lineWidth: editing == i ? 2 : 1))
        .contentShape(Rectangle())
        .onTapGesture { editing = i }
        .popover(isPresented: Binding(get: { editing == i }, set: { if !$0 && editing == i { editing = nil } }),
                 arrowEdge: .bottom) {
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    choice(L("자동 (입력 순서대로)"), i, .auto)
                    choice("Preview", i, .preview)
                    choice("Output", i, .program)
                    choice("Talent Display", i, .talent)
                    Divider().padding(.vertical, 3)
                    ForEach(engine.inputs) { inp in
                        choice("\(engine.number(of: inp)). \(inp.name)", i, .input(inp.id))
                    }
                    Divider().padding(.vertical, 3)
                    choice(L("비우기"), i, .empty)
                }
                .padding(8)
            }
            .frame(width: 240)
            .frame(maxHeight: 420)
        }
        .help(L("이 칸에 보여줄 화면 선택"))
    }

    private func choice(_ title: String, _ i: Int, _ s: MultiViewSlot) -> some View {
        Button {
            set(i, s)
            editing = nil
        } label: {
            HStack {
                Image(systemName: "checkmark").opacity(config.slot(i) == s ? 1 : 0)
                Text(title).lineLimit(1)
                Spacer()
            }
            .contentShape(Rectangle())
            .padding(.vertical, 3).padding(.horizontal, 4)
        }
        .buttonStyle(.plain)
    }
}
