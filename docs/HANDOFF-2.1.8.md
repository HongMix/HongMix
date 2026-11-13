# HongMix 2.1.8 — handoff (Claude → GPT)

Date: 2026-11-14 · Mac: Apple M1 Max, macOS 27.3 · Repo: local `main`, last commit `13d147d` = v2.1.6 (published)

**2.1.7 was built but not published. Publish 2.1.8; it contains all of 2.1.7.** The release notes cover both (2.1.7 bullets: `docs/HANDOFF-2.1.7.md` §7). Everything is **uncommitted** on top of `13d147d`.

## 1. State

| What | Value |
|---|---|
| Version | `Resources/Info.plist` **2.1.8**, build **119** (118 was the internal test build before the review fixes, §6) |
| Installers | `build/dist/HongMix-2.1.8.dmg` / `.pkg`, ad-hoc signed (`SIGN_ID="-"`) |
| SHA-256 | DMG `751160011ed816511b162377ea97de2577ee0713e55cda2437e409982dcd7e07` · PKG `622e935b7aafd2806cc6f16447bb7a0e69413083c9e0a59d90f2b25e65b825bd` (`build/dist/SHA256.txt`) |
| Copy for the user | `~/Desktop/HongMix/HongMix 2.1.8 배포/` (DMG, PKG, SHA256.txt, `screenshots/`), `~/Desktop/HongMix 2.1.8.app` |
| Screenshots | `docs/screenshots/2.1.8/` — **separate KO and EN files** |

## 2. How to publish
1. Use the DMG/PKG as is (if you rebuild: build **120**, `SIGN_ID="-" bash scripts/make-dmg.sh`). `scripts/test-core.sh` PASS, `check-i18n.py` PASS, `hdiutil verify` VALID.
2. Commit as `Seunghoon Hong <176268839+HongMix@users.noreply.github.com>`. New files since `13d147d`: `Sources/App/Engine/Upscaler.swift`, `Sources/App/Engine/LayerPresets.swift`, `Sources/App/UI/UpscaleSection.swift`, `docs/HANDOFF-2.1.7.md`, `docs/HANDOFF-2.1.8.md`, `docs/screenshots/2.1.7/*`, `docs/screenshots/2.1.8/*`. Never add `HongMIX-signing/` or `build/`. (`docs/screenshots/2.0.9/*` are old untracked leftovers — not part of this release.)
3. `docs/RELEASE-NOTES-2.1.8.md` / `.ko.md` / `-GITHUB.md` from §5 here **plus** 2.1.7's §7. **Screenshots: KO notes / KO README use `ko-*.png`, EN notes / EN README / GitHub release use `en-*.png` — never mix.** EN text in US spelling like the app (color, center, gray); read the EN notes once against the KO before publishing. README "Latest update"; manuals + `docs/FUNCTIONS.md` (new API §4, Layers editor).
4. `gh release create v2.1.8 --repo HongMix/HongMix --latest`, same asset set as v2.1.6.

## 3. What's new in 2.1.8 (Layers tab — follow-up to the vMix user's feedback)

### 3.1 Layer presets (`LayerPresets.swift`, Layers › selected layer › **Presets ▾**)
- Save the selected layer's placement under a name: position, size, crop, rotation, opacity, border (width + color) and Fit/Fill. **Never the layer's input**, visibility or lock.
- **Stored app-wide** (UserDefaults `layerPresets`, JSON), so a preset works in every input and every project. Values are fractions of the output, so a 1080p preset fits a 720p project the same way.
- Menu: the presets (name — size in px) → apply; "Save Current Placement as Preset…" (name prompt; same name asks to replace); Rename; Delete. Applying is one undo step (⌘Z).
- Bad stored entries (non-finite or absurd values) are dropped on load, so they can't reach the renderer or break project saving.

### 3.2 Several layers at once (`LayersEditor.multiPanel`, `PlacementCanvas`)
- **⇧-click** in the list or the preview adds / removes a layer; **⌘A** in the preview selects all. The preview shows a dashed outline of the selection; dragging any selected box moves them all (snapping as one box), arrow keys move them all (1 px, ⇧ 10 px). Locked layers stay.
- Panel (replaces the single-layer details while ≥2 are selected): **Align to** Selected boxes / Frame / First selected box; align left / horizontal center / right / top / vertical center / bottom; **Space Evenly Across / Down** (Frame: equal space at the edges too, from 2 boxes; otherwise the outer boxes stay, from 3); **Same Size** (width and height / width only / height only, to the first selected box, top-left corners stay); Deselect. Every action is one undo step.

### 3.3 Snap to other layers
Moving a box (or a selection) now also snaps to the left / center / right and top / middle / bottom of the other visible layers (green guides), besides the frame edges, center and safe areas.

### 3.4 Cropping a rotated layer
The crop handles of a rotated layer now move that edge of the box, like an unrotated layer: the opposite edge stays put on screen and the picture keeps its size (2.1.7 changed only the crop on rotated layers). Same formula for every angle (`PlacementCanvas.layerCrop`).

