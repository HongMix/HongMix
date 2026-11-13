# HongMix 2.1.7 — handoff (Claude → GPT)

Date: 2026-11-14 · Mac: Apple M1 Max, macOS 27.3 · Repo: local `main`, last commit `13d147d` = v2.1.6 (published)

Everything below is **uncommitted** on top of `13d147d`.

## 1. State

| What | Value |
|---|---|
| Version | `Resources/Info.plist` **2.1.7**, build **117** (115/116 were internal builds, replaced after the stability review §6a and the English text review §6c) |
| Installers | `build/dist/HongMix-2.1.7.dmg` / `.pkg`, ad-hoc signed (`SIGN_ID="-"`) |
| SHA-256 | DMG `3507b7f63720238baf8b4158b5c7125fa64389ca32e36954a69c777eaa122e8e` · PKG `a22240bdbb2d2f84da4fb95ffb2170ce6ddfdf2a8ae9a9c72dfb41e9ecf4dadc` (`build/dist/SHA256.txt`) |
| Copy for the user | `~/Desktop/HongMix/HongMix 2.1.7 배포/` (DMG, PKG, SHA256.txt, `screenshots/`), `~/Desktop/HongMix 2.1.7.app` |
| Screenshots | `docs/screenshots/2.1.7/` (KO + EN) |

## 2. How to publish
1. Use the DMG/PKG as is (if you rebuild: build **118**, `SIGN_ID="-" bash scripts/make-dmg.sh`). `scripts/test-core.sh` PASS, `check-i18n.py` PASS, `hdiutil verify` VALID.
2. Commit as `Seunghoon Hong <176268839+HongMix@users.noreply.github.com>`. New files: `Sources/App/Engine/Upscaler.swift`, `Sources/App/UI/UpscaleSection.swift`, `docs/HANDOFF-2.1.7.md`, `docs/screenshots/2.1.7/*`. Never add `HongMIX-signing/` or `build/`. (`docs/screenshots/2.0.9/*` are old untracked leftovers — not part of this release.)
3. `docs/RELEASE-NOTES-2.1.7.md` / `.ko.md` / `-GITHUB.md` from §7. **Screenshots: KO notes / KO README use `ko-*.png`, EN notes / EN README / GitHub release use `en-*.png` — never mix.** EN text in US spelling like the app (color, center, gray); read the EN notes once against the KO before publishing; README "Latest update" with §8; manuals + `docs/FUNCTIONS.md` (new API functions §5, Layers editor, Position tab, AI upscaling).
4. `gh release create v2.1.7 --repo HongMix/HongMix --latest`, same asset set as v2.1.6.

## 3. Why (feedback from a vMix user on 2.1.6, KakaoTalk)
- "Crop and size are harder to set exactly than in vMix."
- "While adjusting numbers the yellow box grew and I can't make it exactly smaller again." — the box went past the frame; the canvas clipped it, so the resize handles were unreachable.
- "I pressed Trim Transparent Edges, nothing happened — is it a different function?" — his source had no transparency; the message went to the main window's status line, invisible in the settings window. **And it was really broken**: see §4.4.

## 4. What's new

### 4.1 vMix-style value entry (Layers and Position tabs) — `PlacementEditor.swift` `NudgeField` / `StepperField`
- Every value has a number field with **− / +** buttons: type a value (applied while typing), **↑↓ in the field = one step, ⇧↑↓ = ten**, ⇧-click on ± = ten. Layers: X / Y / Width / Height in output px; opacity %, rotation °, crop % (0.5 % steps).
- Position tab: the shared `slider()` helper now has the same field + ± (zoom, pan, crop in %, opacity, colour, audio sliders everywhere in Input Settings). Position column widened 400 → 480 pt.
- A one-line explanation under each group (how the keys work; what crop does).

