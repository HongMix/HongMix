# HongMix 2.4.2 — handoff (Claude → GPT)

> **Superseded — don't publish 2.4.2.** It was never released; everything here ships in **2.4.3** with more fixes. Follow `docs/HANDOFF-2.4.3.md`. This file and `docs/test-results/2.4.2/` stay as the record of the 2.4.2 round.

Date: 2026-11-28 · Repo: local `main`, last commit `6ec5eb4` = v2.4.1 (published). The code changes are **not in the working tree**: they arrive as three PR merges plus one patch (§4).

**Publish 2.4.2: a faster switcher, plus Video Cue, MultiLayouts and a live preview in Input Settings.**
- Buttons, transitions and slider drags no longer freeze the main window for 0.15–0.7 s.
- Three community pull requests by @otiumvisuals are included: #15, #16 and #17.

## 1. State
| What | Value |
|---|---|
| Version | **2.4.2**, build **205** (203 = test build, 204 = replaced release candidate) |
| Installers | `build/dist/HongMix-2.4.2.dmg` / `.pkg`, ad-hoc signed |
| SHA-256 | DMG `52fd8c973979050483f4081bbb495ad565c0b6e787e9484843ea21c0c9c83d98` · PKG `1b9c0d6e3a4122426e8927245966073ba942505bd6a5374b35b2b1c1a8b2b958` |
| Merge helpers (outside the repo, **don't commit**) | `~/Desktop/HongMix/HongMix 2.4.2 배포/merge/pr16-resolved/` (10 files) and `…/merge/2.4.2.patch` (sha256 `9ddb9036…93ec`) |
| Already in the working tree (commit in step 3) | `docs/HANDOFF-2.4.2.md`, `docs/test-results/2.4.2/*`, `docs/screenshots/2.4.2/*` |
| Don't commit | `Blackmagic-settings-backup-2026-11-16/`, `docs/screenshots/2.0.9/*`, `build/`, `HongMIX-signing/`, `ThirdParty/` |

The installers were built from a clone where these exact steps were applied. Claude rehearsed §4 twice in a fresh clone: the result is identical to the tested tree (`Sources`, `Resources`, `tests`), and the contributor's commits keep his author name.

## 2. What's in 2.4.2
Details and numbers: `docs/test-results/2.4.2/verification.md`.

1. **The switcher reacts without freezing (Swift Observation).**
   - Before, about 80 views watched the whole engine, and any change re-ran them all (0.15–0.3 s on the main thread). While an input setting was being dragged, this happened 10 times a second.
   - Now each view updates only when what it shows changes:
     - master mute: 150 → 5–22 ms
     - fade: 170–330 → 42–62 ms
     - overlay: 156–314 → 40 ms
     - slider drag in Input Settings / Layers: 0.26–0.72 s → 50–70 ms
   - The switcher monitors stay at 56–60 fps during transitions. Program drops: 0, as before.
2. **Input Settings sliders:** the ↺ reset button responds on its whole square, not just on the arrow.
3. **PR #15 Video Cue** (otiumvisuals): a cue list with GO / STOP / PANIC, fades, outputs to monitors, background and test card. New input type "Video Cue" and window.
   - Our change: its audio follows Program like any input (the PR sent it to Master even off air).
4. **PR #16 MultiLayouts** (otiumvisuals): eight-box layouts, scenes with animated changes, rounded corners. New input type "MultiLayout" and window.
   - Our changes:
     - "Animate when going on air" is off by default, so CUT stays instant.
     - Scene names are localized.
5. **PR #17** (otiumvisuals): live preview beside Color Adjust, Key, Playback and List in Input Settings.
6. **Small fixes:** the bottom bar labels no longer wrap ("STREAM"); EN "color" spelling and a KO/EN mismatch in Video Cue.
7. **Compatibility:**
   - A project or autosave that contains a Video Cue or MultiLayout input does **not** open in 2.4.1 or older.
   - Projects without them open as before.

## 3. Screenshots
`docs/screenshots/2.4.2/`: synthetic inputs only (test patterns, colors), no paths or IPs. Each language was captured separately with the app set to that language.
- `ko-` / `en-` + `main-videocue` (Video Cue in Preview)
- `main-multilayout` (MultiLayout on Program with its scene buttons)
- `videocue` (Video Cue window)
- `multilayouts` (MultiLayouts window)

Use `en-*` in EN notes, `ko-*` in KO notes.

## 4. How to publish (order matters)
```bash
cd ~/Documents/ChatGPT/HongMIX
M="$HOME/Desktop/HongMix/HongMix 2.4.2 배포/merge"
export GIT_AUTHOR_NAME="Seunghoon Hong" GIT_AUTHOR_EMAIL="176268839+HongMix@users.noreply.github.com"
export GIT_COMMITTER_NAME="$GIT_AUTHOR_NAME" GIT_COMMITTER_EMAIL="$GIT_AUTHOR_EMAIL"

# 1) the three PRs as merge commits (contributor commits keep their author; GitHub marks the PRs merged on push)
for n in 15 16 17; do git fetch origin pull/$n/head:pr$n; done
git merge --no-ff pr17 -m "Merge PR #17 by @otiumvisuals: live preview in Input Settings"
git merge --no-ff pr15 -m "Merge PR #15 by @otiumvisuals: Video Cue"
git merge --no-ff --no-commit pr16      # expected conflicts in exactly these 10 files (both PRs add an input kind, API, shortcuts, window, button):
#   Sources/App/Engine/{APIFunctions,AudioMixer,InputModel,Shortcuts}.swift  Sources/App/HongMixApp.swift
#   Sources/App/UI/{ContentView,InputEditorSheet,MIDISettingsView,UISnapshots}.swift  docs/FUNCTIONS.md
(cd "$M/pr16-resolved" && find . -type f) | while read f; do cp "$M/pr16-resolved/$f" "$f"; git add "$f"; done
git commit -m "Merge PR #16 by @otiumvisuals: MultiLayouts"

# 2) 2.4.2: Observation, slider/reset fix, PR follow-ups, version
git apply "$M/2.4.2.patch"
git add Sources Resources tests
git commit -m "HongMix 2.4.2: Swift Observation for the switcher (no more full-window refreshes), reset buttons, PR follow-ups"

# 3) release docs
git add docs/HANDOFF-2.4.2.md docs/test-results/2.4.2 docs/screenshots/2.4.2   # plus the notes/manual/README edits below
git commit -m "Release HongMix 2.4.2"
```
- **Stop and ask the operator if:**
  - step 1 conflicts in other files than the 10 listed,
  - `git apply` doesn't apply cleanly, or
  - the PR heads moved: expected `pr15` = `e4cfed8`, `pr16` = `a8b5674`, `pr17` = `7123ced`.
- **Check before pushing:**
  - `python3 -I scripts/check-i18n.py`
  - `bash tests/multiview/run.sh`
  - `bash tests/multilayout/run.sh`
  - `bash tests/videocue/run.sh`
  - `git status` shows nothing from the "Don't commit" list.
- **Installers:** use the DMG/PKG as is. If you rebuild, use build **206**.
- **Release notes:** `docs/RELEASE-NOTES-2.4.2.md` / `.ko.md` / `-GITHUB.md` from §5, with the thanks line at the top. US spelling.
- **README (KO + EN):** add 2.4.2 to the @otiumvisuals thanks line (Video Cue, MultiLayouts, Input Settings preview).
- **Manuals (KO + EN), version 2.4.2. Add:**
  - Video Cue window and input:
    - GO / STOP / PANIC, fades, outputs to monitors, background, test card
    - API `VideoCue*`, `AddInput VideoCue`
  - MultiLayouts window and input:
    - boxes, scenes, scene change effects, "Animate when going on air" (off by default)
    - API `MultiLayout*`, `AddInput MultiLayout`
  - Input Settings: live preview beside Color / Key / Playback / List.
  - Note: projects with Video Cue or MultiLayout inputs need 2.4.2 or newer.
- **Push:** push `main`, then `gh release create v2.4.2 --repo HongMix/HongMix --latest`.
- **PR comments:** drafts are in `~/Desktop/HongMix/HongMix 2.4.2 배포/PR-댓글-초안.md`. Post them **only after the operator approves the text.**
- No Reddit posts unless the operator asks.

## 5. Release-note bullets (KO / EN)
- **감사 / Thanks:**
  - KO: Video Cue, MultiLayouts, 입력 설정 미리보기는 @otiumvisuals 님이 기여해 주셨습니다. 감사합니다!
  - EN: Video Cue, MultiLayouts and the Input Settings preview were contributed by @otiumvisuals — thank you!
- **스위처가 멈칫하지 않음 / The switcher no longer hitches:**
  - KO: 마스터 음소거, 컷·페이드, 오버레이, 프리뷰 변경 때 화면이 0.15~0.3초 멈추던 현상을 없앴습니다. 화면마다 자기가 보여 주는 값이 바뀔 때만 다시 그립니다.
  - EN: Master mute, cuts, fades, overlays and preview changes used to freeze the window for 0.15–0.3 s. Now each part redraws only when what it shows changes.
- **입력 설정 슬라이더 부드럽게 / Smooth sliders in Input Settings:**
  - KO: 위치·크롭·레이어 슬라이더를 끌 때 끊기지 않고, ↺ 버튼이 정사각형 전체에서 눌립니다.
  - EN: Position, crop and layer sliders drag smoothly, and the ↺ button responds on its whole square.
- **Video Cue (새 기능 / new):**
  - KO: 큐 목록을 GO·STOP·PANIC으로 재생합니다. 페이드, 모니터 출력, 배경, 테스트 화면을 지원합니다. 소리는 다른 입력처럼 Program을 따릅니다.
  - EN: Play a cue list with GO / STOP / PANIC, fades, outputs to monitors, a background and a test card. Its audio follows Program like any input.
- **MultiLayouts (새 기능 / new):**
  - KO: 상자 8개 레이아웃과 장면을 만들고 날아오기·커지기·페이드로 바꿉니다. 둥근 모서리도 지원합니다. "방송에 나갈 때 애니메이션"은 기본 꺼짐이라 CUT은 그대로 즉시입니다.
  - EN: Eight-box layouts and scenes that change with fly-in, grow or fade, with rounded corners. "Animate when going on air" is off by default, so CUT stays instant.
- **입력 설정 미리보기 / Input Settings preview:**
  - KO: 색 보정·키·재생·목록 탭 옆에 실시간 미리보기가 나옵니다.
  - EN: A live preview sits beside Color Adjust, Key, Playback and List.
- **참고 / Note:**
  - KO: Video Cue나 MultiLayout 입력이 들어간 프로젝트는 2.4.1 이하에서 열리지 않습니다.
  - EN: Projects that contain a Video Cue or MultiLayout input don't open in 2.4.1 or older.
