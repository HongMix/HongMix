# HongMix 2.4.2 — verification

- Builds: 203 (signed test build), **205 (release, ad-hoc)**. Build 204 was an ad-hoc release candidate, replaced to fix the "Box" label.
- Base: `6ec5eb4` (v2.4.1) + PR #17, #15, #16 (otiumvisuals) + the 2.4.2 patch. Apple M1 Max, macOS 27.3.
- Performance tests used the operator's own project (11 media inputs + a Browser input). Functional tests and screenshots used a synthetic project (test-pattern files and colors only).
- Replay recording was **not** started in this round, so the operator's replay buffer is untouched.

## 1. What the operator reported
1. Fades, Merges and other AUTO transitions felt rough, and "cut off at the end". Cuts were fine. (Same as for 2.4.1.)
2. In Input Settings › Position and in the Layers editor, dragging a slider stuttered (mouse dragging on the picture worked), and the ↺ reset button sometimes did nothing.

## 2. Cause
About 80 views observed the whole `SwitcherEngine` (`ObservableObject` + `@EnvironmentObject`). Any change to any published engine property re-ran all of them on the main thread, costing about 0.15–0.3 s each time. Examples:
- master mute,
- the Program/Preview swap at the end of a transition,
- a preview change, an overlay.

On top of that, every change inside an input (name, status, position, crop, layers …) was forwarded as a full-engine refresh, up to 10 times a second. While a slider was dragged, the whole window rebuilt every 100 ms, so the slider stuttered and a click on ↺ could land in a stall.

The ↺ button was also borderless, so only the arrow's pixels (~14 pt) took clicks.

## 3. Changes (2.4.2 patch)
- **Swift Observation.** `SwitcherEngine` is `@Observable`. A view now re-runs only when a property it actually reads changes.
  - Views use `@Environment(SwitcherEngine.self)`, `Bindable(engine).x` for bindings, and `.environment(engine)`.
  - Internal state (render thread, timers, counters) is `@ObservationIgnored`, so it adds no tracking cost.
  - Input/output changes bump a revision that only views reading `engine.inputs` / `engine.outputs` follow. This is still batched to 10/s, so names, tally and status still update.
  - `engine.$programID` / `$previewID` / `$inputs` (MIDI tally, PTZ) became `programIDSubject` / `previewIDSubject` / `inputsSubject`. These are `CurrentValueSubject`s, so like `@Published` they send the current value on subscribe.
- **Buses A–G in the mixer** (`visibleBuses`) are stored and replaced only when the list changes. A volume or mute change no longer re-runs every channel strip and the main window.
- **↺ reset buttons** (Input Settings sliders): the whole 24×24 square clicks. They look the same.
- **Bottom bar:** labels never wrap. With the two new buttons, "STREAM" broke into "STREA / M" at 1600 pt.
- **PR fixes** (see §6).

## 4. Results — operator's project
UI stall = longest main-thread stall in the 2.4 s after the action. Monitor = the lowest Program monitor fps in that window.

| Action | 2.4.1 (202) | **2.4.2** |
|---|---|---|
| Master mute on/off | 133–153 ms | **5–22 ms** |
| Cut | 152–172 ms | **16–99 ms** |
| Preview change | 147–171 ms | **38–60 ms** |
| Fade (Transition1) | 168–332 ms | **42–62 ms** |
| Overlay 1 in/out | 156–314 ms | **40–42 ms** |
| AUTO ×5 per slot (tr.sh) | 168–315 ms, monitor ≥ 52 fps | **98–107 ms, monitor ≥ 56 fps** |
| Slider drag (pan X 30×/s, drag.sh) | **261–724 ms**, monitor 46–56 fps | **50–70 ms**, monitor 59–60 fps |
| First open: Audio Mixer / Scopes / Replay / Talent Cue / MultiView | 229 / 94 / 174 / 201 / 75 ms | 208 / 66 / 140 / 185 / 73 ms |