### 4.2 Picture editor (`PlacementCanvas`)
- **Grey margin** (8 % each side) around the picture; boxes outside the frame stay visible, and handles of a box that sticks out further are **pinned to the edge of the margin** — always grabbable (dragging works on movement, so a pinned handle behaves the same).
- **"Outside the frame: right 280 px, bottom 70 px"** warning under the readout.
- **Arrow keys**: click the picture, then ←→↑↓ = 1 px, ⇧ = 10 px (selected layer, or the input's pan on the Position tab). Small "Arrow keys move" badge while focused.
- **Undo (⌘Z / button)**: `PlacementHistory` — position values + layers per input, 100 steps; field typing / nudges within 0.8 s are one step. Covers canvas drags, fields, sliders, list operations (add, delete, reorder, templates).

### 4.3 Layers tab extras (`LayersEditor.swift`)
- **Fit in Frame** (shrink keeping shape + move inside), **Center**, **Source Aspect** (box height = cropped source aspect, centre kept), **Full Screen**.
- **Copy Position / Paste** (x, y, w, h, crop, rotation; works across inputs).
- **Lock** per layer (no handles, fields disabled, arrow keys beep). Saved.
- **Opacity** and **Rotation** per layer (new, saved): renderer — `composeFragment` in `Mixer.metal` draws the rotated rect's bounding box and rotates back, 1 px anti-aliased edge; opacity multiplies colour, alpha and border. Editor draws the rotated box and handles; resize / crop / ⌥-slide work in the layer's own axes (opposite corner stays put).

### 4.4 Layer crop now fills the box (behaviour change) + Trim fixed
Before (2.1.4–2.1.6) a layer's crop only **hid** part of the source in place, so "Trim Transparent Edges" + Fill left a graphic small — the 2.1.6 handoff claimed it filled the box, but that was never verified and was wrong. Now (vMix layer rectangle): **the cropped part of the source is fitted (Fit) or fills (Fill) the box, centred** (`SwitcherEngine.composeLayers`: zoom/pan from crop, letterbox factors fx/fy). Dragging an orange handle in the editor moves that box edge with it, so the picture keeps its size and only that side is cut (vMix crop feel). Layers saved with crop in 2.1.4–2.1.6 are **converted when loaded** so they look the same (`InputLayer.init(from:)`: no `cropFills` key + crop → the box shrinks to the part that was visible; exact for sources with the output's aspect). New files carry `cropFills: true`, so the conversion runs once. Verified: a hand-made 2.1.6 project rendered in 2.1.6 and in 2.1.7 gives the same picture; re-saved and reopened, unchanged.
- Button renamed **"Trim Transparent Background"**; disabled with an inline orange explanation when the source has no transparent edge (re-checked every second while the layer is selected), green "Trimmed · left … top …" result inline.

### 4.5 AI upscaling (`Upscaler.swift`, `UpscaleSection.swift`, Input Settings › Position)
- Toggle "Enlarge low-resolution sources with AI" (default off, saved per input). Apple `VTLowLatencySuperResolutionScaler` (VideoToolbox, macOS 26+), real time. Only for sources smaller than the output, only while the input (or its original / a layer of it) is on Program, Preview, an overlay or the stinger; off-air inputs keep the model loaded but cost nothing.
- Like background removal the render thread never waits (newest finished frame, ≤1 frame late). Model supports 420v only and these factors: 640×360 → ×1.5/×2, 720×480 → ×1.5/×2, 1280×720 → ×1.5 (= 1080p). The smallest factor reaching the output is used.
- Status line in the tab (loading / source size → ×factor · ms per frame / not needed / unsupported / failed), orange when slower than a frame.
- Colour: buffers tagged BT.709 so conversions are exact; on real footage colour is unchanged (mean RGB within 1, same saturation); **very saturated synthetic colours (colour bars) come out paler** — a property of Apple's model, stated in the UI text.

### 4.6 Performance (measured)
Scene 1080p29.97: bars on Program with 3 layers (playing 360p clip + 2 PNGs), plus 3 off-air inputs with 4 PNG layers each.
| | render avg | max | drops | HongMix CPU |
|---|---|---|---|---|
| 2.1.6 code path (before) | 5.91 ms | 12.8 ms | 0 | 53 % |
| 2.1.7 | **3.07 ms** | 6.8 ms | 0 | 42 % |
| 2.1.7 + AI upscaling on air (640×360 ×2, 12.7 ms/frame on its own queue) | 3.48 ms | 8.5 ms | 0 | 51 % |

Two changes in `composeLayers` / `MetalMixer.compose(batch:)`:
1. **Composition cache**: an input's layer composition is reused while every layer has the same source frame (identity; buffers retained so they can't be recycled) and identical parameters (`ComposeLayer.same(as:)`) — static graphics are no longer redrawn 60×/s.
2. **One GPU round trip per frame**: all compositions that did change are encoded into one command buffer, one `waitUntilCompleted` (was one per input with layers). Nested layers already used the previous frame's composition; unchanged.

