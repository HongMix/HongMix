// Standalone check of the MultiView layouts and slot handling (bash tests/multiview/run.sh).
import Foundation
import CoreGraphics

func L(_ s: String) -> String { s }   // the app's localizer, not needed here

var failures = 0
func check(_ ok: Bool, _ msg: String) { if !ok { failures += 1; print("FAIL: \(msg)") } }

let W: CGFloat = 1920, H: CGFloat = 1080
let expectedCells: [MultiViewLayoutKind: Int] = [.bigTop: 10, .bigBottom: 10, .bigLeft: 10, .bigRight: 10, .fourBig: 4,
                                                  .grid9: 9, .grid16: 16]

for l in MultiViewLayoutKind.allCases {
    let r = l.rects(width: W, height: H)
    check(r.count == expectedCells[l], "\(l): \(r.count) cells")
    // the cells tile the canvas exactly: total area matches and no two overlap
    let area = r.reduce(0) { $0 + $1.width * $1.height }
    check(abs(area - W * H) < 1, "\(l): area \(area)")
    for i in r.indices { for j in r.indices where j > i {
        check(r[i].intersection(r[j]).width * r[i].intersection(r[j]).height < 0.5, "\(l): cells \(i) and \(j) overlap")
    } }
    for (i, c) in r.enumerated() {
        check(c.minX >= 0 && c.minY >= 0 && c.maxX <= W + 0.5 && c.maxY <= H + 0.5, "\(l): cell \(i) off canvas")
        check(abs(c.width / c.height - 16.0 / 9.0) < 0.01, "\(l): cell \(i) not 16:9")
        if i < l.bigCount, l.bigCount < r.count {
            check(c.width > r[r.count - 1].width, "\(l): big cell \(i) not bigger than small cells")
        }
    }
}
// large cells sit on the side the name says
let top = MultiViewLayoutKind.bigTop.rects(width: W, height: H)
check(top[0].minY == 0 && top[1].minY == 0, "bigTop: large cells not on top")
let bottom = MultiViewLayoutKind.bigBottom.rects(width: W, height: H)
check(bottom[0].minY == H / 2 && bottom[1].minY == H / 2, "bigBottom: large cells not at the bottom")
let left = MultiViewLayoutKind.bigLeft.rects(width: W, height: H)
check(left[0].minX == 0 && left[1].minX == 0, "bigLeft: large cells not on the left")
let right = MultiViewLayoutKind.bigRight.rects(width: W, height: H)
check(right[0].minX == W / 2 && right[1].minX == W / 2, "bigRight: large cells not on the right")

// defaults: Preview, Output, then inputs in order
var mv = MultiViewConfig.standard()
check(mv.slot(0) == .preview && mv.slot(1) == .program && mv.slot(2) == .auto && mv.slot(9) == .auto, "default slots")

// switching layout keeps the user's own picks for cells that still exist
let cam = UUID()
var s = mv.resolvedSlots
s[3] = .input(cam)
s[7] = .empty
mv.slots = s
mv.setLayout(.fourBig)
check(mv.resolvedSlots.count == 4 && mv.slot(3) == .input(cam), "fourBig keeps cell 3 pick: \(mv.resolvedSlots)")
mv.setLayout(.bigLeft)
check(mv.slot(3) == .input(cam) && mv.slot(7) == .auto, "back to 10 cells: cell 3 kept, cell 7 back to default")

// Auto cells: the n-th Auto cell shows input n; explicit cells don't use up an input; too few inputs → empty
let a = UUID(), b = UUID()
var t = MultiViewConfig(name: "t", layout: .fourBig)            // preview, program, auto, auto
check(t.cellTargets(inputIDs: [a, b]) == [.preview, .program, .input(a), .input(b)], "auto cells follow input order")
check(t.cellTargets(inputIDs: [a]) == [.preview, .program, .input(a), .empty], "auto cell without input is empty")
t.slots = [.input(b), .program, .auto, .empty]
check(t.cellTargets(inputIDs: [a, b]) == [.input(b), .program, .input(a), .empty], "explicit cells keep their pick")
check(MultiViewConfig(name: "g", layout: .grid9).cellTargets(inputIDs: []).count == 9, "grid9 has 9 targets")
// a Talent Display cell stays a Talent cell and doesn't use up an input
t.slots = [.talent, .program, .auto, .auto]
check(t.cellTargets(inputIDs: [a, b]) == [.talent, .program, .input(a), .input(b)], "talent cell kept, autos still follow input order")

