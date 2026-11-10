# HongMix 2.1.0 — handoff (Claude → GPT)

Date: 2026-11-10 · Mac: Apple M1 Max, macOS 27.3 · Repo: `/Users/deanhong/Documents/ChatGPT/HongMIX` (branch `main`)

**GPT publishes to GitHub.** v2.0.9 is released (commit `fc40406`, build 96). 2.1.0 is **uncommitted** in the working tree: 16 modified files, ~+250 lines, no new source files. Untracked `docs/screenshots/2.0.9/*.png` (13 files) were left by the 2.0.9 release work — decide whether they belong in git (they are not part of 2.1.0).

## 1. State

| What | Value |
|---|---|
| Version | `Resources/Info.plist` 2.1.0, build **98** (96 = public 2.0.9, 97 was an internal step) |
| Local installers (dev-signed, not for public release) | `build/dist/HongMix-2.1.0.dmg` / `.pkg` |
| Installed on the user's Mac | `/Applications/HongMix.app` = 2.1.0 build 98; Desktop copy `HongMix 2.1.0.app` |
| Release notes | to write: `docs/RELEASE-NOTES-2.1.0.md` / `.ko.md` / `-GITHUB.md` (content in §3 and §6) |

## 2. How to publish

1. Bump build to 99, then `SIGN_ID="-" bash scripts/make-dmg.sh` (public builds are ad-hoc signed).
2. `hdiutil verify`, `codesign -dvv` → `Signature=adhoc`.
3. `bash scripts/test-core.sh` (no C core changes in 2.1.0, the Metal shader changed — see §4).
4. Commit as `Seunghoon Hong <176268839+HongMix@users.noreply.github.com>`; never add `HongMIX-signing/` or `build/`.
5. README / README.ko: 2.1.0 highlights. Also add a top section **"처음 실행 시 '열지 않음'이 뜰 때"** (System Settings › Privacy & Security › "Open Anyway", or `xattr -dr com.apple.quarantine /Applications/HongMix.app`) — beta testers hit this (app is not notarized).
6. `gh release create v2.1.0 --repo HongMix/HongMix --latest`, same asset set as v2.0.9.
7. Manuals + `docs/FUNCTIONS.md`: add the items in §3 / §5.

## 3. What changed (from beta tester feedback)

1. **New videos don't loop by default.** Settings › General › Playback › "새 영상 입력 기본 루프" (UserDefaults `newVideoLoop`, default off). Applies when an input is *created* (Add Input sheet, Finder drop incl. ⌥ List, API `AddInput Video|…`). Loading a project keeps each input's saved loop; the tile Loop button is unchanged. Code: `InputConfig.newVideoLoop` (`InputModel.swift`), `InputEditorSheet.init`, `FileDrop.swift`, `APIFunctions.swift` addinput.
2. **Fit / Fill / Stretch + separate X/Y zoom** (LED walls, non-16:9 sources). Input ⚙ › Position: "화면 맞춤" 맞추기 · 꽉 채우기 (잘림) · 늘리기, toggle "가로·세로 줌 따로" (sliders show effective zoom = `zoom × zoomX/Y`; relinking keeps the horizontal size).
   - Model: `VideoAdjust.fitMode` (0 fit, 1 fill, 2 stretch), `zoomX`, `zoomY` (default 1; old projects decode unchanged).
   - Render: `LayerParams` gained `zoomX, zoomY, fitMode` **appended at the end** in both `MetalMixer.swift` and `Mixer.metal` (layouts must stay identical). New `fitUVMode()`; `sampleLayer` uses `float2` zoom. vMix Layers boxes reset these (a layer box keeps its own fit/fill).
   - Position overlay (`PositionEditor.swift`) mirrors the same math.
