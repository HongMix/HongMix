# HongMix 2.1.2 — handoff (Claude → GPT)

Date: 2026-11-12 · Mac: Apple M1 Max, macOS 27.3 · Repo: local `main` checkout (last commit `b5ba2fb` = v2.1.1 release)

**GPT publishes to GitHub.** 2.1.2 is **uncommitted** in the working tree: 19 modified files (+518/−18), 2 new source files, new screenshots in `docs/screenshots/2.1.2/`. The untracked `docs/screenshots/2.0.9/*.png` are still leftovers from 2.0.9 and are not part of 2.1.2.

## 1. State

| What | Value |
|---|---|
| Version | `Resources/Info.plist` 2.1.2, public build **109** (104–108 were internal test steps) |
| Public installers (already built) | `build/dist/HongMix-2.1.2.dmg` / `.pkg`, ad-hoc signed, LGPL FFmpeg |
| SHA-256 | DMG `3890af5c04c73afb6e31f1d7cc960f3e951662be64a13a314798f32fe1783cba` · PKG `ce5de29aba229dd89d9c5005371fb12dd1799ffb5e05f5cb362ce4b932c0c3ba` |
| Copy for the user | `~/Desktop/HongMix/HongMix 2.1.2 배포/` (same files) and `~/Desktop/HongMix 2.1.2.app` (installed from this DMG, tested) |
| Screenshots (KO/EN) | `docs/screenshots/2.1.2/` — list in §8 |

## 2. How to publish

1. **Use the DMG/PKG already in `build/dist/` (build 109)** — that exact build was tested. If you must rebuild, bump to **110** first, then `SIGN_ID="-" bash scripts/make-dmg.sh`.
2. Check: `hdiutil verify`, `codesign -dvv` → `Signature=adhoc`, `Contents/Resources/HongMix Focus.shortcut` present, version 2.1.2 (109).
3. `bash scripts/test-core.sh` — **C core changed** this time (`mc_output.c` CBR, `mc_core.h` new `cbr` field at the end of `mc_output_config`).
4. Commit as `Seunghoon Hong <176268839+HongMix@users.noreply.github.com>`; never add `HongMIX-signing/` or `build/`. Add the new files: `Sources/App/Engine/SystemHealth.swift`, `Sources/App/UI/InputMonitorWindow.swift`, `docs/screenshots/2.1.2/*`.
5. Release notes `docs/RELEASE-NOTES-2.1.2.md` / `.ko.md` / `-GITHUB.md` from §7 (**include the "why" paragraph for Mac cleanup**), README "Latest update" with the screenshots in §8.
6. `gh release create v2.1.2 --repo HongMix/HongMix --latest`, same asset set as v2.1.1 (DMG, PKG, manuals EN/KO, SHA256.txt, THIRD-PARTY-NOTICES.txt, screenshots).
7. Manuals + `docs/FUNCTIONS.md`: features in §3.

## 3. What's new

