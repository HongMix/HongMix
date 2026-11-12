# HongMix 2.1.4 — handoff (Claude → GPT)

Date: 2026-11-13 · Mac: Apple M1 Max, macOS 27.3 · Repo: local `main`, last commit `85879a7` = v2.1.2 (build 109, published)

**Publish 2.1.4 only.** 2.1.3 (build 110) was built but **never published** — 2.1.4 contains everything from 2.1.3 (`docs/HANDOFF-2.1.3.md` §3) plus the items below. Release notes should cover both (§7). Everything is **uncommitted** on top of `85879a7`. `docs/screenshots/2.0.9/*.png` are old leftovers — not part of this release.

## 1. State

| What | Value |
|---|---|
| Version | `Resources/Info.plist` **2.1.4**, build **111** |
| Installers (built, tested) | `build/dist/HongMix-2.1.4.dmg` / `.pkg`, ad-hoc signed, LGPL FFmpeg |
| SHA-256 | DMG `0fc68930facb8e2a99ac84cb6a5de4f2847e258dfef9f59d368348d5d421f9c5` · PKG `038b93e3a8305cfb2cdd51d29ac69bd2997e29e260a269125f29394585d1eeea` (`build/dist/SHA256.txt`) |
| Copy for the user | `~/Desktop/HongMix/HongMix 2.1.4 배포/`, `~/Desktop/HongMix 2.1.4.app` (running) |
| Screenshots | `docs/screenshots/2.1.4/` (new) + `docs/screenshots/2.1.3/` (2.1.3 items) — §8 |

## 2. How to publish

1. Use the DMG/PKG in `build/dist/` (2.1.4 / 111). If you must rebuild: build **112**, `SIGN_ID="-" bash scripts/make-dmg.sh`.
2. `bash scripts/test-core.sh` (PASS). `scripts/check-i18n.py` runs inside the build and must pass.
3. Commit as `Seunghoon Hong <176268839+HongMix@users.noreply.github.com>`; never add `HongMIX-signing/` or `build/`. New files: `Sources/App/Engine/VirtualInput.swift`, `scripts/check-i18n.py`, `docs/HANDOFF-2.1.3.md`, `docs/HANDOFF-2.1.4.md`, `docs/screenshots/2.1.3/*`, `docs/screenshots/2.1.4/*`.
4. `docs/RELEASE-NOTES-2.1.4.md` / `.ko.md` / `-GITHUB.md` from §7 — **remote-control default change first**.
5. README "Latest update" with §8 screenshots; manuals + `docs/FUNCTIONS.md` (virtual input, layer crop, double-click, thumbnail smoothness, remote-control switch, ⌘W). API list: `CreateVirtualInput` is now supported.
6. `gh release create v2.1.4 --repo HongMix/HongMix --latest`, same asset set as v2.1.2 (DMG, PKG, manuals EN/KO, SHA256.txt, THIRD-PARTY-NOTICES.txt, screenshots of 2.1.3 + 2.1.4).

## 3. What's new in 2.1.4 (user feedback from a vMix user, checked against vMix 28/29 docs)

### 3.1 Virtual Input (`VirtualInput.swift`, `VideoSlot.addMirror` in `MediaBuffers.swift`, `SwitcherEngine.createVirtualInput`)
vMix: "Create Virtual Input — copies the settings and contents of this input into a new input"; it depends on the original (closed original → blank).
- Input picture **right-click › Create Virtual Input** (also on folded tiles) and API **`CreateVirtualInput`** (`Input=`).
- Every frame the original stores is handed to the virtual input as the **same CVPixelBuffer** — no second file open, no second decoder, no copy.
- Starts as a copy of the original's settings (position, crop, colour, key, layers); afterwards each has its own. Triggers, MultiCorder, failover are not copied; sound stays with the original (virtual input muted, no audio of its own).
- Playback follows the original like a layer: the virtual input going on air plays the original's media (Auto Play), leaving the air pauses it **unless the original is on air elsewhere** (`layerSources` treats the original as a child of the virtual input).
- Saved in the project (`InputConfig.virtualOf` = original id) and re-linked at load; re-linked every media tick, so a replaced original is picked up. Original removed → status "original input is missing", picture blank (as vMix).
- A virtual of a virtual links to the root original. Audio-only inputs can't have one.

