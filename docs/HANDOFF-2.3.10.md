# HongMix 2.3.10 — handoff (Claude → GPT)

Date: 2026-11-27 · Repo: local `main`, last commit `4ced42f` = v2.3.8 (published).

**Publish 2.3.10.** It contains:
- engine work (render-thread savings, smooth Browser-input video, no click at launch). It was prepared as 2.3.9, which is **skipped** and never released.
- community pull requests **#10–#14 by @otiumvisuals**. Per the operator, #14's background texture and #13's label style are options.

## 1. State
| What | Value |
|---|---|
| Version | `Resources/Info.plist` **2.3.10**, build **187** (174–186 = test builds) |
| Installers | `build/dist/HongMix-2.3.10.dmg` / `.pkg`, ad-hoc signed |
| SHA-256 | DMG `67b252aeae79c01f51f547118af89870b25ca6f385aa659fa26bee10e36a9651` · PKG `b39ea62fc269c2589647f62b6d35b4e42f7ad3e3d78dd4ef038cc30b947baa9d` |
| Uncommitted now | `Sources/App/Engine/MetalMixer.swift`, `Sources/App/Engine/SwitcherEngine.swift`, `Sources/Shaders/Mixer.metal`, `Sources/Core/mc_web.mm` (engine work) · `Resources/Info.plist` · this file · `docs/test-results/2.3.10/*` · `docs/screenshots/2.3.10/*` |
| Merge helpers (outside the repo, **don't commit**) | `~/Desktop/HongMix/HongMix 2.3.10 배포/merge/MetalMixer-pr13-resolved.swift` (sha256 `683de1dd…`) · `…/merge/2.3.10-options.patch` (sha256 `266a0e41…`) |
| Don't commit | `Blackmagic-settings-backup-2026-11-16/`, `docs/screenshots/2.0.9/*`, `build/`, `HongMIX-signing/`, `ThirdParty/` |

The release was built from a scratch clone made with exactly the steps in §4. Claude rehearsed them in a fresh clone: the resulting tree is identical to the tested one, and the contributor's commits keep their author.

## 2. What's in 2.3.10
**Engine** (details: `docs/test-results/2.3.10/verification.md` Part A)
1. **MultiCorder ISO:** all ISO frames are rendered in one GPU pass with one wait. Before, there was one wait per ISO. 4 ISOs: 1.67 → 0.79 ms per frame. Suggested by Hawk_Super on Reddit.
2. **MultiView labels:** each label is drawn once and kept on the GPU, instead of every label being redrawn on the CPU each frame. 4×4: 1.23 → 0.71 ms per frame. Same pixels (≤ 2/255). Also suggested by Hawk_Super.
3. **Browser input video is smooth with the main window on screen.** Chromium's "work now" requests went through a coalesced dispatch timer. They now run on the main run loop's next pass, and delayed work uses a zero-tolerance timer. YouTube: 25 → 30 fps, gaps 24/24 s → 0–1/24 s.
4. **No click at launch.** Chromium's audio service opened the speakers for ~0.1 s while HongMix was loading. Now `disable-audio-output` is set; page audio still goes to the mixer.

**Pull requests** (details: Part B and `pr-review.md`)
- #10 green ✓ on the launch screen in every skin.
- #11 a ring on the input tile's Overlay key whose channel remembers the input.
- #12 extra Scopes windows (one per camera), hardware-look controls.
- #13 MultiView: own name per cell, names on or below the picture. **Option (new):** automatic names "With input name" (default, as before) or "PREVIEW · PROGRAM".
- #14 hardware look: grey tones, squarer monitors and tiles, hardware keys in Talent Cue. **Option (new):** brushed-metal background, Settings › General, **off by default**. **Tally borders stay at 100 %** (the PR had 50 %).

**Checks:**
- Drops (operator's project): 0. HongMix GPU 6.6 % and WindowServer GPU 21.4–21.7 %, the same as before.
- check-i18n, MultiView tests, test-core, hdiutil and codesign all pass.

## 3. Screenshots
`docs/screenshots/2.3.10/` — synthetic inputs, LAN address masked, KO and EN captured separately with the app in that language:
- `ko-`/`en-` + `main`, `multiview`, `settings`, `talentcue`
- `multiview-labels.png`, `multiview-labels-below.png`

Use `en-*` in the EN notes and `ko-*` in the KO notes.

## 4. How to publish (order matters)
```bash
cd ~/Documents/ChatGPT/HongMIX
M="$HOME/Desktop/HongMix/HongMix 2.3.10 배포/merge"
export GIT_AUTHOR_NAME="Seunghoon Hong" GIT_AUTHOR_EMAIL="176268839+HongMix@users.noreply.github.com"
export GIT_COMMITTER_NAME="$GIT_AUTHOR_NAME" GIT_COMMITTER_EMAIL="$GIT_AUTHOR_EMAIL"

# 1) engine work (only these four files)
git add Sources/App/Engine/MetalMixer.swift Sources/App/Engine/SwitcherEngine.swift Sources/Shaders/Mixer.metal Sources/Core/mc_web.mm
git commit -m "Engine: one GPU wait for MultiCorder ISO, GPU-cached MultiView labels, smooth Browser-input video, no click at launch"

# 2) the five PRs as merge commits (contributor commits keep their author; GitHub marks the PRs merged on push)
for n in 10 11 12 13 14; do git fetch origin pull/$n/head:pr$n; done
git merge --no-ff pr10 -m "Merge PR #10 by @otiumvisuals: green launch check marks"
git merge --no-ff pr11 -m "Merge PR #11 by @otiumvisuals: overlay-key ring on input tiles"
git merge --no-ff pr12 -m "Merge PR #12 by @otiumvisuals: extra Scopes windows"
git merge --no-ff pr14 -m "Merge PR #14 by @otiumvisuals: hardware look refinements"
git merge --no-ff --no-commit pr13        # conflict in Sources/App/Engine/MetalMixer.swift only (expected)
cp "$M/MetalMixer-pr13-resolved.swift" Sources/App/Engine/MetalMixer.swift
git add Sources/App/Engine/MetalMixer.swift
git commit -m "Merge PR #13 by @otiumvisuals: MultiView labels (ported to the GPU label path)"

# 3) options + release files
git apply "$M/2.3.10-options.patch"
git add Sources Resources/en.json tests/multiview/main.swift Resources/Info.plist \
        docs/HANDOFF-2.3.10.md docs/test-results/2.3.10 docs/screenshots/2.3.10
git commit -m "Release HongMix 2.3.10: options for brushed-metal background and MultiView names, tally at full strength"
```
- If any step differs from the expected result, stop and ask the operator. Don't resolve differently.
  - Step 2 should conflict only in `MetalMixer.swift`.
  - `git apply` must apply cleanly.
- Check before pushing:
  - `python3 -I scripts/check-i18n.py`
  - `bash tests/multiview/run.sh`
  - `git status` must show nothing from the "Don't commit" list.
4. Use the DMG/PKG as is. If you rebuild, use build **188**.
5. Release notes `docs/RELEASE-NOTES-2.3.10.md` / `.ko.md` / `-GITHUB.md` from §5, with the thanks lines at the top. US spelling.
6. README (KO + EN): extend the thanks line so it mentions 2.3.10 as well (MultiView labels, Scopes windows, hardware-look refinements by @otiumvisuals).
7. Manuals: version 2.3.10. Add:
   - Settings › General "Brushed-metal background" (hardware look, off by default)
   - MultiView editor: "On picture / Below picture" and "With input name / PREVIEW · PROGRAM", plus per-cell names
   - Scopes "+" for another window
8. Push `main`, then `gh release create v2.3.10 --repo HongMix/HongMix --latest`.
9. **PR comments:** drafts are in `~/Desktop/HongMix/HongMix 2.3.10 배포/PR-댓글-초안.md`. Post them **only after the operator approves the text.**

## 5. Release-note bullets (KO / EN)
- 감사 / Thanks:
  - MultiView 이름표, 스코프 창, 하드웨어 룩 개선 등은 @otiumvisuals 님이 기여해 주셨습니다. 렌더링 개선 아이디어는 Reddit의 Hawk_Super 님께 받았습니다. 감사합니다!
  - MultiView labels, Scopes windows, hardware-look refinements and more were contributed by @otiumvisuals, and the render-thread ideas came from Hawk_Super on Reddit — thank you!
- **브라우저 입력 영상 끊김 수정** — 메인 창이 보일 때 유튜브 등 브라우저 영상이 끊기던 문제를 고쳤습니다. / **Smooth video in Browser inputs** — YouTube and other video in a Browser input no longer stutters while the main window is on screen.
- **시작할 때 '팍' 소리 수정** — 로딩 중 스피커에서 짧게 튀던 소리를 없앴습니다. / **No more click at launch** — HongMix no longer briefly opens the speakers while loading.
- **MultiCorder ISO·MultiView 가볍게** — ISO 녹화를 한 번에 처리하고(4개 기준 약 절반), MultiView 이름표는 한 번만 그려 다시 씁니다. / **Lighter MultiCorder ISO and MultiView** — ISO frames are rendered in one GPU pass (about half the time with 4 ISOs), and MultiView labels are drawn once and reused.
- **MultiView 이름 옵션** — 칸마다 이름 직접 지정, 이름을 화면 안 또는 아래에, 자동 이름은 '입력 이름 포함'(기본) 또는 'PREVIEW · PROGRAM'. / **MultiView name options** — your own name per cell, names on or below the picture, and automatic names "with input name" (default) or "PREVIEW · PROGRAM".
- **스코프 창 여러 개** — 카메라마다 따로 스코프를 볼 수 있습니다. / **More than one Scopes window** — watch each camera in its own window.
- **하드웨어 룩 다듬기** — 회색 톤, 각진 모니터·타일, Talent Cue 입체 버튼. 배경 금속 질감은 설정에서 켤 수 있습니다(기본 꺼짐). / **Hardware look refinements** — grey tones, squarer monitors and tiles, hardware keys in Talent Cue. A brushed-metal background can be turned on in Settings (off by default).
- **작은 개선** — 로딩 화면 체크 표시 초록색, 오버레이 채널이 기억하는 입력은 타일 키에 테두리 표시. / **Small touches** — green check marks on the launch screen; an input remembered by an overlay channel shows a ring on its tile key.
- 참고 / Note: MultiView 이름 옵션을 쓴 프로젝트도 이전 버전에서 열립니다(새 설정은 무시됨). / Projects that use the new MultiView name options still open in older versions (the new settings are ignored).
