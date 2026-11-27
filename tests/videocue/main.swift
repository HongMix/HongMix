// Standalone check of the Video Cue logic (bash tests/videocue/run.sh).
import Foundation

var failures = 0
func check(_ ok: Bool, _ msg: String) { if !ok { failures += 1; print("FAIL: \(msg)") } }

// A cue knows what kind of file it plays and what to call it
check(VideoCue(path: "/a/Clip.MOV").kind == .video, "mov = video")
check(VideoCue(path: "/a/logo.png").kind == .still, "png = still")
check(VideoCue(path: "/a/walk-in.mp3").kind == .audio, "mp3 = audio")
check(VideoCue(path: "/a/x.mov").displayName == "x", "name falls back to the file name")

// A saved list from an older or hand-edited project still opens, with defaults for what is missing
let partial = #"{"cues":[{"path":"/x/a.mov"},{"path":"/x/b.png","endAction":"black","fadeIn":1.5}]}"#.data(using: .utf8)!
let list = try! JSONDecoder().decode(VideoCueList.self, from: partial)
check(list.cues.count == 2, "both cues read")
check(list.cues[0].kind == .video && list.cues[0].endAction == .hold && list.cues[0].fadeIn == 0, "missing fields get defaults")
check(list.cues[1].kind == .still && list.cues[1].endAction == .black && list.cues[1].fadeIn == 1.5, "given fields kept")
let again = try! JSONDecoder().decode(VideoCueList.self, from: JSONEncoder().encode(list))
check(again == list, "round trip")

// Picture settings, outputs and the list's background: an older list gets "fit, whole picture, everywhere, black"
check(list.cues[0].fit == .fit && list.cues[0].zoom == 1 && list.cues[0].cropL == 0, "old cue: fit, no zoom, no crop")
let vc1 = UUID(), vc2 = UUID()
check(list.cues[0].shows(on: vc1) && list.cues[0].shows(on: vc2), "old cue shows on every Video Cue input")
check(list.background == nil, "old list: no background (black)")
var framed = VideoCue(path: "/x/a.mov")
framed.fit = .fill; framed.zoom = 1.2; framed.panX = 0.1; framed.cropT = 0.05; framed.hiddenOn = [vc2]
var withBG = VideoCueList(cues: [framed]); withBG.background = CueBackground(kind: .video, color: "#000000", path: "/x/loop.mov")
let back = try! JSONDecoder().decode(VideoCueList.self, from: JSONEncoder().encode(withBG))
check(back == withBG, "picture settings, outputs and background survive saving")
check(back.cues[0].shows(on: vc1) && !back.cues[0].shows(on: vc2), "a cue can be left off one Video Cue input")

// Fades: how visible/loud a deck is at a moment (picture and sound together)
let f = Fade(from: 0, to: 1, start: 10, seconds: 2)
check(f.level(at: 9) == 0 && f.level(at: 11) == 0.5 && f.level(at: 13) == 1, "linear fade, clamped")
check(!f.done(at: 11.9) && f.done(at: 12), "fade done at its end")
check(Fade(from: 1, to: 0, start: 0, seconds: 0).level(at: 0) == 0, "0-second fade is a cut")
check(Fade(from: 0.5, to: 0, start: 0, seconds: 1).level(at: 0.5) == 0.25, "fade-out from where an interrupted fade-in was")

func cue(_ name: String, fadeIn: Double = 0, fadeOut: Double = 0, end: VideoCue.EndAction = .hold) -> VideoCue {
    var c = VideoCue(path: "/show/\(name).mov")
    c.fadeIn = fadeIn; c.fadeOut = fadeOut; c.endAction = end
    return c
}

// GO with nothing playing: the selected cue goes into deck 0 and fades in; the next cue is selected
var m = CueMachine(cues: [cue("A", fadeIn: 1), cue("B", fadeIn: 2), cue("C")])
var cmds = m.go()
check(cmds == [.load(deck: 0, cue: 0), .play(deck: 0), .fade(deck: 0, to: 1, seconds: 1)], "GO idle: load, play, fade in (\(cmds))")
check(m.live == 0 && m.selected == 1 && m.deckCue == [0, nil], "deck 0 live with A, B selected next")

// GO while a cue plays: crossfade into the other deck, over the NEW cue's fade-in
cmds = m.go()
check(cmds == [.load(deck: 1, cue: 1), .play(deck: 1), .fade(deck: 1, to: 1, seconds: 2), .fade(deck: 0, to: 0, seconds: 2)],
      "GO playing: crossfade with B's fade-in (\(cmds))")
check(m.live == 1 && m.selected == 2 && m.deckCue == [0, 1], "deck 1 live, deck 0 still fading out")

// GO during that crossfade: the deck still fading out is cut and reused, so two decks are always enough
cmds = m.go()
check(cmds == [.stop(deck: 0), .load(deck: 0, cue: 2), .play(deck: 0), .fade(deck: 0, to: 1, seconds: 0), .fade(deck: 1, to: 0, seconds: 0)],
      "GO mid-crossfade reuses the outgoing deck (\(cmds))")
