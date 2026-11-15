# HongMix 2.2.4 — handoff (Claude → GPT)

Date: 2026-11-15 · Mac: Apple M1 Max, macOS 27.3 · Repo: local `main`, last commit `975371a` = v2.2.3 (published by GPT)

**Publish 2.2.4** — the phone web remote (port 8088) rebuilt: thumbnails, audio mixer, title editing, status bar, safer stream / record buttons, KO / EN, and a view-only camera tally that stays awake. Everything below is **uncommitted** on top of `975371a`.

## 1. State

| What | Value |
|---|---|
| Version | `Resources/Info.plist` **2.2.4**, build **131** (129–130 were test builds) |
| Installers | `build/dist/HongMix-2.2.4.dmg` / `.pkg`, ad-hoc signed (`SIGN_ID="-"`) |
| SHA-256 | DMG `ae2c4b08099b74b70f04f76d3d9ac158862f901da41198df787fbdc82e37c930` · PKG `da1b3955c1f48ce912e3cffb643c554ec60cf155c4a5bcf8565a5d2f5d039e8a` (`build/dist/SHA256.txt`) |
| Copy for the user | `~/Desktop/HongMix/HongMix 2.2.4 배포/` (DMG, PKG, SHA256.txt, `screenshots/`, `test-results/`) |
| Screenshots | `docs/screenshots/2.2.4/` — `ko-05…08` and `en-05…08` (switcher, audio, title, tally; phone size). Synthetic test patterns only, no people / addresses |
| Test results | `docs/test-results/2.2.4/web-remote-tests.md`, `load-test.py` |

Changed files: `Sources/App/Engine/WebRemote.swift` (**new** — pages, JSON states), `Sources/App/Engine/ControlAPI.swift` (routes, tally without password, old pages removed), `Sources/App/Engine/Titles.swift` (`countdownStatus`), `Sources/App/UI/OutputsSheet.swift` (help text), `Resources/en.json` (+30), `Resources/Info.plist`, `docs/FUNCTIONS.md` (new "웹 페이지" section).

## 2. How to publish
1. Use the DMG/PKG as is (if you rebuild: build **132**). `test-core.sh` PASS, `check-i18n.py` PASS, `hdiutil verify` VALID.
2. Commit as `Seunghoon Hong <176268839+HongMix@users.noreply.github.com>`. New: `Sources/App/Engine/WebRemote.swift`, `docs/HANDOFF-2.2.4.md`, `docs/screenshots/2.2.4/*`, `docs/test-results/2.2.4/*`. Never add `HongMIX-signing/`, `build/`, or `docs/screenshots/2.0.9/*` (old untracked leftovers).
3. Release notes `docs/RELEASE-NOTES-2.2.4.md` / `.ko.md` / `-GITHUB.md` from §5. **KO notes use `ko-05…08`, EN notes / GitHub release use `en-05…08` — never mix.** US spelling; read EN against KO once. README "Latest update"; manuals (web remote section, tally without password).
4. `gh release create v2.2.4 --repo HongMix/HongMix --latest`, same asset set as v2.2.3.

## 3. What changed (all served by the HTTP API on 8088; remote control must be on — Settings › Network)

### `/` — web remote (phone first, 3 tabs; replaces the old single page)
- **Status bar** (always visible): ● LIVE h:mm:ss / ● REC h:mm:ss (longest running stream / record output), format, dropped frames (`droppedTicks`), one item per SRT input: `SRT n · RTT ms · loss %` (+ "dropped packets N" in the last 30 s); green / yellow (> 1 % loss) / red (disconnected or drops).
- **Switcher**: input tiles with thumbnails (`/thumb`, refreshed every 4 s, 3 columns on a phone); tap = Preview (and selects the tile), hold 0.6 s = `CutDirect`. CUT / AUTO / FTB row sticks to the bottom of the screen while scrolling. Transition effect + duration (`SetTransitionEffect1` / `SetTransitionDuration1`; AUTO = `Transition1`). T-bar (`SetFader`, throttled 60 ms, sends 255 once at the end). Overlay 1–4 for the selected input (`OverlayInputNIn/Out`). Media Restart / Play / Pause / Loop for the selected input. **STREAM / REC: tap starts; stopping needs a 1-second hold** (red bar fills; a short press shows "To stop, press and hold for 1 second").
- **Audio**: master + every input with audio (not color / image / title): slider (`SetVolume` / `SetMasterVolume`, throttled 80 ms), M = mute (`AudioOn/Off`, `MasterAudioOn/Off`), level meter (−60…0 dB, green / yellow > −9 / red > −3). Countdown of any title with a countdown field: big time, Start / Pause / Stop / −1 min / +1 min (`StartCountdown`, `PauseCountdown`, `StopCountdown`, `AdjustCountdown ±60`). Polls every 0.3 s on this tab (1 s otherwise).
- **Title**: pick a title input; its plain / ticker text fields as text boxes. Typing does not go on air — **Apply** sends `SetText` per changed field; Revert. While unapplied the page doesn't overwrite the boxes ("You have changes that aren't applied yet"). Presets ◀ n / N ▶, IN / OUT (`TitleBeginAnimation`), Overlay 1 in / out.
- Language: KO / EN from the app language (`L()` per request; strings in `WebRemote.remotePage()`).
- State: new `/remote.json` (`WebRemote.remoteState`) instead of parsing the full vMix XML. No file paths, addresses, keys.