### 3.2 Layer crop (`LayersEditor.swift`)
User: "can't crop on a layer — I had to load the same source again and crop that". The renderer already applied per-layer crop; there was no UI.
- Layers tab: **Move / Crop** mode (vMix Layer Designer). Crop mode: orange handles on the selected box's edges crop that side; dragging inside the box slides the visible part (vMix: Alt-drag in Crop).
- Below the list: **"Crop layer N"** sliders Left/Right/Top/Bottom (0–90 %) + Reset. The canvas shows the result live.

### 3.3 Settings window shows the result live (`InputPropertiesSheet.swift`)
User: "crop shows only in Preview, not in the settings window, so I crop by trial and error".
- Position tab: new top section **"Preview (placed as in Program)"** — 384×216, 30 fps, same placement maths as Program (zoom, pan, crop, fit). The small header monitor uses the placement too.

### 3.4 Double-click an input picture → Input Settings (`SwitcherPanels.swift`)
vMix habit. The first click still previews immediately (AppKit `clickCount`, no waiting for a second click); the second click opens Input Settings. The title bar double-click uses the same method now.

### 3.5 Input thumbnail smoothness (`InputTileRate` in `MediaBuffers.swift`, Settings › General › Playback)
User: "inputs look choppy — I know it's on purpose, but it makes me nervous". **6 / 15 / 30 fps** for the input tiles (proxy generation, tile redraw and off-air ticker titles follow it). Default 6 (unchanged). Program/Preview/outputs always run at the full rate.

### 3.6 Korean / English UI completed
- 83 English-only labels in the **Korean** UI translated (Input Settings tabs General/Position/Layers/Audio Settings/Triggers…, Cancel/Reset/Browse…, toggles such as Loop/Mirror/Low Latency Mode, audio channel names, launch-screen status lines). vMix/industry terms stay English on purpose: Cut, Quick Play, Overlay, MultiView, Stinger, Master, Bus, MultiCorder, Instant Replay, Waveform/Vector/Parade/Histogram, Fill & Key, brand and legal text.
- English side: every new string translated; `check-i18n.py` passes (build fails otherwise).

### 3.7 Test hooks (`UISnapshots.swift`)
`props-<n>-<tab>` (Input Settings of input n on a tab, real window titled "Snapshot props") and `layers-<n>` (Layers editor, layer 1 selected, Crop mode). Live video can't be drawn offscreen, so these open a real window; capture with `screencapture -l` and close it.

## 4. Verification (real app; project + defaults backed up and restored)

| Test | Result |
|---|---|
| Create Virtual Input of a clip and of a title | Created; VideoToolbox decoder count unchanged (8 → 8) |
| Virtual clip cut to Program | Original starts playing; original and virtual both **59.94 fps**, 0 render drops, programReuse 0 |
| Cut away from the virtual | Original paused (Auto Pause) |
| Original on Program + virtual in Overlay 1 in/out | Original **keeps playing** |
| Own placement | Zoom/pan/crop on the virtual changes only it (tile + Preview); original tile unchanged |
| Save / relaunch | `virtualOf` saved; both virtual inputs re-linked after restart |
| Layer crop render | Layer crop (L 0, T 55 %, R 60 %, B 15 %) cuts the layer exactly in Preview |
| Position tab live preview, Layers Crop mode | Shown correctly (screenshots §8) |
| `test-core.sh`, `check-i18n.py`, codesign | PASS / PASS / adhoc OK |

**Not verifiable by Claude on this Mac:** mouse input (double-click, dragging crop handles). macOS doesn't deliver synthetic clicks from the shell to SwiftUI. The user was asked to try them once.

## 5. API
`CreateVirtualInput` (Input) — returns an error for audio-only inputs. With remote control off (default since 2.1.3), the API is unavailable.

