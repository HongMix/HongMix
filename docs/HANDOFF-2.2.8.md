# HongMix 2.2.8 — handoff (Claude → GPT)

Date: 2026-11-15 · Repo: local `main`, last commit `ee4c900` = v2.2.5 (published)

**Publish 2.2.8.** v2.2.5 is already public. Builds 2.2.6 and 2.2.7 were not published separately; 2.2.8 contains both. Follow `docs/HANDOFF-2.2.5.md` §2 for the publish steps (using the files and numbers below). Feature details: `HANDOFF-2.2.6.md` (live PREVIEW/PROGRAM with quality choice) and this document (web-remote reliability and security). The 2.2.8 work is uncommitted on top of `ee4c900`.

## 1. State
| What | Value |
|---|---|
| Version | `Resources/Info.plist` **2.2.8**, build **141** (138–140 test builds; 2.2.7 = 138–139, renamed 2.2.8 by the user) |
| Installers | `build/dist/HongMix-2.2.8.dmg` / `.pkg`, ad-hoc signed |
| SHA-256 | DMG `0a89bef126df18bc115b0768f84e1c64a741a4763e4cc1c3fa11519bbe754931` · PKG `6a47bcddf7fdeb363f55f9d4ff7c2a79a8ab81efbdaad2f91c7ad94d09fba2f7` |
| Manual | `docs/manual/` (title 2.2.8) |
| Test results | `docs/test-results/2.2.8/` (+ 2.2.4–2.2.6) |
| Copy for the user | `~/Desktop/HongMix/HongMix 2.2.8 배포/` |
| User's Mac | `/Applications` has 2.2.6; the user installs 2.2.8 |

## 2. What changed in 2.2.8 — robustness of the web remote (independent code review + fixes)
| # | Problem found | Fix |
|---|---|---|
| 1 | A phone that leaves Wi-Fi without closing kept its live picture "attached" for minutes (frames waiting, encoder running) | `WebStream`: a viewer still busy after 8 s is force-closed (`forceCancel` — plain `cancel` waited to flush and kept the socket). Measured: dropped after 7.8 s |
| 2 | After a Wi-Fi drop the remote page could freeze on old state with no warning | every request gives up after 3 s (`AbortController`) → "Connection lost — reconnecting…" shows, polling continues |
| 3 | Tally polls overlapped on slow Wi-Fi → an old reply could flash the wrong light; a hung request never showed "lost" | one tally request at a time, 2-s timeout |
| 4 | Thumbnail JPEG encoding shared the HTTP queue → a CUT could wait behind pictures; the page loaded all tile pictures at once | thumbnails encode on their own queue; the page loads tile pictures 2 at a time |
| 5 | Unlimited distinct stream feeds/viewers from the LAN (load on GPU/main thread) | fps snapped to 2/8/15, width to 320/400/480/640/854; max 16 live pictures (503 above) |
| 6 | stream hub's engine reference written from the network queue per request | set once at startup on main |
| 7–8 | failed header send left the socket open; no engine → empty stream | closed in both cases |
| 9 | another web page on the same IP but a different port (`Sec-Fetch-Site: same-site`) could trigger commands with cached credentials | only `same-origin` (the page itself) or `none` (typed address, Companion, no header) pass |
| 11 | "This Mac only" still showed `http://<LAN IP>:8088` as the status, so phones were pointed at an address that refuses them (cause of the user's report) | status now `http://localhost:8088 · This Mac only` (or `· only these IPs` with an allow-list); orange hint under the picker; status refreshes when the mode or IP list changes |
| 10 | the request was read with a single receive (split headers → spurious errors); silent connections never closed | read until the end of headers (max 16 KB); a connection that sends nothing for 10 s is closed |

Files: `Sources/App/Engine/WebStream.swift`, `ControlAPI.swift`, `Sources/App/UI/OutputsSheet.swift` (hint, refresh), `Resources/en.json` (+2), `WebRemote.swift` (tally script), `WebRemotePage.swift`, `SwitcherEngine.swift` (one line), `Resources/Info.plist`, manuals (version), `docs/test-results/2.2.8/*`, this file.

## 3. Verification (synthetic test project, local SRT in/out, recording; user's project + settings backed up and restored byte-identical)
- Hardening checks (`docs/test-results/2.2.8/harden.py`): 10 / 10 PASS — fps snap, 17th viewer 503, connections released, stalled viewer dropped (7.8 s), split request, idle close (10.0 s), same-site 403, same-origin / none allowed, 0 dropped frames.
- Page on the virtual switcher (`docs/test-results/2.2.5/mock.py` + `suite.js`): desk 65 / iPad 65 / phone 66 — all PASS.
- Real app (`docs/test-results/2.2.5/verify-real-app.py`): 47 / 47 PASS.
- Soak (`docs/test-results/2.2.8/soak.py`): 2 remotes polling, 3 tallies, tile thumbnails, 4 live pictures reconnecting every 20–45 s, 1 stalled viewer, 2 command senders (switching, overlays, play/pause, volume, T-bar, title text, countdown), recording + SRT stream + SRT input running.
  - 2.2.8 (build 140), 10 min: **0 dropped frames**, render max 3.9 ms, memory 522–558 MB flat, threads 98–103 flat, 10,495 requests, 797 commands 0 failed, 89 stream sessions, 0 connections left at the end. (The ~200 request "errors" are the expected 404 thumbnails of the audio-only input.)
  - build 139, 6.5 min (ended when the user quit the test app): same picture, 0 dropped frames.
- **LAN check** (user report: "the web remote doesn't open on my iPhone / in Chrome"): at that moment the running HongMix was the *test* app in "This Mac only" mode, which refuses any non-loopback address — and its status line still showed the LAN URL. With the user's real setting ("Devices on the network") every page opens via the Mac's LAN address (`/`, `/remote.json`, `/tally`, `/tally.json`, `/thumb`, `/stream.mjpg` 200 / frames; Chrome at phone size: page + CUT work). In "This Mac only" the LAN address is refused (as designed).

## 4. Release-note bullets (add to 2.2.4–2.2.6)
- **불안정한 Wi-Fi에서도 웹 리모트가 멈추지 않음** — 끊기면 '연결 끊김'을 바로 표시하고 다시 연결, 사라진 휴대폰은 8초 안에 정리 / **Web remote holds up on shaky Wi-Fi** — shows "connection lost" right away and reconnects; a phone that vanished is cleaned up within 8 seconds.
- **탈리 불빛이 잠깐 이전 상태로 돌아가던 현상 수정** / **Fixed the tally light briefly flashing an old state on slow Wi-Fi.**
- **웹 화면이 송출에 주는 부담 제한** (실시간 화면 최대 16개, 썸네일은 별도 처리) / **Limits on what web viewers can cost the live output** (max 16 live pictures; thumbnails processed separately).
- **보안 강화** — 같은 Mac의 다른 웹 페이지가 HongMix에 명령을 보내는 것도 차단 / **Hardening** — other web pages on the same Mac can't send commands either.
- **"이 맥에서만"일 때 상태에 휴대폰용 주소 대신 `localhost · 이 맥에서만` 표시와 안내** / **"This Mac only" now says so in the status line (no LAN address that would refuse phones), with a hint.**
- **설명서: 휴대폰에서 웹 리모트가 안 열릴 때 확인 순서** / **Manual: step-by-step check when the web remote won't open on a phone.**
