// Standalone check of the MultiLayout logic (bash tests/multilayout/run.sh).
import Foundation

var failures = 0
func check(_ ok: Bool, _ msg: String) { if !ok { failures += 1; print("FAIL: \(msg)") } }
func near(_ a: MLRect?, _ b: MLRect, _ msg: String) {
    guard let a else { check(false, "\(msg): no box"); return }
    let ok = abs(a.x - b.x) < 1e-9 && abs(a.y - b.y) < 1e-9 && abs(a.w - b.w) < 1e-9 && abs(a.h - b.h) < 1e-9
    check(ok, "\(msg): \(a) ≠ \(b)")
}

let full = MLRect(x: 0, y: 0, w: 1, h: 1), left = MLRect(x: 0, y: 0, w: 0.5, h: 1)
func scene(_ name: String, _ rects: [MLRect], seconds: Double = 0.5, appear: MLAppear = .fly) -> MLScene {
    var s = MLScene(name: name)
    for (k, r) in rects.enumerated() { s.boxes[k] = MLSceneBox(visible: true, rect: r) }
    s.seconds = seconds; s.appear = appear
    return s
}

// A box that is in both scenes moves to its new place, easing in and out
var set = MultiLayoutSettings()
set.scenes = [scene("A", [full]), scene("B", [left])]
var p = MLPlayer(settings: set)
p.take(scene: 0, at: 0)
near(p.frames(at: 0).first { $0.box == 0 }?.rect, full, "first scene shows at once")
p.take(scene: 1, at: 10)
near(p.frames(at: 10.25).first { $0.box == 0 }?.rect, MLRect(x: 0, y: 0, w: 0.75, h: 1), "halfway in time = halfway in place")
near(p.frames(at: 10.125).first { $0.box == 0 }?.rect, MLRect(x: 0, y: 0, w: 1 - 0.5 * 0.0625, h: 1), "ease-in: a quarter of the time = 1/16 of the way")
near(p.frames(at: 11).first { $0.box == 0 }?.rect, left, "arrived")

// A box that comes in flies from the nearest edge; one that goes flies out over the same edge
let pipBR = MLRect(x: 0.6, y: 0.6, w: 0.3, h: 0.3)       // nearest edge: right (and bottom, right wins ties)
let topBox = MLRect(x: 0.3, y: 0.05, w: 0.4, h: 0.2)      // nearest edge: top
set.scenes = [scene("A", [full]), scene("B", [full, pipBR, topBox])]
p = MLPlayer(settings: set)
p.take(scene: 0, at: 0); p.take(scene: 1, at: 10)
near(p.frames(at: 10).first { $0.box == 1 }?.rect, MLRect(x: 1, y: 0.6, w: 0.3, h: 0.3), "fly in: starts just off the right edge")
near(p.frames(at: 10).first { $0.box == 2 }?.rect, MLRect(x: 0.3, y: -0.2, w: 0.4, h: 0.2), "fly in: starts just above the top")
near(p.frames(at: 10.5).first { $0.box == 1 }?.rect, pipBR, "fly in: lands in its place")
p.take(scene: 0, at: 20)
near(p.frames(at: 20.25).first { $0.box == 1 }?.rect, MLRect(x: 0.8, y: 0.6, w: 0.3, h: 0.3), "fly out: halfway to the right edge")
check(p.frames(at: 21).allSatisfy { $0.box == 0 }, "after flying out the box is gone")

// Grow: from nothing at its centre. Fade: in place, opacity. Cut: there at once.
set.scenes = [scene("A", [full]), scene("G", [full, pipBR], appear: .grow), scene("F", [full, pipBR], appear: .fade), scene("C", [full, pipBR], appear: .cut),
              scene("A fade", [full], appear: .fade), scene("A cut", [full], appear: .cut)]