- Program dropped frames: **0** in every test, both versions.
- Main thread at idle (sample, 8 s): SwiftUI view-graph updates 217 → 134 samples, view bodies 41 → 7.
- Window first-open is still 0.07–0.2 s. That is SwiftUI building the window's views, not engine refreshes.

**Regression** (reg.sh, two runs each, alternating versions):

| | 2.4.1 | 2.4.2 |
|---|---|---|
| Speaker opened at launch ("click") | 0 / 0 | 0 / 0 |
| Drops: 30 s steady / 20 fades / 10 cuts | 0 / 0 / 0 | 0 / 0 / 0 |
| HongMix GPU (15 s) | 8.9 %, 7.6 % | 8.9 %, 8.4 % |

- No HongMix crash reports during the whole round.

## 5. Functional check — synthetic project, KO and EN (func.sh, release build 205)
- Renaming input 1 while it is on Program updates the tile, the Program label and the mixer strip. This is a child-object change seen through the engine.
- Master mute shows MUTE, and On returns it to ON (API `muted="False"`).
- Overlay 1, Cut and Fade: tally borders and the monitor labels follow.
- Video Cue (#15):
  - Add the input, add 2 cues, GO: the cue plays in the Video Cue tile and in Preview.
  - The Video Cue window shows the playing/next cue and the countdown.
- MultiLayouts (#16):
  - Add the input, put boxes 1/2 = cameras, Quad scene.
  - On Program, the scene buttons show under the Program monitor. The starter scene names are localized:
    - EN: Side by side / Full Screen / PIP / Quad
    - KO: 나란히 / 전체 화면 / PIP / 4분할
  - CUT away from the MultiLayout is **immediate**: about 120–150 ms including the API polling. The on-air animation is now off by default.
- Input Settings (#17): Color Adjust, Key and Playback show the live preview beside the form. Seen in the operator's own app; the test-hook window capture can't show Metal pictures.
- Unit tests:
  - `tests/multilayout`, `tests/videocue` and `tests/multiview` pass.
  - `scripts/check-i18n.py` passes.
- Release binary 205:
  - `hdiutil verify` VALID.
  - `codesign --verify --deep --strict` OK (ad-hoc).
  - CEF is bundled.
  - No `/Users/` or scratch paths.

## 6. Community PRs (otiumvisuals)
| PR | What | Merge | Changed by us |
|---|---|---|---|
| #17 | Input Settings: live preview beside Color, Key, Playback, List | clean | — |
| #15 | Video Cue: cue-list playback (GO / STOP / PANIC, fades, outputs to monitors, background, test card) | clean | <ul><li>A Video Cue input's audio follows Program like every other input. The PR sent it to Master even off air.</li><li>EN "colour" → "color".</li><li>The KO note now says, like the EN one, that picture settings apply at once.</li></ul> |
| #16 | MultiLayouts: 8-box layouts, scenes, animated scene changes, rounded corners | conflicts with #15 in 10 files (both add a new input kind, API, shortcuts, window, toolbar button); resolved keeping both | <ul><li>"Animate when going on air" is **off by default**. With it on, CUT/AUTO away from a MultiLayout waited for the box to grow, 0.5 s.</li><li>Starter scene names are localized.</li><li>"Box" label no longer wraps.</li></ul> |

Cost when the features are not used: one type check per input per frame and one empty audio check per audio tick. Mixer.metal adds one uniform branch, used only for rounded corners.

**Compatibility note:** a project or autosave that contains a Video Cue or MultiLayout input does not open in 2.4.1 or older. Older versions don't know the input kind and reject the whole input list, and the autosave restore then starts with an empty project. This has been true for every new input kind; mention it in the release notes.

## 7. Operator data
Project, settings (compared by value), incident list and folder, MultiCorder, Application Support and Movies listings were backed up first and restored afterwards; all identical. Test incident folders were moved to the test work folder.

Test scripts are in this folder. `$SCRATCH` = the test work folder; `bk242/` there holds the backup.
- `eng.sh`: single actions.
- `tr.sh`: AUTO transitions.
- `drag.sh`: slider drag.
- `reg.sh`: regression.
- `func.sh`: synthetic functional check and screenshots.