Verified no stale pictures: a playing layer keeps changing between snapshots; a static layered input picks up an opacity change at once.

## 5. API (HongMix extensions; API is off by default)
| Function | Value |
|---|---|
| `SetLayerRect` | `layer,x,y,width,height` (output px) |
| `SetLayerOpacity` | `layer,0…100` |
| `SetLayerRotation` | `layer,degrees` (−180…180, clockwise) |
| `LayerTrim` | `layer` — "No transparent edges" error when nothing to trim |
| `UpscaleOn / UpscaleOff / Upscale` | (Input) |
XML: `<inputUpscaleStats number state factor ms srcW srcH />` per input with an upscaler.

## 6. Verification (real app; project + defaults backed up and restored byte-identical; graphics test media only)
| Test | Result |
|---|---|
| Rotation 20° + opacity 50 % layer in Program | Rotated, anti-aliased, bars show through |
| Layer 800 px past the right edge | Grey margin shows it; right handles pinned at the margin edge; "Outside the frame: right 280 px, bottom 70 px" |
| Trim on a transparent lower third (1920×1080 PNG, graphic 520×180) in an 800×280 box | Before: thin strip; after: graphic fills the box. On a video layer: "No transparent edges" |
| AI upscaling 640×360 on Program | running ×2, 12.5–13.4 ms/frame, render unaffected, 0 drops |
| Colour through the upscaler | conversions exact (yellow 254,255,0 round trip); real frame mean RGB within 1 |
| Performance | §4.6 |
| Build, `test-core.sh`, `check-i18n.py` (45 new EN strings), `hdiutil verify` | PASS |
| KO / EN screenshots | `docs/screenshots/2.1.7/` |
| **Mouse drags, arrow-key nudge, ⌘Z, ± clicks, typing in fields** | **Not verifiable by Claude** (macOS doesn't deliver synthetic input from the shell) — the user tests these |

## 6a. Stability review (build 116)
Code review of the whole 2.1.7 diff (crash / race / leak focus) plus runtime tests. Fixed:
| Problem | Fix |
|---|---|
| Upscaler: one slow frame (>1 s, e.g. model load on a slow Mac) → "failed" for good | Retries with back-off 2 → 30 s; first frames of a session may take 8 s; a timed-out session is recreated; completion flag lock-protected |
| Upscaler: off-air input kept returning its last upscaled frame → frozen tile / MultiView / bus | Off air returns the live source (`process == false` → nil) |
| Upscaler: stale result from the previous resolution could be shown; "unsupported" never reported (always "failed", retried forever) | Result tagged with its source size; `setup` returns ok / unsupported / failed |
| Upscaler kept loaded after the last input turned it off; torn down while `paramsLock` held | Released when off; released outside the lock |
| `InputSource.upscaler` read by UI/API while the render thread writes it | Lock-guarded property |
| `SetLayerRect Value=nan,…` → `Int(nan)` crash; `inf`/`nan` in API or the X/Y fields → project can no longer be saved (JSON rejects non-finite) | Finite values only; X/Y fields clamped (−4…5 × frame) |
| Crop drag wrote back the whole layer from a copy made at drag start (undid API changes; wrong layer if the list changed mid-drag) | Drags look the layer up by id, write only geometry / crop |
| Layer detail fields bound by index → possible out-of-range crash if the layer is removed while a field is focused | Bound by layer id (`layers[layer: id]`, writes to a removed layer are ignored) |
| Layers tab with no layer selected: arrow keys moved the whole input (on air, nothing shown) | Beep instead |
| Batched compose: nested layers (A uses B, both with layers) one frame late | Batch flushed before an input that uses a pending one |

Runtime: legacy-project conversion (above); resolution changes 360 → 480 → 1080 → 360 on air (running ×2 / ×2 / not needed / ×2, 0 drops); off / on releases and reloads the model; invalid API values rejected without crash; 40-min soak — see §6b.

## 6b. 40-minute soak (build 116, same engine code as 117)
Scene: input with 2 layers (one rotated + 90 % opacity, one playing video), a 360p list input with AI upscaling cycling 360p → 480p → 1080p clips, Cut/Fade between them every 10 s, layer opacity/rotation changed every 30 s, upscaling switched off/on every 2 min.

| Measure | Result |
|---|---|
| Dropped frames | **0** |
| API errors / app restarts | 0 / 0 |
| Memory (RSS) | 302–365 MB, flat (no growth) |
| Render time | avg 3.5–5.9 ms, worst single frame 23 ms (frame = 33 ms) |
| Upscaler | 0 failures; ×2 at 9–14 ms/frame; "not needed" on the 1080p clip |

## 6c. English text review (build 117)
All new EN strings read one by one against the KO source. Fixed: spelling unified to US English like the rest of `en.json` (center, color, gray); badge "Arrow keys move" → "Arrow keys active"; upscaler failure text now says it retries (KO + EN). Scan of the diff: no Korean literal outside `L()`/`Lf()`. EN screenshots re-taken with 117 — no Korean left on screen.

## 7. Release-note bullets (KO / EN)
- **숫자로 정확하게 (vMix처럼)** — 위치·레이어의 모든 값에 숫자칸과 −/+; 칸에서 ↑↓ = 한 칸, ⇧ = 열 칸 / **Exact values like vMix** — number field with −/+ for every Position and Layer value; ↑↓ in a field = one step, ⇧ = ten.
- **화면 밖으로 나간 상자도 잡을 수 있게** — 미리보기 둘레 회색 여백, 손잡이는 항상 보이고, 밖으로 나간 길이를 px로 표시. ‘화면에 맞추기’ 한 번으로 화면 안으로 / **Boxes outside the frame stay editable** — gray margin, handles always reachable, "outside by … px" warning, Fit in Frame.
- **화살표 키 1px 이동, ⌘Z 되돌리기** / **Arrow keys move 1 px (⇧ 10 px), ⌘Z undoes.**
- **레이어 불투명도·회전·잠금, 가운데·원래 비율·전체 화면, 위치 복사·붙여넣기** / **Layer opacity, rotation and lock; Center, Source Aspect, Full Screen; Copy / Paste Position.**
- **레이어 자르기가 상자를 채우도록 변경** — 잘라낸 나머지가 상자를 채웁니다(vMix 방식). 이전 버전 프로젝트는 열 때 자동으로 바꿔 예전과 같은 모습으로 보입니다 / **Layer crop now fills the box** (vMix-style). Projects from earlier versions are converted on open and look the same.
- **‘투명 배경만 잘라내기’ 수정·안내** — 자막·PNG의 빈 투명 부분을 잘라 그래픽이 상자를 꽉 채움; 쓸 수 없는 소스는 이유를 바로 표시 / **Trim Transparent Background fixed** and explained inline.
- **AI 화질 올리기** — 720p·SD 등 저해상도 소스를 Apple 실시간 초해상도로 키움(입력 설정 › 위치, 기본 꺼짐, 송출 중에만 처리) / **AI Upscaling** for low-resolution sources (Input Settings › Position; off by default; processed only while on air).
- **레이어 합성 최적화** — 변하지 않는 레이어는 다시 그리지 않고 GPU 대기를 한 번으로: 레이어 많은 장면 렌더 시간 약 절반 / **Faster layers** — unchanged layers are reused and the GPU is waited on once per frame: about half the render time in layer-heavy scenes.

## 8. Screenshots (`docs/screenshots/2.1.7/`, build 117, **separate KO and EN files** for the KO / EN release notes and README; color bars / test pattern / graphics only — no people, footage, IPs or keys)
| File | Shows |
|---|---|
| `ko-01-position-editor.png` / `en-01-…` | Position tab of a 360p input (AI upscaling on): sliders + number fields with −/+, explanations, picture with gray margin |
| `ko-02-layers-editor.png` / `en-02-…` | Layers tab: layer 1 rotated 12° at 90 % with crop, px fields, Fit in Frame / Center / Source Aspect / Full Screen, Copy / Paste, Lock, crop %, Trim explanation |

## 9. Known / open
- Rotated layers: crop handles change crop only (the box edge doesn't follow); resize keeps the opposite corner.
- Undo history is per app session (not saved).
- AI upscaling needs macOS 26+; on older macOS the toggle is disabled with an explanation.
- Working rules: Korean replies; new build number every build; KO + EN UI complete (append to `en.json`, never re-serialize); tests never touch the user's project; never connect to real stream destinations.