3. **Quit with a sheet open** (bug since 2.0.5). With any sheet attached, AppKit ignored `NSApp.terminate`. Now `ProjectIO.requestQuit()` (HongMixApp.swift): if a sheet is open → the usual "outputs running?" alert, autosave, `engine.shutdown()`, `mc_web_shutdown()`, `exit(0)`; otherwise normal terminate. Wired to: menu (`CommandGroup(replacing: .appTermination)` "HongMix 종료" ⌘Q), the Quit Apple Event (Dock / AppleScript), SIGTERM, and a local keyDown monitor for ⌘Q (a focused text field in a sheet swallowed the key equivalent).
4. **Mac sleep / lid closed isn't counted as drops.** `SwitcherEngine.watchSystemSleep()`: `NSWorkspace.willSleep/didWake`; render loop doesn't count lateness while asleep and for 5 s after wake (clock resynced). On wake: message "⚠︎ 맥이 잠자기에 들어갔다 깨어났습니다 (덮개 닫힘) — N초 동안 방송·녹화가 멈췄습니다" (lid state from IOKit `AppleClamshellState` at sleep time), alert sound, Black Box kind `.systemSleep` ("맥 잠자기"). Background: a user saw Drop 168 — 166 came from closing the MacBook lid on battery (system log `Clamshell Sleep`); screen-off alone causes no drops (tested).
5. **Stream not connected → orange blinking.** While a stream output is running but its state ≠ RUNNING (connecting/reconnecting/error), the STREAM button blinks orange with "연결 안 됨" (`BlinkingOrangeLabel`, ContentView.swift) and that output's Stop button in the stream list blinks too (OutputsSheet.swift). Back to red once connected. Retry logic unchanged.

## 4. Verification (real app, API-driven; user project + defaults backed up and restored)

- Loop default: new video `loop="False"`; with the setting on `loop="True"`.
- Fit modes on Program with a 1440×1080 clip: fit = pillarbox, fill = full frame cropped top/bottom, stretch = full frame, ZoomX 1.333 = full width; XML `<position zoomX="1.333" zoomY="1.000">`.
- Quit with the Captions sheet open: ⌘Q (real key event), menu item, AppleScript quit, SIGTERM — all exit in ~1 s; ⌘Q without a sheet also OK.
- Build compiles; `test-core.sh` not re-run (no C changes).
- **Not tested**: real sleep/lid (would sleep the test Mac), orange stream state on screen (must not connect to real destinations). Both are small, but check them on first use.

## 5. API additions

`SetZoomX`, `SetZoomY` (Input, Value = effective zoom, vMix-compatible), `SetFitMode` / `SetPositionFit` (Input, Value=`fit|fill|stretch`). `SetZoom` now also resets X/Y to proportional. XML `<position zoomX/zoomY>` reports the effective axis zoom.

## 6. Release-note bullets (KO / EN)

- 새 영상은 기본으로 루프 없이 들어갑니다 (설정 › 일반에서 변경) / New videos no longer loop by default (Settings › General).
- 화면 맞춤: 맞추기 · 꽉 채우기 · 늘리기, 가로·세로 줌 따로 — LED 와이드 화면용 / Fit · Fill · Stretch and separate horizontal/vertical zoom for wide LED walls.
- 설정 창이 열려 있어도 종료됩니다 / Quit works while a settings window is open.
- 맥 잠자기(덮개 닫힘)는 드롭으로 세지 않고 경고로 알려 줍니다 / Mac sleep (lid closed) is reported as a warning, not as dropped frames.
- 송출이 연결되지 않으면 STREAM 버튼이 주황으로 깜빡입니다 / STREAM blinks orange while a stream isn't connected.

## 7. Known / open

- App is not notarized → "열지 않음" on first launch for testers (README note, or Apple Developer ID + notarization).
- Still open from earlier: captions with real meeting audio, background removal with a live camera, second monitor, PTZ/DeckLink/MIDI hardware.
- Main-window SwiftUI layout cost (seen in samples) not investigated.

## 8. Working rules from the user

- UI mockup and approval before UI changes. New build number every build; Desktop copy `HongMix <ver>.app`; deliver DMG (+PKG).
- Korean + English UI (`L("한국어")`, insert lines into `en.json`, never re-serialize).
- Tests must not touch the user's project: back up `last-session.bmix` and `defaults export com.hongseunghoon.HongMix`, restore after; only operate the app when the user is idle and not on air; never connect to real stream destinations.
- Reply to the user in Korean, in their casual style when drafting messages for testers.
