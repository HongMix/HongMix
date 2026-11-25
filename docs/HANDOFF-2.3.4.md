# HongMix 2.3.4 — handoff (Claude → GPT)

Date: 2026-11-25 · Repo: local `main`, last commit `9130be8` = v2.3.3 (published). Everything below is **uncommitted** on top of it.

**Publish 2.3.4** — display output that turned itself off, a new center (transition) column, two-line translation captions, and Korean text that still showed in the English UI.

## 1. State
| What | Value |
|---|---|
| Version | `Resources/Info.plist` **2.3.4**, build **161** (158–160 = test builds) |
| Installers | `build/dist/HongMix-2.3.4.dmg` / `.pkg`, ad-hoc signed |
| SHA-256 | DMG `f836887e1706646dd1b9a35a360146cd29820121f4c9b8186491f41f487d6ef8` · PKG `b225b11be803db457b24e2dcb9436eb1a3e5dc5de4f3c547bc3576f8f5bdf790` |
| Changed | `Sources/App/UI/FullscreenOutput.swift`, `Sources/App/UI/SwitcherPanels.swift`, `Sources/App/UI/ContentView.swift`, `Sources/App/Engine/SwitcherEngine.swift`, `Sources/App/Engine/Captions.swift`, `Sources/App/Engine/CaptionStyle.swift`, `Sources/App/UI/CaptionsSheet.swift`, `Sources/App/Engine/Localization.swift`, `Sources/App/Engine/InputModel.swift`, `Sources/App/Engine/Outputs.swift`, `Sources/App/UI/TitleGallery.swift`, `Sources/App/UI/LaunchScreen.swift`, `Sources/App/Engine/APIFunctions.swift`, `Resources/en.json`, `Resources/Info.plist`, this file, `docs/screenshots/2.3.4/*`, `docs/test-results/2.3.4/*` |
| Don't commit | `Blackmagic-settings-backup-2026-11-16/`, `docs/screenshots/2.0.9/*`, `build/`, `HongMIX-signing/` |

## 2. Display output turned itself off after a while (window and fullscreen)
**Cause:** the Display output remembers a monitor. When that monitor was not connected, the output opened on another screen — but every macOS "screen parameters changed" notification (Dock / menu bar hiding, full-screen apps, wake, resolution — not only plugging) made `screensChanged()` see "the chosen monitor is gone" and close the output. The window mode never reopened, so it simply went off at a random moment.

**Fix (`FullscreenOutput.swift`):**
- The output closes only if it was really showing on the chosen monitor and that monitor is unplugged (fullscreen still reopens when it comes back, as before).
- Opened on a stand-in screen because the chosen monitor was absent → it stays where it is.
- Output **window** on a monitor that is unplugged → kept on air (macOS moves it to a remaining screen).
- New API test hook `TestScreensChanged` (posts the macOS notification).

**Verified** (real app, saved monitor = an unplugged external display): window mode and fullscreen mode each stayed on through 5 screen-change events (before: closed on the first).

## 3. New center column (transition column)
Approved by the operator from mockups. Same functions, HongMix identity (logo orange), less vMix-like:
- **Transition tabs** Fade · Merge · Wipe · Fly (the 4 slots). Click = the transition **AUTO** and the **T-bar** use (saved); right-click = change the effect. ⌥1–4 still run a slot directly.
- **Effect and length** of the selected slot: effect menu + slider 0–5 s (50 ms steps).
- **CUT · AUTO · Quick Play** — three equal buttons. CUT white, AUTO orange (shows the selected effect), Quick Play blue (first transition, as before: Return).
- **Horizontal T-bar** (left → right), orange handle, uses the selected transition.
- **Overlay 1–8** — round keys in each channel's colour, filled when on air.
- **Stinger** separate: small picker (media input, cut point) + **STINGER** button.
- FTB unchanged.
Files: `SwitcherPanels.swift` (`TransitionColumn`, `TransitionTabs`, `TransitionLength`, `BigTakeButton`, `OverlayBank`, `StingerRow`, `HTBar`), `SwitcherEngine.swift` (`autoSlot`, T-bar uses it), `ContentView.swift` (`Theme.brand`, `Theme.quickPlay`).