p = MLPlayer(settings: set)
p.take(scene: 0, at: 0); p.take(scene: 1, at: 10)
near(p.frames(at: 10).first { $0.box == 1 }?.rect, MLRect(x: 0.75, y: 0.75, w: 0, h: 0), "grow: starts as a point at its centre")
near(p.frames(at: 10.25).first { $0.box == 1 }?.rect, MLRect(x: 0.675, y: 0.675, w: 0.15, h: 0.15), "grow: half size halfway")
p = MLPlayer(settings: set)
p.take(scene: 0, at: 0); p.take(scene: 2, at: 10)
let fading = p.frames(at: 10.25).first { $0.box == 1 }
near(fading?.rect, pipBR, "fade: in its place from the start")
check(fading?.opacity == 0.5, "fade: half visible halfway")
p.take(scene: 4, at: 20)
check(p.frames(at: 20.25).first { $0.box == 1 }?.opacity == 0.5, "fade out (the new scene's way): half visible halfway")
p = MLPlayer(settings: set)
p.take(scene: 0, at: 0); p.take(scene: 3, at: 10)
near(p.frames(at: 10).first { $0.box == 1 }?.rect, pipBR, "cut: there at once")
p.take(scene: 5, at: 20)
check(p.frames(at: 20).allSatisfy { $0.box == 0 }, "cut: gone at once")

// Taking another scene during a change starts from where the boxes are now (no jump)
set.scenes = [scene("A", [full]), scene("B", [left]), scene("C", [MLRect(x: 0.5, y: 0, w: 0.5, h: 1)])]
p = MLPlayer(settings: set)
p.take(scene: 0, at: 0); p.take(scene: 1, at: 10); p.take(scene: 2, at: 10.25)
near(p.frames(at: 10.25).first { $0.box == 0 }?.rect, MLRect(x: 0, y: 0, w: 0.75, h: 1), "interrupted: continues from the halfway place")
near(p.frames(at: 10.75).first { $0.box == 0 }?.rect, MLRect(x: 0.5, y: 0, w: 0.5, h: 1), "interrupted: arrives in the new place")

// A box that gets another input crossfades: the old input stays under the new one while it fades in
let cam1 = UUID(), cam2 = UUID(), slides = UUID()
set.boxes[0].inputID = cam1
var s2 = scene("B", [full]); s2.boxes[0].input = slides             // scene B shows the slides in box 1
set.scenes = [scene("A", [full]), s2]
p = MLPlayer(settings: set)
p.take(scene: 0, at: 0)
check(p.frames(at: 0).map(\.input) == [cam1], "the box shows its own input")
p.setInput(cam2, box: 0, at: 5)
let x = p.frames(at: 5.15)
check(x.map(\.input) == [cam1, cam2] && x[0].opacity == 1 && abs(x[1].opacity - 0.5) < 1e-9, "new input fades in over the old (\(x))")
check(p.frames(at: 5.31).map(\.input) == [cam2], "crossfade done: only the new input")
check(p.settings.boxes[0].inputID == cam2, "the box keeps the new input")
p.take(scene: 1, at: 10)
check(p.frames(at: 10.15).map(\.input) == [cam2, slides], "a scene with its own input for a box crossfades to it")
p.take(scene: 0, at: 20)
check(p.frames(at: 21).map(\.input) == [cam2], "back to the box's own input")
set.inputFade = 0
p = MLPlayer(settings: set)
p.take(scene: 0, at: 0); p.setInput(cam2, box: 0, at: 5)
check(p.frames(at: 5).map(\.input) == [cam2], "crossfade 0 = cut")

// Ready-made layouts: a few exact ones, and every one fits on the screen with at most 8 boxes
check(MLPreset.full.rects == [full], "full screen: one box")
let sbs = MLPreset.sideBySide.rects
near(sbs.first, MLRect(x: 0.02, y: 0.265, w: 0.47, h: 0.47), "side by side: left 16:9 box, centred")
near(sbs.last, MLRect(x: 0.51, y: 0.265, w: 0.47, h: 0.47), "side by side: right 16:9 box")
let q = MLPreset.quad.rects
check(q.count == 4, "quad: four boxes")
near(q[3], MLRect(x: 0.51, y: 1 - 0.02 * 16 / 9 - (1 - 3 * 0.02 * 16 / 9) / 2, w: 0.47, h: (1 - 3 * 0.02 * 16 / 9) / 2), "quad: bottom-right box with equal gaps")
for pr in MLPreset.allCases {
    let r = pr.rects
    check(!r.isEmpty && r.count <= MLScene.boxCount, "\(pr): 1…8 boxes")
    check(r.allSatisfy { $0.x >= 0 && $0.y >= 0 && $0.x + $0.w <= 1 + 1e-9 && $0.y + $0.h <= 1 + 1e-9 && $0.w > 0 && $0.h > 0 }, "\(pr): on screen")
}
// Applying a layout to a scene places the first boxes and hides the rest; the scene keeps its own choices
var sc = scene("X", [full, full, full, full, full]); sc.boxes[1].input = slides; sc.appear = .grow
sc.apply(MLPreset.sideBySide.rects)
check(sc.boxes.map(\.visible) == [true, true, false, false, false, false, false, false], "two boxes shown, the rest hidden")
check(sc.boxes[1].rect == sbs[1] && sc.boxes[1].input == slides && sc.appear == .grow, "the scene keeps its inputs and animation")

