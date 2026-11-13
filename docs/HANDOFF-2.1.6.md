# HongMix 2.1.6 — handoff (Claude → GPT)

Date: 2026-11-13 · Repo: local `main`, last commit `acaaff6` = v2.1.4 (build 111, published)

**Publish 2.1.6.** 2.1.5 (build 113, virtual-input audio fix, `docs/HANDOFF-2.1.5.md`) was built but not published — 2.1.6 contains it. Release notes cover both. Uncommitted on top of `acaaff6`.

## 1. State

| What | Value |
|---|---|
| Version | `Resources/Info.plist` **2.1.6**, build **114** |
| Installers | `build/dist/HongMix-2.1.6.dmg` / `.pkg`, ad-hoc signed |
| SHA-256 | DMG `7b7d7ea087d04567c3fe22e9aa06e18ff225d2badd965a254e29814d8fad575d` · PKG `29b97946846d8b16f85bac260eebe23c62034de18de8f349d746869066bc3426` (`build/dist/SHA256.txt`) |
| Copy for the user | `~/Desktop/HongMix/HongMix 2.1.6 배포/`, `~/Desktop/HongMix 2.1.6.app` |
| Screenshots | `docs/screenshots/2.1.6/` (KO + EN) |

## 2. How to publish
1. Use the DMG/PKG as is (rebuild → build 115, `SIGN_ID="-"`). `scripts/test-core.sh` PASS; `check-i18n.py` PASS.
2. Commit as `Seunghoon Hong <176268839+HongMix@users.noreply.github.com>`. New files: `Sources/App/UI/PlacementEditor.swift`, `docs/HANDOFF-2.1.5.md`, `docs/HANDOFF-2.1.6.md`, `docs/screenshots/2.1.6/*`. Never add `HongMIX-signing/` or `build/`.
3. `docs/RELEASE-NOTES-2.1.6.md` / `.ko.md` / `-GITHUB.md` from §5; README "Latest update" with §6; manuals + `docs/FUNCTIONS.md` (Position/Layers editor).
4. `gh release create v2.1.6 --repo HongMix/HongMix --latest`, same asset set as v2.1.4.

## 3. What's new (user feedback on 2.1.4's Position/Layers tabs)

User: "Move and Crop should be together; I want to move, resize and crop with the mouse on the picture like PGM, not coordinates; when I scroll down to crop/opacity the preview is gone — put it on the right; Fill looks odd."

### 3.1 One placement editor for Position and Layers (`PlacementEditor.swift` `PlacementCanvas`)
- **No mode switch.** On the live picture: drag inside = move, yellow corners = resize (aspect kept; Layers: ⇧ = free), orange edge handles = crop that side, **⌥-drag inside = slide the visible part** (vMix Layer Designer). Green guides snap to centre, edges and the 5 % / 10 % safe-area lines.
- **Position tab:** edits the input's own zoom / pan / crop with the same maths as Program (`EditableLayer.rect` = `sampleLayer` in Mixer.metal). Crop keeps the rest of the picture in place (vMix: crop never re-scales). The preview shows the input as placed in Program.
- **Layers tab:** the input's own picture with its layer boxes; click a box (or the layer number) to select it. Old Move/Crop segmented control removed.
- **Readout in output pixels** under the picture (X / Y / W / H px, zoom, pan, crop %), like vMix's toolbar.

### 3.2 Layout: values left, picture right
Position and Layers tabs widen the Input Settings window to 1240 × 760 and put the values in a scrolling column (400 pt) on the left, the 16:9 picture fixed on the right — cropping / opacity / mirror are always edited with the picture in view.
Layers: selected layer's **X / Y / Width / Height in px** (editable) + crop sliders.

### 3.3 "Trim Transparent Edges" (Layers › selected layer) — the "Fill looks odd" case
Graphics such as a lower-third title are full-screen transparent canvases (1920×1080) with the picture in one corner, so Fill fills the box with the empty canvas and the graphic stays small (vMix behaves the same). The button scans the layer source's current BGRA frame for non-transparent pixels and sets the layer crop to that area (+4 px margin); with Fill the graphic then fills the box. Titles, PNG images and other BGRA sources with alpha; others report "No transparent edges found".

### 3.4 Includes 2.1.5
Virtual input on air brings its original's audio in when the original is on Auto (follow video) — `docs/HANDOFF-2.1.5.md`.

## 4. Verification
| Test | Result |
|---|---|
| Position tab render (virtual TABLE STATUS, zoom 0.8, pan Y 0.28, crop R 10 %) | Box, handles and readout (X 192 Y −44 W 1382 H 864 px) line up with the rendered picture |
| Layers tab render (2 layers) | List + px fields + crop left, picture with selected box/handles right |
| Build, `test-core.sh`, `check-i18n.py`, codesign | PASS |
| **Mouse dragging (move / resize / crop / ⌥ slide), Trim button** | **Not verifiable by Claude** (macOS doesn't deliver synthetic clicks from the shell) — the user tests these |

## 5. Release-note bullets (KO / EN)
- **위치·레이어를 마우스로 편집** — 미리보기에서 안쪽을 끌면 이동, 노란 모서리는 크기, 주황 손잡이는 자르기, ⌥ 끌기는 보이는 부분 옮기기 (모드 전환 없음). 값은 픽셀로 표시 / **Edit position and layers with the mouse** — drag inside to move, yellow corners to resize, orange handles to crop, ⌥-drag to slide the visible part (no mode switch); values shown in pixels.
- **미리보기를 오른쪽에 고정** — 자르기·불투명도를 내려서 조정해도 화면이 계속 보입니다 / **Preview stays on the right** while you scroll through crop, opacity and other values.
- **투명 여백 자동 자르기** — 자막·PNG 같은 그래픽 레이어를 실제 그림만 남게 잘라 채우기가 칸을 꽉 채우도록 / **Trim Transparent Edges** for graphic layers, so Fill fills the box with the graphic.
- 가상 입력 송출 시 원본 오디오가 AUTO면 소리가 안 나던 문제 수정 (2.1.5) / Fixed silent virtual inputs when the original's audio is on Auto (2.1.5).

## 6. Screenshots (`docs/screenshots/2.1.6/`, KO + EN)
| File | Shows |
|---|---|
| `*-01-position-editor.png` | Position tab: values left, live picture right with move/resize/crop handles and px readout |
| `*-02-layers-editor.png` | Layers tab: layer list, selected layer px + crop + Trim button, picture with handles |

Graphics inputs only — no people, footage, IPs or keys.

## 7. Known / open
- Layer Designer: no Lock, no Copy/Paste of position between layers yet.
- Input-mode resize keeps aspect only (independent X/Y zoom stays on the sliders).