## 4. Translation captions: two readable lines
Operator: the translation changed too fast to read.
- While translating, the original keeps (caption lines − 1) lines and the **translation gets 2 lines** under it (new setting "Translation lines" 1–4 in Live Captions › Caption look; default 2).
- Each translation stays on screen **at least 3 s** (or the "minimum time per line" if longer); newer results wait and the newest is shown next.
- "Send test sentence" now also translates, so the translated layout can be checked without speaking.
Everything else unchanged. Files: `Captions.swift`, `CaptionStyle.swift` (`translationLines`), `CaptionsSheet.swift`.
**Verified:** EN → KO, test sentences every 0.5 s: the Korean lines changed at 1.0 s and 6.5 s (held ≥ 3 s); two Korean lines shown under the English.

## 5. Korean in the English UI
- Input status from the C core ("재생", "재생 완료", "SRT 연결 실패: …") was shown raw — now translated when HongMix is in English (`AppLanguage.localizedStatus` in `postStatus` and output errors). Verified: a finished video shows "Playback finished".
- The caption label left at its default ("AI 자막") follows the UI language ("AI captions").
- Title gallery: "All" / "My templates" showed nothing in English (compared against the translated word) — fixed.
- Launch screen: "TCP 8099 unavailable" check no longer depends on the Korean text.
- OCR check of the English main window, settings panels and input editors: no Korean left except the language picker ("한국어") and input names the user created while in Korean (their own content).

## 6. Screenshots (`docs/screenshots/2.3.4/`)
`ko-main.png` / `en-main.png` (new column + 2-line translation on Program), `ko-center-column.png` / `en-center-column.png`. Synthetic scene only (colour inputs, titles, a test video), no people / IPs / keys.

## 7. How to publish
1. Use the DMG/PKG as is (if you rebuild: build **162**). `check-i18n.py` PASS, `test-core.sh` PASS, `hdiutil verify` VALID.
2. Commit as `Seunghoon Hong <176268839+HongMix@users.noreply.github.com>` (files in §1).
3. Release notes `docs/RELEASE-NOTES-2.3.4.md` / `.ko.md` / `-GITHUB.md` from §8, with the screenshots (EN notes `en-*`, KO notes `ko-*`). US spelling.
4. Manuals: version 2.3.4; transition section → new column (tabs, length, CUT / AUTO / Quick Play, horizontal T-bar, overlay keys, stinger row); captions → "Translation lines".
5. `gh release create v2.3.4 --repo HongMix/HongMix --latest`.

## 8. Release-note bullets (KO / EN)
- **디스플레이 출력이 저절로 꺼지던 문제 수정** — 지정한 모니터가 연결돼 있지 않을 때 다른 화면에 띄운 출력이 잠시 뒤 닫히던 문제 / **Fixed the Display output turning itself off** — when the saved monitor was not connected, the output shown on another screen closed after a while.
- **새 센터 패널** — 트랜지션 탭과 길이 슬라이더, 같은 크기의 CUT · AUTO · Quick Play, 가로 T-바, 오버레이 1–8 원형 버튼, 스팅어 따로 / **New center panel** — transition tabs with a length slider, equal CUT · AUTO · Quick Play buttons, a horizontal T-bar, round Overlay 1–8 keys, and a separate stinger.
- **번역 자막 2줄** — 번역이 원문 아래 2줄로, 최소 3초씩 유지돼 읽기 쉬움 (줄 수 설정 가능) / **Two-line translated captions** — the translation shows in two lines under the original and stays at least 3 seconds (line count adjustable).
- **영어 화면에 남던 한국어 수정** — 입력 상태·오류 메시지·자막 라벨·타이틀 갤러리 / **Fixed Korean text in the English UI** — input status and error messages, the caption label, and the title gallery.