check(m.selected == 3, "past the end")
check(m.go() == [], "GO past the end does nothing")

// A deck whose fade-out finished is closed; a finished fade-in changes nothing
m = CueMachine(cues: [cue("A"), cue("B", fadeIn: 1)])
_ = m.go(); _ = m.go()
check(m.fadeFinished(deck: 0) == [.stop(deck: 0)], "fade-out done: deck closed")
check(m.fadeFinished(deck: 1) == [], "fade-in done: nothing")
check(m.deckCue == [nil, 1] && m.live == 1, "only deck 1 holds a cue")

// STOP fades the live cue out with its fade-out, then it closes
m = CueMachine(cues: [cue("A", fadeOut: 3), cue("B")])
_ = m.go()
check(m.stop() == [.fade(deck: 0, to: 0, seconds: 3)], "STOP fades out")
check(m.live == nil && m.selected == 1, "nothing live after STOP, selection kept")
check(m.fadeFinished(deck: 0) == [.stop(deck: 0)], "closed after the fade")
check(m.stop() == [], "STOP when idle does nothing")
check(m.go().first == .load(deck: 0, cue: 1), "GO after STOP starts the next cue on a free deck")

m = CueMachine(cues: [cue("A", fadeOut: 3), cue("B")])
_ = m.go(); _ = m.stop()
check(m.go().first == .load(deck: 1, cue: 1), "GO right after STOP lets the fade-out finish on the other deck")

// PANIC: everything off at once, selection stays
m = CueMachine(cues: [cue("A"), cue("B", fadeIn: 2)])
_ = m.go(); _ = m.go()
check(m.panic() == [.stop(deck: 0), .stop(deck: 1)], "PANIC stops both decks")
check(m.live == nil && m.deckCue == [nil, nil] && m.selected == 2, "PANIC keeps the selection")
check(m.panic() == [], "PANIC with nothing loaded does nothing")

// End of a cue
m = CueMachine(cues: [cue("A", end: .hold), cue("B", fadeOut: 1, end: .black), cue("C", end: .next), cue("D")])
_ = m.go()
check(m.deckEnded(deck: 0) == [] && m.live == 0, "hold: last frame stays, still live")
check(m.fadeOutLead(deck: 0) == nil, "hold: no early fade-out")
_ = m.go(); _ = m.fadeFinished(deck: 0)             // B on deck 1
check(m.fadeOutLead(deck: 1) == 1, "black: fade-out starts 1 s before the end")
check(m.nearEnd(deck: 1) == [.fade(deck: 1, to: 0, seconds: 1)], "black: fade-out")
check(m.nearEnd(deck: 1) == [] && m.deckEnded(deck: 1) == [], "black: no second fade; the end is ignored while fading")
check(m.fadeFinished(deck: 1) == [.stop(deck: 1)], "black: closed after the fade")
_ = m.go()                                          // C on deck 0
let auto = m.deckEnded(deck: 0)
check(auto.first == .load(deck: 1, cue: 3), "next: the end starts the following cue (\(auto))")
check(m.deckEnded(deck: 0) == [], "end of a deck that is no longer live is ignored")
m = CueMachine(cues: [cue("Z", end: .black)])
_ = m.go()
check(m.deckEnded(deck: 0) == [.stop(deck: 0)] && m.live == nil, "black without fade-out: cut at the end")
check(m.fadeOutLead(deck: 0) == nil, "no lead for an empty deck")
m = CueMachine(cues: [cue("L", fadeOut: 2, end: .loop)])
_ = m.go()
check(m.fadeOutLead(deck: 0) == nil && m.deckEnded(deck: 0) == [], "loop: never ends by itself")

// Choosing what the next GO starts
m = CueMachine(cues: [cue("A"), cue("B")])
m.previous(); check(m.selected == 0, "previous stops at the first cue")
m.next(); m.next(); m.next(); check(m.selected == 2, "next stops just past the last cue")
m.select(1); check(m.selected == 1, "select a cue")
m.select(9); check(m.selected == 1, "select out of range is ignored")
m.cues.removeLast(); m.next(); check(m.selected == 1, "removing cues keeps the selection in range")

// Another project's list: nothing playing, its first cue is next
var p = CueMachine(cues: [cue("A"), cue("B"), cue("C")])
_ = p.go(); _ = p.go()
cmds = p.replaceList([cue("X"), cue("Y")])
check(cmds == [.stop(deck: 0), .stop(deck: 1)], "new list: both decks off (\(cmds))")
check(p.selected == 0 && p.live == nil && p.deckCue == [nil, nil], "new list starts at its first cue")

// Deleting a cue above the next one keeps the same cue next
var r = CueMachine(cues: [cue("A"), cue("B"), cue("C")])
r.select(2)
r.remove(at: 0); check(r.selected == 1 && r.cues.map(\.displayName) == ["B", "C"], "delete above: C stays next")
r.remove(at: 1); check(r.selected == 1, "delete the next cue: the one after it (past the end) is next")

if failures == 0 { print("videocue: all checks passed") } else { print("videocue: \(failures) failed"); exit(1) }
