# HongMix 2.4.3 — verification

- Builds: 206 (test), **207 (release, ad-hoc)**.
- 2.4.2 (builds 203–205) was never published. 2.4.3 contains everything verified for 2.4.2 (`docs/test-results/2.4.2/verification.md`) plus the fixes below.
- Base: `6ec5eb4` (v2.4.1) + PR #17, #15, #16 + the 2.4.3 patch. Apple M1 Max, macOS 27.3.
- Performance used the operator's current project (more inputs than in the 2.4.2 round, two MultiLayouts). Clicks, drags and screenshots used a synthetic project (test patterns and colors).
- Replay recording was not started.

## 1. What the operator reported on 2.4.2
1. **MultiLayouts:** dragging an input from the list onto a box put it in the wrong box. Only one box ever got it, never the one under the pointer.
2. **Input Settings › Position:** the ↺ reset buttons still often did nothing, and the sliders behaved oddly.
3. **The main window looks cluttered** now that there are many inputs.

## 2. Causes and fixes
### 2.1 MultiLayouts drop target
**Cause:** every box was drawn at its place with `.offset`, but SwiftUI keeps a view's drop target at its un-offset place, which is the top-left of the canvas for all boxes. Every drop landed on whichever box covered that corner.

**Fix:**
- One drop target covers the whole picture (`MLBoxDrop`, a `DropDelegate`). It drops on the visible box under the pointer, the top one when boxes overlap, and highlights that box while dragging.
- Pure hit test: `MLScene.box(atX:y:)`, covered by `tests/multilayout`:
  - quad: each of four points lands in its own box
  - overlapping boxes: the top box wins
  - a hidden box takes no drop

### 2.2 Dead ↺ buttons and sliders in Input Settings (and the Layers tab)
Found by clicking and dragging inside the real Input Settings sheet with a new in-app test hook (§4).

1. **Main cause: the preview canvas took clicks outside itself.**
   - When an input is moved far (e.g. Pan X −0.5 or more, or a big zoom), its yellow box extends past the canvas edge, into the form.
   - `.clipped()` only hides that part; SwiftUI still hit-tests it. So the invisible box sat over the sliders and ↺ buttons.
   - Clicks there grabbed the canvas instead: ↺ did nothing, and dragging a slider moved the picture (Pan X went to −2.27, past the slider's −2 limit).
   - **Fix:** `.contentShape(Rectangle())` on the canvas, so it only takes clicks inside its own bounds. Same guard on the MultiLayouts canvas.
2. **A number field with keyboard focus didn't update.**
   - The sheet's first number field (Zoom) gets focus when it opens. A focused field kept its text while the value changed: ↺, slider, preview drag.
   - **Fix:** the field shows the new value unless it already shows what is being typed. ↺ also ends editing first.
3. (2.4.2) ↺ takes clicks on its whole 24×24 square.

**Results** (synthetic project, the real Input Settings sheet opened from the main window, release build 207):

| Sequence | 2.4.2 code | 2.4.3 |
|---|---|---|
| Drag the Pan X slider, then ↺ (×3) | 1st drag OK; ↺ dead; next drags moved the picture (−2.14, −2.27) | **↺ resets to 0 each time; drags stay on the slider** |
| Zoom 1.5 via API while the Zoom field has focus | field still showed 1.00 | **field shows 1.50** |
| Zoom ↺ and Pan X ↺ at Pan −0.73 | — | **both reset (zoom 1, pan 0)** |

- Main window position editing (the "위치/Position" button) was checked the same way. With Program's box pushed past the monitor's edge, CUT still worked, so that part was not affected.

### 2.3 A calmer input area (option)
Each tile carried three rows of buttons (close/restart/play/Cut/Loop/monitor, audio, overlay 1–8). With 14 inputs that is about 200 buttons.

- **New option "Tile buttons on hover only":**
  - The cursor icon next to "Expand tile" in the Inputs header, or the right-click menu.
  - Tiles show the picture and the name. The buttons come up over the picture while the pointer is on the tile.
  - A muted or looping input keeps a small badge on its picture.
  - Name bar, tally colors, double-click and right-click work as before.
- **Off by default**, so nothing changes until the operator turns it on.
- Screenshots (`docs/screenshots/2.4.3/`): 8 inputs at the operator's tile size.
  - `ko-/en-tiles-always.png`: as before; the eighth row runs to the bottom.
  - `ko-/en-tiles-hover.png`: all 8 tiles in two short rows.
  - The window capture draws monitor pictures last, so the hover buttons and badges can't be seen in a capture.

## 3. Regression — operator's project
| | 2.4.2 (205) | 2.4.3 (207) |
|---|---|---|
| Speaker opened at launch | 0 / 0 | 0 / 0 / 0 / 0 |
| Drops: 30 s steady / 20 fades / 10 cuts | 0 / 0 / 0 | 0 / 0 / 0 in all runs |
| HongMix GPU (option off) | 11.8 %, 12.8 % | 12.7 %, 12.7 % |
| HongMix GPU (option on) | — | 12.3 %, 13.0 % |
| Slider drag (drag.sh): UI stall / monitor | — | 30 ms / 59–60 fps |
| Master mute / cut / preview / fade / overlay (eng.sh) | — | 3–18 / 11–54 / 3–29 / 28 / 20–25 ms |

- GPU is higher than in the 2.4.2 round for both versions because the operator's project now has more inputs.
- No HongMix crash reports.

**Checks:**
- `tests/multilayout`, `tests/videocue` and `tests/multiview` pass; `check-i18n` passes (3 new strings, US spelling).
- Release 207:
  - `hdiutil verify` VALID
  - `codesign --verify --deep --strict` OK (ad-hoc)
  - CEF bundled
  - no `/Users/` or scratch paths

## 4. New API
- `ShowInputProperties` (Input=…, Value=tab 0–9): opens Input Settings on that tab in the main window, as the tile's gear › Properties does.
- Test hooks (like `SnapshotView`):
  - `ClickWindow` (Value=`title|sheet,x,y`): a click sent to a window from inside HongMix, in points from the content's top left.
  - `DragWindow` (Value=`title|sheet,x,y,x2,y2`): a drag posted to HongMix's event queue, so sliders track it.
  - Neither moves the real pointer.

## 5. Operator data
- Before the tests, the operator agreed to quit HongMix.
- Backed up first and restored afterwards, all identical:
  - project
  - settings, compared by value; test-only keys deleted
  - incident list and folder (test incident folders moved to the work folder)
  - MultiCorder, Application Support and Movies listings

Scripts in this folder:
- `start.sh`: synthetic project.
- `eng.sh`, `tr.sh`, `drag.sh`, `reg.sh`: operator's project.