### `/tally` — camera tally
- **View-only and served without the HTTP password** (`WebRemote.publicPaths`: `/tally`, `/tally.json`, `/tally.txt`) — IP rules and the cross-site block still apply. Camera operators no longer get a page that can switch; the remote and API still ask for the password. Thumbnails in the picker only when no password is set (`/thumb` would trigger a password prompt).
- **Screen stays on**: the Wake Lock API only works on https / localhost, and phones open `http://<Mac IP>:8088` — so the old code never kept the screen on. Now: Wake Lock where available, else a muted inline 2-s 64×64 H.264 clip (data URI, 1.6 KB) plays in a loop (NoSleep technique); if the browser blocks autoplay, "Tap once to keep the screen on". Re-armed when the page becomes visible again.
- New `/tally.json` (numbers, names, 0 / 1 / 2) instead of the full XML; picker built once (was rebuilt with fresh thumbnails every 250 ms).
- Settings › Network help text now says the tally opens without the password.

## 4. Verification
See `docs/test-results/2.2.4/web-remote-tests.md`: every button tested against the running app (state checked through `/remote.json`), password / cross-site rules, KO / EN. 3-minute load with 7 busy clients while streaming + recording: **0 dropped frames**, render worst 4.8 ms, CPU about +10 %.
Found and fixed while testing: T-bar to the end sent 255 twice → the second call left the T-bar at the end (build 129).
**Not verifiable by Claude:** real phones (iOS Safari / Android Chrome) — touch hold, keep-awake on the tally over plain http, Basic-auth prompt on the phone. The user checks these.

## 5. Release-note bullets (KO / EN)
- **휴대폰 웹 리모트 새 단장** — 입력 썸네일, 탭 = 프리뷰·길게 = 바로 컷, 전환 효과·T-바, 오버레이 1~4, 미디어 재생 / **Web remote rebuilt for phones** — input thumbnails, tap for Preview or hold to cut, transition effect and T-bar, overlays 1–4, media playback.
- **오디오 믹서와 카운트다운** — 입력별 볼륨·음소거·레벨 미터, 마스터, 카운트다운 조작 / **Audio mixer and countdown** — per-input volume, mute and meters, master, countdown controls.
- **타이틀 글자를 휴대폰에서 수정** — 고친 뒤 '적용'을 눌러야 화면에 나감 / **Edit title text from your phone** — changes go on air only when you tap Apply.
- **상태 표시줄** — 송출·녹화 시간, 드롭 프레임, SRT 상태 / **Status bar** — streaming and recording time, dropped frames, SRT link health.
- **송출·녹화 실수 방지** — 끌 때는 1초 길게 누르기 / **No accidental stops** — stopping a stream or recording takes a 1-second hold.
- **카메라 탈리는 보기 전용, 비밀번호 없이 열림, 화면 꺼짐 방지 보완** / **Camera tally is view-only**, opens without the password, and keeps the phone screen on.
- **웹 페이지 한국어·영어 지원** / **Web pages in Korean and English** (follow the app language).

## 6. Known / open
- Overlays 5–8 exist in the engine (8 channels) but the remote shows 1–4 (vMix habit).
- Transition presets on the remote change transition button 1 (the same one the app's AUTO uses).
- Working rules: Korean replies; new build number every build; every improvement changes the last version digit (user picks it); KO + EN complete (append to `en.json`); tests never touch the user's project.
