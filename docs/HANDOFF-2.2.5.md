# HongMix 2.2.5 — handoff (Claude → GPT)

Date: 2026-11-15 · Mac: Apple M1 Max, macOS 27.3 · Repo: local `main`, last commit `975371a` = v2.2.3 (published)

**Publish 2.2.5.** 2.2.4 was built (the first web remote rebuild, `docs/HANDOFF-2.2.4.md`) but **not published** — 2.2.5 replaces its web remote completely and contains everything else from 2.2.4 (tally without password, keep-awake, `/remote.json`, `/tally.json`). Also new: the **complete user manual in Korean and English with screenshots** (`docs/manual/`). Everything is **uncommitted** on top of `975371a`.

## 1. State

| What | Value |
|---|---|
| Version | `Resources/Info.plist` **2.2.5**, build **134** (132–133 were test builds; 129–131 = 2.2.4) |
| Installers | `build/dist/HongMix-2.2.5.dmg` / `.pkg`, ad-hoc signed |
| SHA-256 | DMG `af194a4ff52d13a0649f57f4287b31c9192ac52e696f76bd72cbd08a706cf56d` · PKG `65b3a7d265cd03c028ea85c2c1c254bd2ba2a9ebaaeb1398dacc75ece73bee78` (`build/dist/SHA256.txt`) |
| Manual | `docs/manual/HongMix-Manual.ko.md`, `docs/manual/HongMix-Manual.en.md`, `docs/manual/images/` (14 Korean `ko-*`, 14 English `en-*`) |
| Test results | `docs/test-results/2.2.5/` (+ `2.2.4/`) |
| Copy for the user | `~/Desktop/HongMix/HongMix 2.2.5 배포/` |
| User's Mac | `/Applications` has **2.2.4** (installed today); install the 2.2.5 PKG |

Changed / new files since `975371a`: `Sources/App/Engine/WebRemote.swift` (new: JSON states, tally page, `thumbBuffer`), `Sources/App/Engine/WebRemotePage.swift` (new: the remote page), `Sources/App/Engine/ControlAPI.swift` (routes, tally without password, thumbnails encoded off the main thread, `source=program|preview`), `Sources/App/Engine/Titles.swift` (`countdownStatus`), `Sources/App/UI/OutputsSheet.swift` (help text), `Sources/App/UI/UISnapshots.swift` (`new-<kind>` hook for manual screenshots), `scripts/check-i18n.py` (also checks `WL("…")`), `Resources/en.json` (+66), `Resources/Info.plist`, `docs/FUNCTIONS.md`, docs below.

## 2. How to publish
1. Use the DMG/PKG as is (if you rebuild: build **135**). `test-core.sh` PASS, `check-i18n.py` PASS, `hdiutil verify` VALID.
2. Commit as `Seunghoon Hong <176268839+HongMix@users.noreply.github.com>`. Add: the sources above, `docs/manual/**`, `docs/HANDOFF-2.2.4.md`, `docs/HANDOFF-2.2.5.md`, `docs/screenshots/2.2.4/*`, `docs/test-results/2.2.4/*`, `docs/test-results/2.2.5/*`. **Never add** `HongMIX-signing/`, `build/`, `docs/screenshots/2.0.9/*`.
3. Release notes `docs/RELEASE-NOTES-2.2.5.md` / `.ko.md` / `-GITHUB.md` from §5. Images: **KO notes `docs/manual/images/ko-09…12`, EN notes / GitHub release `en-09…12` — never mix.** US spelling.
4. README (KO / EN): "Latest update" + a link to the manual (`docs/manual/HongMix-Manual.ko.md` / `.en.md`). The old `docs/HongMix-설명서.txt` / `HongMix-Manual-EN.txt` can stay for the installer folder; the Markdown manual is the full one.
5. `gh release create v2.2.5 --repo HongMix/HongMix --latest`, same asset set as before.

## 3. Web remote 2.2.5 — "the switcher moved into a browser"
User feedback on 2.2.4 (tested on their phone): unclear which screen is on air, overlay buttons applied to a "selected input" that differed from Preview, play/pause needed a selection first, no explanation, no way to see English, **holding STREAM 1 s stopped and then restarted the stream** (after the hold the poll already said "off", so the click that follows the release started it again), wanted the same text and layout as the app and iPad / laptop support.

