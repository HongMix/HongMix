# HongMix 2.3.5 — handoff (Claude → GPT)

Date: 2026-11-25 · Repo: local `main`, last commit `9130be8` = v2.3.3 (published). Everything below is **uncommitted** on top of it.

**Publish 2.3.5 and skip 2.3.4.** 2.3.4 was built but never released; 2.3.5 contains all of it plus the changes in §3–§5. Read `docs/HANDOFF-2.3.4.md` §2, §4 and §5 for the display-output, caption and English-UI fixes (unchanged); §3 there (center column) is replaced by §3 here.

## 1. State
| What | Value |
|---|---|
| Version | `Resources/Info.plist` **2.3.5**, build **165** (158–164 = test builds; 161 = the unreleased 2.3.4) |
| Installers | `build/dist/HongMix-2.3.5.dmg` / `.pkg`, ad-hoc signed |
| SHA-256 | DMG `c07ff65d19dbd23f50a13522dd372f11d08419b05a2aa9fa3bd1540a9bc59859` · PKG `79f8d2de51030ecb5f0334fc48c9247f3b6e7093ffa35ee2a1569c924928204c` |
| Changed (2.3.4 + 2.3.5) | `Sources/App/UI/FullscreenOutput.swift`, `Sources/App/UI/SwitcherPanels.swift`, `Sources/App/UI/ContentView.swift`, `Sources/App/Engine/SwitcherEngine.swift`, `Sources/App/Engine/Inputs.swift`, `Sources/App/Engine/Captions.swift`, `Sources/App/Engine/CaptionStyle.swift`, `Sources/App/UI/CaptionsSheet.swift`, `Sources/App/Engine/Localization.swift`, `Sources/App/Engine/InputModel.swift`, `Sources/App/Engine/Outputs.swift`, `Sources/App/UI/TitleGallery.swift`, `Sources/App/UI/LaunchScreen.swift`, `Sources/App/Engine/APIFunctions.swift`, `Resources/en.json`, `Resources/Info.plist`, `docs/HANDOFF-2.3.4.md`, this file, `docs/screenshots/2.3.4/*`, `docs/screenshots/2.3.5/*`, `docs/test-results/2.3.4/*`, `docs/test-results/2.3.5/*` |
| Don't commit | `Blackmagic-settings-backup-2026-11-16/`, `docs/screenshots/2.0.9/*`, `build/`, `HongMIX-signing/` |

## 2. Included from 2.3.4 (details in HANDOFF-2.3.4.md)
- Display output (window and fullscreen) no longer turns itself off when the saved monitor is not connected.
- Two-line translated captions, each translation held ≥ 3 s ("Translation lines" setting).
- Korean text removed from the English UI (input status / errors from the core, caption label, title gallery).

## 3. Center column — final layout (operator's choice after testing 2.3.4)
2.3.4 left a large empty gap in the middle of the column. Final layout, top to bottom:
- Transition tabs Fade · Merge · Wipe · Fly (click = the transition AUTO and the T-bar use; right-click = change effect), effect menu + length slider.
- **CUT, AUTO, Quick Play — one full-width row each.** They share the free height (34–72 pt each, so small windows still fit). AUTO shows "AUTO" with the effect and length centred on the line below ("Fade 0.5 s").
- Horizontal T-bar, Overlay 1–8 round keys, stinger picker + STINGER button, FTB.

## 4. Stinger did not work properly (operator report) — fixed
Reproduced on the real app with a 2-second stinger clip:
- **Loop on (the usual setting for a new video input):** the clip never reached its end, so the stinger stayed on top of Program and kept playing (up to the 30 s safety limit), and kept playing afterwards. Now the stinger plays once: Loop is turned off for the run and restored afterwards, and the clip is paused when the stinger ends.
- **Every clip stopped ~0.5 s early** (stinger and any video played to its end): the decoder reports "finished" while its last frames are still queued, and HongMix paused right away. Now a clip counts as finished only after its last frame is shown (1 s at most). Verified: the 2-second clip now reaches 1960 ms (its last frame at 30 fps) instead of ~1500 ms, for both the stinger and a plain clip.
- The cut point works as set (Program switched at ~0.5 s with cut point 500 ms), twice in a row.
- New API `SetStinger` (Input = media input, Value = cut point ms) — stinger setup without the menu.
Files: `SwitcherEngine.swift` (`stinger`, `finishStinger`, end check), `Inputs.swift` (`pollPosition`), `APIFunctions.swift`.

## 5. Screenshots
`docs/screenshots/2.3.5/`: `ko-main.png` / `en-main.png`, `ko-center-column.png` / `en-center-column.png` (synthetic scene, no people / IPs / keys). For the captions, use `docs/screenshots/2.3.4/ko-main.png` / `en-main.png` (two-line translation on Program). Don't use `docs/screenshots/2.3.4/*-center-column.png` (old layout).

## 6. How to publish
1. Use the DMG/PKG as is (if you rebuild: build **166**). `check-i18n.py` PASS, `test-core.sh` PASS, `hdiutil verify` VALID.
2. One commit for everything, as `Seunghoon Hong <176268839+HongMix@users.noreply.github.com>` (files in §1). No v2.3.4 tag or release.
3. Release notes `docs/RELEASE-NOTES-2.3.5.md` / `.ko.md` / `-GITHUB.md` from §7, screenshots per §5 (EN notes `en-*`, KO notes `ko-*`). US spelling.
4. Manuals: version 2.3.5; transition section → new column (§3); stinger → plays once, `SetStinger`; captions → "Translation lines".
5. `gh release create v2.3.5 --repo HongMix/HongMix --latest`.

## 7. Release-note bullets (KO / EN)
- **새 센터 패널** — 트랜지션 탭과 길이 슬라이더, 한 줄씩 크게 놓인 CUT · AUTO · Quick Play, 가로 T-바, 오버레이 1–8 원형 버튼, 스팅어 따로 / **New center panel** — transition tabs with a length slider, large CUT · AUTO · Quick Play buttons (one per row), a horizontal T-bar, round Overlay 1–8 keys, and a separate stinger.
- **스팅어 수정** — 반복 재생이 켜진 영상도 한 번만 재생되고 끝나면 정확히 빠짐 / **Stinger fixed** — plays once even when the clip is set to loop, and clears as soon as it ends.
- **영상 끝 0.5초가 잘리던 문제 수정** — 끝까지 재생하면 마지막 프레임까지 나옴 / **Fixed the last half second of clips being cut off** — clips now play to their last frame.
- **디스플레이 출력이 저절로 꺼지던 문제 수정** / **Fixed the Display output turning itself off** when the saved monitor was not connected.
- **번역 자막 2줄** — 원문 아래 2줄, 최소 3초 유지 (줄 수 설정 가능) / **Two-line translated captions** — two lines under the original, each kept at least 3 seconds (adjustable).
- **영어 화면에 남던 한국어 수정** / **Fixed Korean text in the English UI** — input status and error messages, the caption label, and the title gallery.