### 3.1 Layer media follows its parent (`SwitcherEngine.swift`)
User report (vMix habit): a video placed as a **layer** of an input didn't play when that input went to Program.
- Going to Program/overlay (cut or transition start) plays every visible layer's media (nested layers too), using each clip's own Auto Play.
- Leaving Program pauses/rewinds layer media by its own Auto Pause / Auto Restart — **unless it is still on air elsewhere**. Example: the same loop as a layer on cameras 1–3 keeps running across camera cuts, no restart.
- A layer switched on or added while the parent is on air starts at once. Countdown titles in a layer start too. Triggers of layer inputs are not fired (only the parent's).

### 3.2 Stream bitrate mode VBR / CBR (`OutputsSheet.swift`, `Outputs.swift`, `mc_output.c`, `mc_core.h`)
- Stream outputs (SRT and RTMP): Settings › Encoding › **Bitrate mode: VBR / CBR**. Default VBR = previous behaviour; existing projects unchanged.
- CBR: VideoToolbox `constant_bit_rate` (x264 `nal-hrd=cbr`), `rc_min_rate = rc_max_rate`; SRT/MPEG-TS also null-padded to a fixed `muxrate` ((video+audio) × 1.12).
- If the encoder refuses CBR on that Mac: same encoder as capped VBR, one orange message "CBR not supported — streaming as capped VBR".

### 3.3 Input thumbnails show the input as placed in Program (`MonitorView.swift`, `Mixer.metal` `tileFragment`, `SwitcherPanels.swift`)
- User report: with **Fill**, Preview/Program were filled but the input tile still showed the original — confusing.
- Tiles now use the same placement maths as Program (fit/fill/stretch, zoom, pan, crop; colour/key off in the tile). Small **FILL / STRETCH** tag when the fit mode isn't Fit. Layers were already composed into tiles.

### 3.4 Input monitor window (`InputMonitorWindow.swift`, tile button)
- User request: monitor icon on the input tile (right of Loop) opens that input large in its own resizable window (one per input), with audio meter and tally border.
- View only + Restart / Play-Pause — no Cut/Preview buttons (a stray click can't change the show). Closes when the input is removed; not reopened at launch.

### 3.5 Mac cleanup — symptom detection, one-click cleanup, auto cleanup (`SystemHealth.swift`, `SafetyChips.swift` `SystemHealthBanner`, `StartupCheckView.swift` `MacCleanupPanel`)
**Why (put this in the release notes):** during testing the HongMix window froze for 0.5–1.8 s every ~15 s while the output itself never dropped a frame. Cause: macOS's own Live Activities widget renderer (`WidgetRenderer_Activities`, iPhone Live Activities such as a delivery tracker) had been running 32 h and spiked to ~200 % CPU every few seconds, blocking the WindowServer — so every app's window stuttered. Restarting that macOS helper fixed it instantly (stalls 1303 ms → max 67 ms, monitor 59–61 fps). A broadcast Mac often runs for days without a reboot, so HongMix now detects this and fixes it without a restart.
- **Detection:** HongMix already measures its UI response every second. 3 stalls > 300 ms within a minute → it lists the processes using the CPU and shows an orange bar: "The Mac's display is slow — cause: Live Activities widget 196 % (output not affected)". WindowServer, kernel_task, coreaudiod, VT services and HongMix itself are never listed as causes.
- **Clean up** (bar and Pre-show check): restarts **only macOS widget helpers** (`WidgetRenderer*`, widget `.appex`, `chronod`) — launchd starts them again at once, no setting changes. Other apps (Adobe installer, Spotlight …) are listed, never closed. Then measures 10 s and says "Better" / "No change".
- **Auto cleanup** (off by default, for unattended 24 h shows): same cleanup when the symptom appears; each helper at most once per 30 min; every cleanup is written to the incident recorder (new kind "Mac cleanup").
- **Broadcast Mac setup (once):** iPhone Live Activities, desktop widgets, Spotlight exclusions for video/recording folders, automatic updates — each with "Open Settings". HongMix never changes them itself.
- No reboot advice (24 h operation was the user's explicit requirement).

### 3.6 On-air freeze fix + watchdog (`Inputs.swift`, `SwitcherEngine.swift`)
Found in the load test — **existing bug, release-relevant:** a clip without Loop that had reached its end stayed "finished" in the C thread; Play / Auto Play on a cut un-paused it, and the next position poll paused it again within 50 ms. Result: a frozen picture on air (4K clip frozen 115 s in the test) while output frame counters looked normal.
- Fix (vMix behaviour): Play / Auto Play on a finished clip restarts it; a 1 s grace stops the stale "finished" flag from re-pausing it.
- Watchdog for any other cause, for Program, overlays and their layer media: (1) Auto Play requested but still paused 0.5 s later → restart; (2) playing but position unchanged for 1.5 s (stuck decoder) → re-seek at the same position. Message bar + incident recorder. Operator-paused clips and clips that ended without Loop are left alone. 2.5 s grace after going live.

### 3.7 CPU / UI work reduction
- Titles not shown anywhere (Program, Preview, overlays, layers of those, Output 2–4 input/multiview, MultiCorder, monitor windows) redraw scrolling tickers at 6 fps (tile rate) instead of 30; back to full rate before the first on-air frame.
- All audio meters update in one Core Animation commit per tick (was one per meter).
- Transport bar (playhead/timecode) lives in its own hosting view.

### 3.8 Test hooks (`UISnapshots.swift`, API `SnapshotView`)
New names: `lang-en`, `lang-ko`, `cleanup`, `healthbanner`, `encoding`, `inputmonitor-<n>`. Used for the release screenshots.

## 4. Verification (real app on the user's Mac; project + defaults backed up)

| Test | Result |
|---|---|
| Layer media (code path) | Builds; cut between inputs sharing one layer loop keeps it running (logic checked; user to confirm in a real show) |
| Finished clip → Play / Cut to it | **Fixed**: restarts and runs (before: stayed paused) |
| Load: 29 inputs (15× 1080p60 H.264, 5× 4K59.94 H.264, 1× 10-bit 4:2:2 H.264) | Output drops **0** in every scenario, render avg 1.2–1.5 ms (max 19 ms once), program 4K 59.92–59.95 fps |
| 4K ↔ 10-bit cut ×10, 4K ↔ 4K fade ×8 | Program playing after **every** cut/fade (before the fix: paused/frozen) |
| CPU (HongMix, 10-core M1 Max) | 30–64 % average, peaks 93–118 % with 20 clips playing |
| Mac cleanup button | Restarted `WidgetRenderer_Activities`, incident logged; detection fired by itself on this Mac (orange bar seen in the main window) |
| UI stalls | 3–16 ms normally; 100–400 ms while the Live Activities widget is busy again (user's Live Activity still active) |
| DMG/PKG 109 | `codesign --verify --deep --strict` OK, ad-hoc, no `--enable-gpl`, shortcut + en.json present, installed and launched |

## 5. API additions
None public (CBR has no API yet). `SnapshotView` test names in §3.8.

## 6. Known / open
- CBR: builds and the C core test passes (`scripts/test-core.sh` PASS, VBR path), but a CBR stream was **not measured end-to-end** (no constant-rate check of an SRT capture yet). The fallback path (encoder refuses CBR → capped VBR + warning) is in place.
- Audio dropouts reported by the user are **not reproduced/diagnosed** yet: HongMix had no audio output device enabled during tests; input audio queues never under-ran. Needs the user's listening path.
- UI stalls remain while macOS's Live Activities renderer is busy; the real cure is turning iPhone Live Activities off (guide item).
- The Mac cleanup list shows any process ≥ 30 % CPU (e.g. MenuBarAgent 33 % in the screenshot) — informational only.
- Watchdog (2) uses the 0.05 s position resolution; at playback rates below ~0.03× it could re-seek needlessly.
- App is not notarized (unchanged).

## 7. Release-note bullets (KO / EN)

- 레이어 영상이 함께 재생: 입력을 출력으로 보내면 그 입력의 레이어 영상도 같이 재생되고, 빠지면 같이 멈춥니다. 같은 루프 영상을 여러 카메라에 레이어로 넣으면 카메라끼리 컷해도 끊기지 않습니다 / Layer media follows its input: it plays when the input goes on air and pauses when it leaves; the same loop layered on several cameras keeps running across camera cuts.
- 송출 비트레이트 VBR / CBR 선택 (SRT·RTMP). CBR은 SRT 전송량까지 일정하게 맞춥니다 / Stream bitrate mode VBR / CBR (SRT and RTMP); CBR also keeps the SRT transport rate constant.
- 입력 썸네일이 출력과 똑같이 보입니다 (꽉 채우기·늘리기·위치·자르기, FILL 표시) / Input thumbnails show the input exactly as placed in Program (fill, stretch, position, crop — with a FILL tag).
- 입력 크게 보기 창: 입력 칸의 모니터 버튼으로 그 입력만 따로 크게 (보기 전용) / Input monitor window: the tile's monitor button opens that input large in its own window (view only).
- **맥 정리** — 왜 필요한가: 맥을 며칠씩 켜 두면 macOS의 실시간 현황 위젯 같은 시스템 도우미가 꼬여 몇 초마다 화면 합성을 막을 수 있습니다. 이때 송출은 멀쩡해도 HongMix 화면(미리보기·출력 모니터)이 0.5~2초씩 멈춰 보입니다. 2.1.2는 이 증상을 감지해 원인을 알려 주고, "정리하기" 한 번으로 해당 macOS 위젯만 재시작합니다 (재부팅 불필요, 다른 앱은 끄지 않음). 24시간 무인 방송용 자동 정리 옵션과 방송용 맥 세팅 가이드도 있습니다 / **Mac cleanup** — why: on a Mac that runs for days, a macOS helper such as the Live Activities widget renderer can get stuck and block the WindowServer every few seconds. The output keeps running, but the HongMix window (preview/output monitors) freezes for 0.5–2 s. 2.1.2 detects this, names the cause and restarts just that macOS widget with one click (no reboot, no other apps closed). Optional auto cleanup for unattended 24 h shows and a one-time broadcast-Mac setup guide.
- 끝난 영상이 출력에서 멈춘 채 나가던 문제 수정 + 출력 영상 멈춤 감시 (자동 복구, 사고 기록) / Fixed a finished clip staying frozen on air when played or cut to again; new on-air freeze watchdog with automatic recovery and incident log.
- 출력에 안 쓰이는 자막 티커와 오디오 미터의 CPU 사용 감소 / Less CPU for unused title tickers and audio meters.

## 8. Screenshots (`docs/screenshots/2.1.2/`)

| File | Shows |
|---|---|
| `ko-01-mac-cleanup.png`, `en-01-mac-cleanup.png` | Pre-show check › Mac cleanup (clean up, auto cleanup, setup guide) |
| `ko-02-health-banner.png`, `en-02-health-banner.png` | Orange bar naming the cause (sample: Live Activities widget 196 %) |
| `ko-03-cbr-setting.png`, `en-03-cbr-setting.png` | Stream › Encoding › Bitrate mode VBR / CBR |
| `04-input-tile-fill-monitor-button.png` | Input tile with FILL tag and the new monitor button (no language text) |
| `ko-05-input-monitor-window.png`, `en-05-input-monitor-window.png` | Input monitor window |

No people, programme footage, IP addresses or stream keys (the SRT host in the CBR shot is the documentation address 203.0.113.10).

## 9. Working rules from the user
- UI mockup and approval before UI changes (the user waived it for §3.5). New build number every build; Desktop copy `HongMix <ver>.app`; deliver DMG (+PKG).
- Korean + English UI (`L("한국어")`, append lines to `en.json`, never re-serialize).
- Tests must not touch the user's project: back up `last-session.bmix` and `defaults export com.hongseunghoon.HongMix`, restore after; never connect to real stream destinations.
- Reply to the user in Korean.
