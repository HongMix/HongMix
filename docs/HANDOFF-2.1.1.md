# HongMix 2.1.1 — handoff (Claude → GPT)

Date: 2026-11-11 · Mac: Apple M1 Max, macOS 27.3 · Repo: local `main` checkout (last commit `50f71c3` = v2.1.0 release)

**GPT publishes to GitHub.** 2.1.1 is **uncommitted** in the working tree: 12 modified files (+343/−20), 7 new source/resource files, 1 new script, new screenshots in `docs/screenshots/2.1.1/`. The untracked `docs/screenshots/2.0.9/*.png` are left over from 2.0.9 and are not part of 2.1.1.

## 1. State

| What | Value |
|---|---|
| Version | `Resources/Info.plist` 2.1.1, public build **103** (100–102 were internal steps) |
| Public installers | `build/dist/HongMix-2.1.1.dmg` / `.pkg`, ad-hoc signed |
| Installed test copy | v2.1.1 was tested locally before the public build |
| Screenshots (KO/EN) | `docs/screenshots/2.1.1/` — list in §8 |

## 2. How to publish

1. Bump build to 103, then `SIGN_ID="-" bash scripts/make-dmg.sh` (public builds are ad-hoc signed).
2. `hdiutil verify`, `codesign -dvv` → `Signature=adhoc`. Check `Contents/Resources/HongMix Focus.shortcut` is in the app.
3. `bash scripts/test-core.sh` (no C core changes in 2.1.1).
4. Commit as `Seunghoon Hong <176268839+HongMix@users.noreply.github.com>`; never add `HongMIX-signing/` or `build/`. Add the new files: `Sources/App/Engine/FocusGuard.swift`, `SystemCheck.swift`, `Sources/App/UI/DisplayMap.swift`, `SafetyChips.swift`, `StartupCheckView.swift`, `UISnapshots.swift`, `Resources/HongMix Focus.shortcut`, `scripts/make-focus-shortcut.py`, `docs/screenshots/2.1.1/*`.
5. Release notes `docs/RELEASE-NOTES-2.1.1.md` / `.ko.md` / `-GITHUB.md` from §7, README highlights with the screenshots in §8.
6. `gh release create v2.1.1 --repo HongMix/HongMix --latest`, same asset set as v2.1.0.
7. Manuals + `docs/FUNCTIONS.md`: features in §3, API in §5.

## 3. What's new