## 6. Known / open
- Layer Designer values are % (vMix shows pixels); no Lock / green snap guides / Copy-Paste of position yet.
- Virtual input transport buttons are dimmed — control playback on the original (it follows the virtual on air).
- CBR end-to-end measurement, audio-dropout listening path, notarization — unchanged from 2.1.3.

## 7. Release-note bullets (KO / EN) — 2.1.3 + 2.1.4

- **원격 제어 켜기/끄기 (기본: 꺼짐)** — 설정 › 네트워크 › 원격 제어. 끄면 8088·8099 포트를 아예 열지 않습니다. **Companion·Stream Deck·웹 리모트를 쓰시면 업데이트 후 한 번 켜 주세요** / **Remote control on/off (default: off)** — Settings › Network › Remote Control. When off, ports 8088/8099 stay closed. **Companion, Stream Deck and web-remote users: turn it on once after updating.**
- **가상 입력 (vMix Virtual Input)** — 입력 화면 우클릭 › 가상 입력 복사. 같은 화면을 다시 디코딩하지 않고 입력을 하나 더 만들어, 위치·자르기·레이어를 따로 쓸 수 있습니다 (재생·소리는 원본을 따라감) / **Virtual Input** — right-click an input › Create Virtual Input: the same picture without decoding it again, with its own position, crop and layers (playback and sound follow the original).
- **레이어 자르기** — 레이어 편집의 이동/자르기 모드와 레이어별 자르기 슬라이더. 같은 소스를 하나 더 불러올 필요가 없습니다 / **Layer crop** — Move/Crop modes in the Layers editor and per-layer crop sliders; no need to load the same source twice.
- **설정 창에서 바로 보이는 자르기·위치** — 위치 탭에 출력과 같은 배치의 실시간 미리보기 / **Crop and position shown live in Input Settings** (Position tab preview placed as in Program).
- **입력 화면 더블클릭 = 입력 설정** (vMix처럼, 첫 클릭은 바로 미리보기) / **Double-click an input = Input Settings** (as in vMix; the first click still previews at once).
- **입력 썸네일 부드럽게 6 / 15 / 30 fps** (설정 › 일반 › 재생 설정; 송출·녹화는 항상 원래 속도) / **Input thumbnail smoothness 6 / 15 / 30 fps** (outputs always full rate).
- ⌘W로 창 닫기 (메인·출력 창은 닫히지 않음) / ⌘W closes windows (never the switcher or Display output).
- 화면 지연 알림 정리, 렌더러 판정 최근 5분, 오디오 언더런 숫자 수정 / Calmer display-lag alerts, renderer judged on the last 5 minutes, fixed inflated audio-underrun counts.
- **한국어·영어 화면 완성** — 한국어 화면에 남아 있던 영어 문구와 영어 화면의 빠진 번역을 모두 채움 / **Complete Korean and English UI.**

## 8. Screenshots

`docs/screenshots/2.1.4/` (KO + EN each)

| File | Shows |
|---|---|
| `*-01-virtual-input.png` | Input 3 (original) and its virtual copy with its own zoom/pan |
| `*-02-position-live-preview.png` | Input Settings › Position: live preview placed as in Program (Korean tabs now translated) |
| `*-03-layer-crop.png` | Layers editor in Crop mode: orange crop handles + "Crop layer 1" sliders |
| `*-04-thumbnail-smoothness.png` | Settings › General › Playback: 6 / 15 / 30 fps |

`docs/screenshots/2.1.3/`: Mac cleanup, health banner, remote-control switch (see HANDOFF-2.1.3 §8). Only graphics inputs are visible — no people, footage, IPs or stream keys.

## 9. Working rules from the user
- New build number every build; Desktop copy `HongMix <ver>.app`; deliver DMG (+PKG).
- Korean + English UI complete (`L("한국어")`, append lines to `en.json`, never re-serialize; `check-i18n.py` must pass).
- Tests must not touch the user's project (backup/restore `last-session.bmix` + defaults); never connect to real stream destinations.
- Reply to the user in Korean.