Now (`WebRemotePage.swift`):
- **Same layout and labels as the app**: PREVIEW (green) · center column (Quick Play, CUT, 4 transition buttons with effect ▾ and ms, OVERLAY 1–8 bank in the app's channel colors, T-BAR, FTB) · PROGRAM (red; the mixed output incl. overlays, `/thumb?source=program`; playback bar with ⏮ ▶/❚❚ and seek for media on air) · input tiles like the app's (`⏮ ▶/❚❚ Cut Loop`, `🔊 1 2 3 4`, `5 6 7 8`; title tiles `Cut Edit`) · Audio Mixer / Titles panel · REC · STREAM · EXTERNAL bar. Top: format, FPS, Render, Max, Drop, SRT link like the app's status bar.
- **No selection concept, no long-press**: tap tile = Preview; **Cut** on a tile = straight to Program; **1–8** on a tile = that input in / out of that overlay (lit in the channel color while on air, dim when it is the saved input); center bank = `OverlayInputNLast` / `Out`.
- **REC / STREAM / EXTERNAL always ask** (start: green button, stop: red button with the running time); EXTERNAL / outputs that aren't set up show a hint instead.
- **Layouts by width** (re-evaluated on rotate): ≥ 1100 px desk (laptop, desktop, iPad landscape) = app layout with the side panel; 700–1099 px tab (iPad portrait) = PREVIEW | PROGRAM, transition strip, 4-col tiles, Audio / Title via bottom tabs; < 700 px phone = small monitors, CUT · transition 1 · FTB strip, 2-col tiles, bottom tabs Switcher / Audio / Title / More (bank, 4 transitions, T-Bar). Touch devices (`pointer: coarse`) get 40-px buttons.
- **한 / EN** switch on the page (per device, default = app language); `?` help (10 lines). The tally page has the same switch. Strings: `WL("한국어")` gives `[KO, EN]` from `en.json`; `check-i18n.py` checks them.
- Server: `/remote.json` adds `bank` (on + saved input per channel), 4 `trans`, `pos`/`dur`, `fps`, `renderMs`/`renderMax`, `stream`/`record`/`external` `{on, sec, has}`; `/thumb` JPEG encoding moved off the main thread; max 960 px.

## 4. Manual (`docs/manual/`)
16 chapters, same structure in both languages: install, screen tour, adding inputs (camera, files, SRT/RTMP/UDP, NDI, screen, browser, titles…), switching, overlays, Position / Layers, Audio Mixer, Titles, outputs (record, stream, EXTERNAL, DISPLAY), replay & captions, broadcast safety (Pre-show Check, Do Not Disturb, failover, incident log), web remote & tally, Companion / API, settings, troubleshooting, requirements. Images captured from the real app (synthetic test patterns only) in each language.
**Privacy:** device name, LAN IP and the public IP visible in some captures were replaced with documentation values (`iPhone Camera`, `192.0.2.10`, `203.0.113.5`) — `ko/en-02`, `-08`, `-13`, and the main-window status text in `-01` blanked. Keep it that way if you recapture.
**Please check before publishing** (the writer could not confirm these in code; plain-text manual was the source): "Visible in Mixer" / "+ Bus" labels; DISPLAY per-monitor source names; recording containers and split-every-N-minutes; Color Adjust controls; title template count/families; Desktop Capture menu path; Replay button labels; caption style names; AI Upscaling minimum macOS. Companion "feedback over TCP 8099" is general vMix-module behavior.

## 5. Release-note bullets (KO / EN)
- **웹 리모트 = 브라우저 속 스위처** — 앱과 같은 PREVIEW · 전환 열 · PROGRAM · 입력 타일 · 오디오 믹서 배치와 문구 / **Web remote = the switcher in a browser** — the app's PREVIEW, transition column, PROGRAM, input tiles and Audio Mixer, same labels.
- **노트북·아이패드·휴대폰에 맞춰 배치가 바뀜** — 아이패드 가로는 앱과 같은 화면, 세로·휴대폰은 아래 탭 / **Adapts to laptop, iPad and phone** — iPad landscape looks like the app; portrait and phones use bottom tabs.
- **타일마다 Cut·재생·오버레이 1–8 버튼, PROGRAM에 재생 막대** / **Cut, playback and overlay 1–8 on every tile; playback bar under PROGRAM.**
- **송출·녹화·EXTERNAL은 확인 창** (길게 누르면 다시 켜지던 문제 해결) / **Stream, record and EXTERNAL ask for confirmation** (fixes a stream restarting after a long press).
- **한국어·영어 전환과 사용법(?)** / **Korean / English switch and built-in help.**
- **카메라 탈리: 보기 전용, 비밀번호 없이, 화면 꺼짐 방지** (2.2.4) / **Camera tally: view-only, no password, keeps the screen on.**
- **전체 사용 설명서 (한국어·영어, 화면 캡처 포함)** / **Full user manual in Korean and English with screenshots.**

## 6. Verification
`docs/test-results/2.2.5/web-remote-tests.md`: 196 page checks on a virtual switcher (desk 65, iPad 65, phone 66 — all PASS; phone width bug found and fixed) and 47 checks against the real app (all PASS, 0 dropped frames). Not tested: real phones / iPad.

## 7. Known / open
- Phone top bar wraps to two lines when SRT links are shown (fine, not cut off).
- The page polls (0.4 s desk, 0.7 s otherwise) — no push; 7 busy clients cost ~10 % CPU (2.2.4 load test).
- Working rules: Korean replies; new build number every build; every improvement changes the last digit (user picks it); KO + EN complete; tests never touch the user's project.