### 3.1 Do Not Disturb while HongMix runs (`FocusGuard.swift`)
Why (user's words for the UI): during a show a call, message or notification window can take the keyboard, mouse or Companion control away, so cuts/transitions stop working.
- macOS has no public API to switch Focus. HongMix ships a Shortcuts shortcut **"HongMix Focus"** (`Resources/HongMix Focus.shortcut`, built by `scripts/make-focus-shortcut.py`) and runs it with `/usr/bin/shortcuts run`. Input text `on` / `off` / anything → output = current Focus name ("" = none).
- Launch: shortcut missing → approval sheet (승인 / 나중에) explaining why; 승인 opens the shortcut in Shortcuts ("단축어 추가"), HongMix watches `shortcuts list` (2 s × 90). Not approved → asked again every launch (in the current app language). Installed → DND on automatically (setting), a one-time info sheet the first time.
- Quit (menu, ⌘Q, Dock, SIGTERM): DND off again, only if HongMix turned it on (setting).
- Top bar chip next to ⚙ (`SafetyChips.swift` `FocusChip`): orange = on, gray = off, click toggles; polls every 30 s so Control Center changes show.
- Settings › General › "방송 안전" (`AboutView.swift`): auto on, off at quit, shortcut status + "승인…" button.
- All alerts are **sheets** (`beginSheetModal`), never `runModal`: an app-modal alert blocked the main queue and with it the HTTP/TCP API (Companion) — found and fixed during testing.
- **Shortcut signing**: the bundled `.shortcut` is signed (`shortcuts sign --mode anyone`) with the Apple ID on the developer Mac. To regenerate: see the header of `scripts/make-focus-shortcut.py`.
- **Bug found in testing and fixed**: the first shortcut named the mode with `DisplayString "Do Not Disturb"`; on a Korean Mac Shortcuts failed with "이 기기에 'Do Not Disturb' 집중 모드가 존재하지 않기 때문에…". It now uses only `Identifier com.apple.donotdisturb.mode.default` (works on Korean macOS; output "방해금지 모드").

### 3.2 First-launch language (`Localization.swift`)
First launch: Korean if any of the Mac's preferred languages is Korean, otherwise English. Afterwards the last saved language (`appLanguage`).

### 3.3 Display sleep prevention (`SwitcherEngine.swift`)
The engine's `beginActivity` now also has `.idleDisplaySleepDisabled` (`pmset -g assertions` shows `PreventUserIdleDisplaySleep "HongMix live production"`).

### 3.4 Keyboard-control-lost banner (`SafetyChips.swift` `ControlFocusBanner`)
While something is live (stream/record/external output, fullscreen display, monitor outputs) and HongMix is not the active app: orange bar under the top bar "키보드 제어가 다른 앱(Finder)에 있습니다 — HongMix 단축키가 동작하지 않습니다. 누르면 돌아옵니다." Click → HongMix active.

### 3.5 Display output: desktop pin + reconnect (`FullscreenOutput.swift`)
- Display ⚙ › "데스크탑": **이 모니터에 항상 고정** (default; every desktop/Space of that monitor, above other windows) / **지금 데스크탑에서만 보기** (only the Space it was opened on). UserDefaults `fullscreenPin`.
- The chosen monitor is remembered by vendor/model/serial (`fullscreenDisplayKey`), so it is found again after replugging (display IDs change). Monitor unplugged → output closes with a message; plugged back → reopens automatically ("풀스크린 디스플레이가 다시 연결되어 출력을 다시 열었습니다").
- Fixed in testing: after replugging the Display picker was blank (stale display ID) — `targetScreen()` now follows the new ID.
- Fixed after user feedback (build 102): with "지금 데스크탑에서만 보기" the window was at `.normal` level, so that monitor's macOS menu bar was drawn over the top of the picture. Both options now use `.screenSaver` level on another monitor; "this desktop only" comes from the collection behaviour (`.managed`), not the level. Same in `DisplayMap` monitor outputs. Verified on the iPad: no menu bar, output gone on the other desktop and back on its own. (The orange microphone-in-use dot is drawn by macOS and cannot be hidden.)

### 3.6 Per-monitor outputs (`DisplayMap.swift`)
Display ⚙ › "모니터별 출력": one row per connected monitor, choose a source (Output/Preview/buses/any input) and the desktop pin. Up to 8 (`SwitcherEngine.displaySlotCount`, `displaySources` / `displaySlots`; duplicate sources are rendered once per tick). Monitors remembered by vendor-model-serial (`#n` for identical twins without serial), saved in UserDefaults `displayMap`; unplugged assignments are listed in orange as waiting and come back on replug. The switcher's own screen and the fullscreen-output screen are disabled. "모니터 번호 표시" shows a big number on every screen for 3 s.

### 3.7 Pre-show check (`SystemCheck.swift`, `StartupCheckView.swift`)
Window after launch (and menu HongMix › "시작 전 점검…", API `StartupCheck`):
- Mac: model, chip, memory, macOS, P/E cores, GPU cores, Neural Engine; donuts CPU / GPU / memory free / disk free / battery; power, DND, thermal.
- Warnings bar: no power adapter, battery < 30 %, low recording-disk space, memory < 10 % free, Mac hot, Ethernet cable unplugged, upload too slow for the stream bitrate, "Displays have separate Spaces" off.
- Network: every interface with assigned IP and link speed; internal networks show "인터넷 연결 안 됨"; Ethernet with no cable "케이블 연결 안 됨"; per-interface speed test (Cloudflare, `NWConnection` bound to the interface, 4 streams, stops when steady, max 5 s each); hotspots (`isExpensive`) skipped with a small KO/EN note; public IP; stream bitrate vs upload.
- Remote: Web API / Companion (TCP 8099) addresses and status. Devices: PTZ, monitors, mic permission, separate Spaces.
- Footer: "실행할 때마다 보기", "인터넷 속도 측정" (also in Settings › General › 방송 안전).

### 3.8 Live captions translation fix (`Captions.swift`)
Testing showed translation never appeared while someone kept talking: every recogniser revision (several per second) cancelled the running translation (~1–2 s). Now the running translation finishes and is shown, then the newest text is translated; one `TranslationSession` is reused per language pair (≈0.9 s per sentence instead of ≈1.8 s).

## 4. Verification (real app on the user's Mac, API + screenshots; user project + defaults backed up and restored)

| Item | Result |
|---|---|
| DND shortcut on/off/status via CLI | OK after the Identifier fix (§3.1) |
| DND on at launch / off at quit / top-bar toggle (orange ↔ gray) | OK |
| Approval sheet KO/EN, API still answers while it is open | OK |
| Display sleep assertion | OK |
| Pre-show check KO/EN, speed test Wi-Fi 445/408 Mbps 8 ms in ~3 s, USB LAN adapter without cable shown as "케이블 연결 안 됨" | OK |
| Banner when Finder is active with fullscreen output on; click returns to HongMix | OK |
| Monitor outputs on 2nd screen (iPad Sidecar 1464×1080), identify monitors | OK |
| "항상 고정" stays when switching that monitor's desktop; "지금 데스크탑에서만" disappears on another desktop and is back on its own | OK |
| Unplug/replug (Sidecar disconnect/connect, display ID 12→14→15): monitor output and fullscreen output reopen on the same monitor | OK |
| Captions: English recognition, EN→KO, KO→EN translation | OK after §3.8 fix |
| Build compiles, DMG verify VALID | OK |

Not tested: a real HDMI/USB-C monitor (Sidecar was used as the second monitor), 3+ monitors, a hotspot connection, Mac without Korean language (first-launch English).

## 5. API additions

| Function | Value |
|---|---|
| `SetMonitorOutput` / `MonitorOutput` | `n[,Output|Preview|Clean|MultiView|Off|input]` (1-based monitor; refuses the switcher's screen) |
| `MonitorOutputOff` | `n` |
| `IdentifyMonitors` | — |
| `DoNotDisturbOn` / `DoNotDisturbOff` / `DoNotDisturbOnOff` | — |
| `StartupCheck` / `ShowStartupCheck` | — |
| Test hooks: `DismissSheet` (1|2), `ShowFocusApproval`, `SnapshotAllWindows` (folder), `SnapshotView` (name,path) | for UI tests / screenshots |

## 6. Known / open

- Captions (existing behaviour, not changed): the recogniser's interim text sometimes shows doubled word endings for a moment ("planan", "programgram") before it is corrected; the translation line translates the newest part of the text, so it can be a sentence fragment for a moment.
- Calls from favourites / repeated calls can still ring in DND (macOS rule) — the info sheet tells the user where to turn this off.
- App is not notarized (README note from 2.1.0 still applies).

## 7. Release-note bullets (KO / EN)

- 방송 중 방해 금지: HongMix를 켜면 맥의 방해 금지를 켜고 끄면 다시 끕니다. 오른쪽 위 버튼으로 켜고 끌 수 있습니다 (처음 한 번 단축어 승인) / Do Not Disturb during the show: on when HongMix opens, off when it quits, toggle in the top bar (approve a shortcut once).
- 시작 전 점검: 맥 상태, 모든 네트워크의 IP·링크·인터넷 속도, 원격 제어 주소, 장비를 한 화면에서 / Pre-show check: Mac status, every network's IP, link and internet speed, remote-control addresses and devices on one screen.
- 모니터별 출력: 연결된 모니터마다 다른 화면을 전체화면으로, 다시 꽂으면 자동 복구 / Per-monitor outputs: a different picture on each monitor, restored automatically when a cable is plugged back in.
- 디스플레이 출력: "이 모니터에 항상 고정" / "지금 데스크탑에서만 보기" / Display output: "Always on this display" or "This desktop only".
- 다른 앱이 키보드를 가져가면 주황 경고 줄 / Orange warning bar when another app takes the keyboard.
- 화면 꺼짐 방지, 처음 실행 언어 자동 선택 / Display stays awake; first-launch language follows the Mac.
- 실시간 자막 번역이 말하는 중에도 표시됩니다 / Live caption translation now shows while someone keeps talking.

## 8. Screenshots (`docs/screenshots/2.1.1/`)

| File | Shows |
|---|---|
| `ko-01-dnd-approval.png`, `en-01-dnd-approval.png` | Approval sheet for the DND shortcut |
| `ko-02-topbar-dnd-on.png`, `en-02-topbar-dnd-on.png`, `en-02b-topbar-dnd-off.png` | Top bar DND chip on (orange) / off (gray) |
| `ko-03-preshow-check.png`, `en-03-preshow-check.png` | Pre-show check window |
| `ko-04-display-monitor-outputs.png`, `en-04-display-monitor-outputs.png` | Display ⚙: desktop pin + monitor outputs |
| `ko-05-settings-show-safety.png`, `en-05-settings-show-safety.png` | Settings › General › Show safety |
| `ko-06-keyboard-lost-banner.png`, `en-06-keyboard-lost-banner.png` | Main window with the orange keyboard banner |
| `07-identify-monitors-macbook.png`, `07-identify-monitors-ipad.png` | "Identify monitors" on both screens |

The release screenshots have their local/public IP addresses redacted before publication.

## 9. Working rules from the user

- UI mockup and approval before UI changes. New build number every build; Desktop copy `HongMix <ver>.app`; deliver DMG (+PKG).
- Korean + English UI (`L("한국어")`, insert lines into `en.json`, never re-serialize).
- Tests must not touch the user's project: back up `last-session.bmix` and `defaults export com.hongseunghoon.HongMix`, restore after; never connect to real stream destinations.
- Reply to the user in Korean.