// Throttle: steps down under load or drops, only steps back up after 5 calm seconds, resets when unused
var th = MultiViewThrottle()
let budget = 40.0                                                 // 25 fps
for _ in 0..<25 { th.add(ms: 10) }
check(!th.evaluate(budgetMs: budget, dropped: 0, active: true) && th.divider == 1, "light load: full rate")
for _ in 0..<25 { th.add(ms: 32) }
check(th.evaluate(budgetMs: budget, dropped: 0, active: true) && th.divider == 2, "heavy load: half rate")
check(th.evaluate(budgetMs: budget, dropped: 3, active: true) && th.divider == 4, "drops: quarter rate")
for _ in 0..<10 { _ = th.evaluate(budgetMs: budget, dropped: 3, active: true) }
check(th.divider == MultiViewThrottle.maxDivider, "never below 1/\(MultiViewThrottle.maxDivider)")
check(th.renders(tick: 16) && !th.renders(tick: 17), "renders every n-th frame")
for k in 1...4 { th.add(ms: 5); check(!th.evaluate(budgetMs: budget, dropped: 0, active: true), "calm second \(k): no step yet") }
th.add(ms: 5)
check(th.evaluate(budgetMs: budget, dropped: 0, active: true) && th.divider == 4, "5 calm seconds: one step back up")
check(th.evaluate(budgetMs: budget, dropped: 5, active: false) && th.divider == 1, "no MultiView in use: back to full rate")

// Labels: Preview / Program say just that; inputs number + name; a custom label wins
check(MultiViewConfig.defaultLabel(.preview, number: nil, name: "Cam 1") == "PREVIEW", "preview label without the input name")
check(MultiViewConfig.defaultLabel(.program, number: nil, name: nil) == "PROGRAM", "program label")
check(MultiViewConfig.defaultLabel(.input(UUID()), number: 3, name: "Cam 3") == "3  Cam 3", "input label")
check(MultiViewConfig.defaultLabel(.empty, number: nil, name: nil) == nil, "empty cell: no label")
var lv = MultiViewConfig.standard()
lv.labels = ["", "ON AIR"]
check(lv.customLabel(0) == nil && lv.customLabel(1) == "ON AIR" && lv.customLabel(7) == nil, "custom label per cell, empty = automatic")

// A MultiView saved before labels existed still opens
let oldMV = #"{"id":"6F9619FF-8B86-D011-B42D-00C04FC964FF","name":"Old","layout":"grid9","slots":[],"showLabels":false,"showTally":true}"#
let dec = try! JSONDecoder().decode(MultiViewConfig.self, from: oldMV.data(using: .utf8)!)
check(dec.name == "Old" && dec.layout == .grid9 && !dec.showLabels && dec.labels.isEmpty && !dec.labelsBelow, "old MultiView decodes with label defaults")
check(try! JSONDecoder().decode(MultiViewConfig.self, from: JSONEncoder().encode(lv)) == lv, "round trip")

// Labels below: the picture shrinks (same 16:9), centred, with room around it and the label strip under it
let cellR = CGRect(x: 960, y: 540, width: 480, height: 270)
let (pic, strip) = MultiViewConfig.labelBelowRects(cell: cellR, labelHeight: 30)
check(abs(pic.width / pic.height - 16.0 / 9.0) < 0.01, "picture keeps 16:9 (\(pic))")
check(pic.width < cellR.width && pic.height < cellR.height - 30, "picture smaller than the cell")
check(abs(pic.midX - cellR.midX) < 0.5, "picture centred")
check(pic.minY > cellR.minY && strip.maxY < cellR.maxY, "room above the picture and under the label")
check(strip.minY == pic.maxY && strip.width == pic.width && strip.minX == pic.minX && strip.height == 30, "label strip right under the picture")

if failures == 0 { print("multiview: all checks passed") } else { print("multiview: \(failures) failed"); exit(1) }