// Saving and opening: a partial (older / hand-edited) MultiLayout still opens, with defaults for the rest
let partialML = #"{"scenes":[{"name":"Talk","boxes":[{"visible":true,"rect":{"x":0,"y":0,"w":0.5,"h":1}}],"appear":"grow"}]}"#.data(using: .utf8)!
let ml = try! JSONDecoder().decode(MultiLayoutSettings.self, from: partialML)
check(ml.scenes.count == 1 && ml.scenes[0].boxes.count == 8, "a scene always has 8 boxes")
check(ml.scenes[0].boxes[0].visible && ml.scenes[0].boxes[0].rect == left && !ml.scenes[0].boxes[1].visible, "given boxes kept, the rest hidden")
check(ml.scenes[0].appear == .grow && ml.scenes[0].seconds == 0.5, "animation kept, default length")
check(ml.boxes.count == 8 && ml.boxes[0].zoom == 1 && ml.boxes[0].fill && ml.inputFade == 0.3 && ml.scene == 0, "box looks and crossfade default")
check(ml.background.kind == .color && ml.foregroundPath.isEmpty, "no background picture or foreground by default")
let unknown = #"{"scenes":[{"name":"X","appear":"spin"}],"inputFade":"fast"}"#.data(using: .utf8)!
let mlu = try! JSONDecoder().decode(MultiLayoutSettings.self, from: unknown)
check(mlu.scenes[0].appear == .fly && mlu.inputFade == 0.3, "unknown values fall back instead of losing the layout")
var full8 = MultiLayoutSettings()
full8.boxes[2].inputID = cam1; full8.boxes[2].radius = 24; full8.boxes[2].zoom = 1.5; full8.boxes[2].borderColor = "#FF0000"
var t1 = scene("T", [left, pipBR], seconds: 0.8, appear: .fade); t1.boxes[1].input = slides
full8.scenes = [t1]; full8.scene = 0; full8.inputFade = 0
full8.background = MLBackground(kind: .input, color: "#000000", path: "", inputID: cam2); full8.foregroundPath = "/x/frame.png"
check(try! JSONDecoder().decode(MultiLayoutSettings.self, from: JSONEncoder().encode(full8)) == full8, "everything survives saving")
// The shared library of own layouts
let mine = MLLayout(name: "Interview", rects: [left, pipBR])
check(try! JSONDecoder().decode([MLLayout].self, from: JSONEncoder().encode([mine])) == [mine], "own layouts survive saving")

// Editing while on air: a moved box in the live scene is there at once; another box input crossfades;
// edits to a scene that is not on air change nothing on screen
set = MultiLayoutSettings(); set.boxes[0].inputID = cam1
set.scenes = [scene("A", [full]), scene("B", [left])]
p = MLPlayer(settings: set)
p.take(scene: 0, at: 0)
var edited = p.settings; edited.scenes[0].boxes[0].rect = pipBR
p.edit(edited, at: 5)
near(p.frames(at: 5).first?.rect, pipBR, "moved in the live scene: there at once")
edited.scenes[1].boxes[0].rect = full
p.edit(edited, at: 6)
near(p.frames(at: 6).first?.rect, pipBR, "edit of a scene not on air: nothing changes")
edited.boxes[0].inputID = cam2
p.edit(edited, at: 7)
check(p.frames(at: 7.15).map(\.input) == [cam1, cam2], "box input changed in the settings: crossfade")
edited.boxes[0].radius = 12
p.edit(edited, at: 8)
check(p.settings.boxes[0].radius == 12 && p.frames(at: 8).count == 1, "look changes apply without a transition")

if failures == 0 { print("multilayout: all checks passed") } else { print("multilayout: \(failures) failed"); exit(1) }
