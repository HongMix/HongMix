# HongMix 2.4.3 — handoff (Claude → GPT)

Date: 2026-11-28 · Repo: local `main`, last commit `6ec5eb4` = v2.4.1 (published). The code is **not in the working tree**: it arrives as three PR merges plus one patch (§4).

**Publish 2.4.3. 2.4.2 is skipped** (never released; see the note at the top of `docs/HANDOFF-2.4.2.md`). 2.4.3 contains:
- everything prepared for 2.4.2: the faster switcher (Swift Observation), and PRs #15 Video Cue, #16 MultiLayouts and #17 Input Settings preview by @otiumvisuals;
- the fixes the operator asked for after trying 2.4.2:
  - MultiLayouts drag-and-drop
  - dead ↺ reset buttons and sliders in Input Settings
  - an option for calmer input tiles.

## 1. State
| What | Value |
|---|---|
| Version | **2.4.3**, build **207** (206 = test build; 203–205 = 2.4.2, unreleased) |
| Installers | `build/dist/HongMix-2.4.3.dmg` / `.pkg`, ad-hoc signed |
| SHA-256 | DMG `3ae57e31965c95dcc90fd0a7aa33697cf29ec2ee3ab215500c42b94b295c997c` · PKG `18ceaf5011dd6ca4025a9ea18ef29d7fe90d4767f74aed413b1bc756382540d5` |
| Merge helpers (outside the repo, **don't commit**) | `~/Desktop/HongMix/HongMix 2.4.3 배포/merge/pr16-resolved/` (10 files), `…/merge/2.4.3.patch` (sha256 `74dc4304…3a6b`) |
| Already in the working tree (commit in step 3) | <ul><li>`docs/HANDOFF-2.4.2.md` (marked superseded)</li><li>`docs/test-results/2.4.2/*`</li><li>`docs/screenshots/2.4.2/*`</li><li>this file</li><li>`docs/test-results/2.4.3/*`</li><li>`docs/screenshots/2.4.3/*`</li></ul> |
| Don't commit | `Blackmagic-settings-backup-2026-11-16/`, `docs/screenshots/2.0.9/*`, `build/`, `HongMIX-signing/`, `ThirdParty/` |

Claude rehearsed §4 in a fresh clone:
- The result is identical to the tested tree (`Sources`, `Resources`, `tests`).
- The contributor's commits keep his author name.

## 2. What's in 2.4.3
Details:
- `docs/test-results/2.4.2/verification.md` (Observation, PRs)
- `docs/test-results/2.4.3/verification.md` (the new fixes)

1. **The switcher reacts without freezing (Swift Observation).**
   - Before, any engine change re-ran about 80 views (0.15–0.3 s). While a setting was dragged, that happened 10 times a second.
   - Results:
     - master mute: 150 → 3–18 ms
     - fade: 170–330 → 28 ms
     - slider drag: up to 0.7 s → 30 ms
   - Monitors stay at 59–60 fps. Program drops: 0.
2. **Input Settings: ↺ and sliders work again.**
   - When an input was moved far (Pan X, zoom), the preview's invisible box reached over the sliders and ↺ buttons and took their clicks. The reset did nothing, and dragging a slider moved the picture instead.
   - Now the preview only takes clicks inside itself. Number fields show the new value even while they have keyboard focus, and ↺ responds on its whole square.
   - The same fix covers the Layers tab.
3. **MultiLayouts drag-and-drop:** an input dragged from the list goes into the box under the pointer. Before, every drop went to one box. That box is highlighted while dragging.
4. **Tile buttons on hover only (new option, off by default):**
   - Input tiles show picture and name; their buttons come up while the pointer is over a tile. Muted/looping inputs keep a small badge.
   - Turn it on with the cursor icon next to "Expand tile" in the Inputs header, or from the right-click menu.
5. **PR #15 Video Cue** (otiumvisuals): cue list with GO / STOP / PANIC, fades, outputs to monitors, background, test card.
   - Our change: its audio follows Program like any input.
6. **PR #16 MultiLayouts** (otiumvisuals): eight-box layouts, animated scenes, rounded corners.
   - Our changes:
     - "Animate when going on air" is off by default, so CUT stays instant.
     - Localized scene names.
7. **PR #17** (otiumvisuals): live preview beside Color Adjust, Key, Playback and List in Input Settings.
8. **Small fixes:** bottom-bar labels don't wrap; "Box" label; EN "color"; KO/EN wording in Video Cue.
9. **API:**
   - `ShowInputProperties` (Input, Value = tab).
   - Test hooks `ClickWindow` / `DragWindow`. Like `SnapshotView`, they are for testing; don't advertise them.
10. **Compatibility:** projects that contain a Video Cue or MultiLayout input don't open in 2.4.1 or older.

## 3. Screenshots
Synthetic inputs only; no paths or IPs. Each language was captured separately with the app in that language.
- `docs/screenshots/2.4.3/`: `ko-`/`en-` + `tiles-always`, `tiles-hover` (the new option, before/after).
- `docs/screenshots/2.4.2/`: `ko-`/`en-` + `main-videocue`, `main-multilayout`, `videocue`, `multilayouts`. Use them for the PR features.

Use `en-*` in EN notes and `ko-*` in KO notes.

## 4. How to publish (order matters)
```bash
cd ~/Documents/ChatGPT/HongMIX
M="$HOME/Desktop/HongMix/HongMix 2.4.3 배포/merge"
export GIT_AUTHOR_NAME="Seunghoon Hong" GIT_AUTHOR_EMAIL="176268839+HongMix@users.noreply.github.com"
export GIT_COMMITTER_NAME="$GIT_AUTHOR_NAME" GIT_COMMITTER_EMAIL="$GIT_AUTHOR_EMAIL"

# 1) the three PRs as merge commits (contributor commits keep their author; GitHub marks the PRs merged on push)
for n in 15 16 17; do git fetch origin pull/$n/head:pr$n; done
git merge --no-ff pr17 -m "Merge PR #17 by @otiumvisuals: live preview in Input Settings"
git merge --no-ff pr15 -m "Merge PR #15 by @otiumvisuals: Video Cue"
git merge --no-ff --no-commit pr16      # expected conflicts in exactly these 10 files:
#   Sources/App/Engine/{APIFunctions,AudioMixer,InputModel,Shortcuts}.swift  Sources/App/HongMixApp.swift
#   Sources/App/UI/{ContentView,InputEditorSheet,MIDISettingsView,UISnapshots}.swift  docs/FUNCTIONS.md
(cd "$M/pr16-resolved" && find . -type f) | while read f; do cp "$M/pr16-resolved/$f" "$f"; git add "$f"; done
git commit -m "Merge PR #16 by @otiumvisuals: MultiLayouts"

# 2) 2.4.3 code
git apply "$M/2.4.3.patch"
git add Sources Resources tests
git commit -m "HongMix 2.4.3: Swift Observation for the switcher, Input Settings reset/slider fix, MultiLayouts drop target, tile buttons on hover, PR follow-ups"

# 3) release docs
git add docs/HANDOFF-2.4.2.md docs/test-results/2.4.2 docs/screenshots/2.4.2 \
        docs/HANDOFF-2.4.3.md docs/test-results/2.4.3 docs/screenshots/2.4.3      # plus notes/manual/README/FUNCTIONS edits
git commit -m "Release HongMix 2.4.3"
```
- **Stop and ask the operator if:**
  - step 1 conflicts in other files,
  - `git apply` doesn't apply cleanly, or
  - the PR heads moved. Expected:
    - `pr15` = `e4cfed8`
    - `pr16` = `a8b5674`
    - `pr17` = `7123ced`
- **Check before pushing:**
  - `python3 -I scripts/check-i18n.py`
  - `bash tests/multiview/run.sh`
  - `bash tests/multilayout/run.sh`
  - `bash tests/videocue/run.sh`
  - `git status` shows nothing from the "Don't commit" list.
- **Installers:** use the DMG/PKG as is. If you rebuild, use build **208**.
- **Release notes:**
  - Files: `docs/RELEASE-NOTES-2.4.3.md` / `.ko.md` / `-GITHUB.md`, from §5. Thanks line at the top. US spelling.
  - Say that 2.4.2 was skipped.
- **README (KO + EN):** add 2.4.3 to the @otiumvisuals thanks line (Video Cue, MultiLayouts, Input Settings preview).
- **`docs/FUNCTIONS.md`:** add `ShowInputProperties`.
- **Manuals (KO + EN), version 2.4.3. Add:**
  - Video Cue window and input:
    - GO / STOP / PANIC, fades, outputs to monitors, background, test card
    - API `VideoCue*`, `AddInput VideoCue`
  - MultiLayouts window and input:
    - boxes, scenes, scene change effects, "Animate when going on air" (off by default)
    - drag inputs onto boxes
    - API `MultiLayout*`, `AddInput MultiLayout`
  - Input Settings: live preview beside Color / Key / Playback / List.
  - Inputs header: "Tile buttons on hover only".
  - API `ShowInputProperties`.
  - Note: projects with Video Cue or MultiLayout inputs need 2.4.3 or newer.
- **Push:** push `main`, then `gh release create v2.4.3 --repo HongMix/HongMix --latest`.
- **PR comments:** drafts are in `~/Desktop/HongMix/HongMix 2.4.3 배포/PR-댓글-초안.md`. Post **only after the operator approves the text.**
- No Reddit posts unless the operator asks.

## 5. Release-note bullets (KO / EN)
- **감사 / Thanks**
  - Video Cue, MultiLayouts, 입력 설정 미리보기는 @otiumvisuals 님이 기여해 주셨습니다. 감사합니다!
  - Video Cue, MultiLayouts and the Input Settings preview were contributed by @otiumvisuals — thank you!
- **스위처가 멈칫하지 않음 / The switcher no longer hitches**
  - 마스터 음소거, 컷·페이드, 오버레이, 프리뷰 변경 때 화면이 0.15~0.3초 멈추던 현상을 없앴습니다. 화면마다 자기가 보여 주는 값이 바뀔 때만 다시 그립니다.
  - Master mute, cuts, fades, overlays and preview changes used to freeze the window for 0.15–0.3 s. Now each part redraws only when what it shows changes.
- **입력 설정 ↺·슬라이더 수정 / Input Settings reset and sliders fixed**
  - 입력을 많이 옮기면 미리보기의 보이지 않는 상자가 왼쪽 설정을 가려 ↺와 슬라이더가 먹히지 않던 문제를 고쳤습니다. 숫자 칸도 바로 바뀐 값을 보여 줍니다.
  - With an input moved far, the preview's invisible box covered the settings beside it, so ↺ and the sliders didn't respond. Fixed, and number fields now always show the current value.
- **MultiLayouts 끌어 놓기 / MultiLayouts drag-and-drop**
  - 입력을 끌어 놓으면 마우스 아래 상자에 들어갑니다.
  - An input dropped on the layout goes into the box under the pointer.
- **타일 버튼은 마우스를 올렸을 때만 (새 옵션) / Tile buttons on hover only (new option)**
  - 입력 타일에 그림과 이름만 보이고, 버튼은 마우스를 올렸을 때 나타납니다. 입력 헤더의 커서 아이콘이나 우클릭 메뉴로 켭니다(기본 꺼짐).
  - Tiles show just picture and name; the buttons appear on hover. Turn it on with the cursor icon in the Inputs header or the right-click menu (off by default).
- **Video Cue (새 기능 / new)**
  - 큐 목록을 GO·STOP·PANIC으로 재생합니다. 페이드, 모니터 출력, 배경, 테스트 화면을 지원하고, 소리는 다른 입력처럼 Program을 따릅니다.
  - A cue list with GO / STOP / PANIC, fades, outputs to monitors, a background and a test card. Its audio follows Program like any input.
- **MultiLayouts (새 기능 / new)**
  - 상자 8개 레이아웃과 장면을 날아오기·커지기·페이드로 바꿉니다. 둥근 모서리도 지원합니다. "방송에 나갈 때 애니메이션"은 기본 꺼짐이라 CUT은 즉시 됩니다.
  - Eight-box layouts and scenes that change with fly-in, grow or fade, with rounded corners. "Animate when going on air" is off by default, so CUT stays instant.
- **입력 설정 미리보기 / Input Settings preview**
  - 색 보정·키·재생·목록 탭 옆에 실시간 미리보기가 나옵니다.
  - A live preview sits beside Color Adjust, Key, Playback and List.
- **참고 / Note**
  - 2.4.2는 배포하지 않고 2.4.3에 합쳤습니다. Video Cue나 MultiLayout 입력이 있는 프로젝트는 2.4.1 이하에서 열리지 않습니다.
  - 2.4.2 was skipped; its changes are in 2.4.3. Projects with a Video Cue or MultiLayout input don't open in 2.4.1 or older.