## 4. API (HongMix extensions; the API is off by default)
| Function | Value | Effect |
|---|---|---|
| `LayerPreset` | `layer,preset name` (Input = target) | Apply a saved preset to that layer (name not case-sensitive); its input stays |
| `LayerPresetSave` | `layer,preset name` | Save that layer's placement as a preset (same name = replaced; name ≤ 60 chars) |
Errors: `Value=layer,preset name`, `Layer preset not found: <name>`.

## 5. Release-note bullets (KO / EN) — add to 2.1.7's list
- **레이어 위치 프리셋** — 자주 쓰는 배치(위치·크기·자르기·회전·불투명도·테두리)를 이름 붙여 저장하고 어느 입력·프로젝트에서든 한 번에 적용 / **Layer presets** — save a placement (position, size, crop, rotation, opacity, border) by name and apply it to any layer in any project.
- **여러 레이어 한꺼번에** — ⇧ 클릭·⌘A로 선택해 함께 이동, 왼쪽·가운데·오른쪽·위·아래 맞춤, 간격 같게, 크기 같게 / **Several layers at once** — ⇧-click or ⌘A, move together, align, space evenly, same size.
- **다른 레이어에 붙는 스냅** / **Boxes snap to other layers' edges and centers.**
- **회전한 레이어도 자르기 손잡이를 따라 상자 변이 움직임** / **Cropping a rotated layer moves that edge of the box**, like an unrotated one.
- API: `LayerPreset`, `LayerPresetSave` (Companion / Stream Deck).

## 6. Verification
Real app, user's project and defaults backed up and restored byte-identical (presets of the test removed with them; API off). Test media: color bars / test patterns only.

| Test | Result |
|---|---|
| `LayerPresetSave` / `LayerPreset` (API) | Saved, applied to another layer (position, size, rotation, opacity moved; input kept); name not case-sensitive; bad layer → `Value=layer,preset name`; unknown name → `Layer preset not found` |
| Presets survive an app restart | Yes (applied by name after relaunch) |
| **10-minute soak** (4 layers, one rotated + semi-transparent, a 360p input with AI upscaling, Cut/Fade every 10 s, a preset applied every 7 s ≈ 85×, opacity/rotation changed every 15 s, upscaling off/on every minute) | **0 dropped frames, 0 errors, 0 app restarts**; memory 344–450 MB, flat; render avg 1.8–3.7 ms, worst single frame 26.5 ms (frame = 33 ms) |
| Code review of the 2.1.8 code (separate reviewer, read-only) | No crash or NaN path. Fixed in build 119: (1)(2) *Space evenly* moved boxes wrongly around a locked layer and ignored "First selected box" → locked / first-selected / outer boxes are now fixed points and the boxes between them are spaced evenly; (3) a crop handle on a layer cropped > 95 % made the box jump → crop of two opposite sides capped at 95 % (handles and sliders), real width used; (4) a drag whose handle vanished mid-drag (selection changed by API) left stale start values → reset on selection change; (5) renaming a preset to an existing name made duplicates → asks to replace; (6) one damaged stored preset wiped the list → damaged entries skipped, unreadable data kept aside (`layerPresets.unreadable`); (7) snapshot hook limited to the Layers tab. Noted, not changed: (8) align / outline use the unrotated box of a rotated layer (§8) |
| Build 119 re-check | Presets apply after relaunch, render 2.1 ms avg, 0 drops |
| Build, `test-core.sh`, `check-i18n.py` (33 new EN strings, read one by one: US spelling, no Korean outside `L()`), `hdiutil verify` | PASS |
| KO / EN screenshots | `docs/screenshots/2.1.8/` — EN screens checked: no Korean left |

## 7. Screenshots (`docs/screenshots/2.1.8/`, KO + EN; color bars / test pattern only — no people, footage, IPs or keys)
| File | Shows |
|---|---|
| `ko-02-layers-editor.png` / `en-02-…` | Layers tab, one layer selected: px fields, Fit in Frame / Center / Source Aspect / Full Screen, Copy / Paste, **Presets ▾**, preset explanation, opacity / rotation |
| `ko-03-layers-align.png` / `en-03-…` | Four layers selected: dashed selection outline, **Align to**, six align buttons, Space Evenly Across / Down, Same Size, explanation |
2.1.7's screenshots (`docs/screenshots/2.1.7/`, position editor + layers editor) stay valid for the 2.1.7 bullets.

## 8. Known / open
- Align / distribute use the unrotated box of a rotated layer.
- Presets are app-wide only (not inside the project file); moving a project to another Mac doesn't bring its presets.
- Undo history is per app session.
- **Not verifiable by Claude:** mouse (⇧-click, group drag, snapping while dragging, rotated crop drag), ⌘A, arrow keys, the preset name dialog — macOS doesn't deliver synthetic input from the shell. The user tests these.
- Working rules: Korean replies; new build number every build; KO + EN UI complete (append to `en.json`, never re-serialize); tests never touch the user's project; never connect to real stream destinations.
