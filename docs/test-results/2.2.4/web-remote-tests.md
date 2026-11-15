# HongMix 2.2.4 — web remote test results (2026-11-15, build 129/130, Apple M1 Max)

Synthetic test project (test-pattern clips, local SRT input from ffmpeg on 127.0.0.1, record to a temp folder,
SRT stream output to a local ffmpeg listener). The user's project and settings were backed up and restored byte-identical.
Browser: Chromium at phone size 390×844, same machine (127.0.0.1).

| Test | Result |
|---|---|
| Tap tile → Preview; hold 0.6 s → cut straight to Program | PASS (preview 4 / then active 2) |
| CUT, AUTO (Transition1 with the chosen effect / duration), FTB on / off | PASS |
| Transition effect Wipe + 1000 ms from the selects | PASS (`SetTransitionEffect1/Duration1`) |
| T-bar drag 0 → 128 (manual mix 0.502) → 255 completes, slider back to 0; twice in a row | PASS (build 129 sent 255 twice → T-bar stuck at the end; fixed) |
| Overlay 1 in / out for the selected input, button shows "1 · 8" in red | PASS |
| Media Play / Pause / Loop / Restart on the selected input | PASS |
| REC: tap starts; short press while recording does NOT stop (toast "press and hold"); 1 s hold stops | PASS |
| STREAM: tap starts (LIVE 0:03 in the status bar); 1 s hold stops | PASS |
| Audio: input volume 40, mute on/off, master 90 and mute | PASS |
| Countdown start (4:58…), +1 min (357 s), pause, stop (back to 5:00) | PASS |
| Title: typing keeps the text while polling (not overwritten), "unsaved" hint, Apply → SetText, Revert | PASS |
| Title: Overlay 1 in / out, IN / OUT animation | PASS |
| Tally: picker with thumbnails; ON AIR red / PREVIEW green; overlay counts as on air | PASS |
| Tally keep-awake fallback (muted inline video, data URI) plays | PASS (wake lock not available on plain http) — real phones not tested |
| Password set: `/`, `/remote.json`, `/api`, `/thumb` → 401; `/tally`, `/tally.json`, `/tally.txt` → 200; with password → 200 | PASS |
| Cross-site request to `/tally.json` (Sec-Fetch-Site: cross-site) → 403 | PASS |
| Language: page follows the app language (KO / EN) | PASS — screenshots `docs/screenshots/2.2.4/ko-*` / `en-*` |
| `check-i18n.py` (30 new EN strings, US spelling), `test-core.sh`, `hdiutil verify` | PASS |

## Load (3 min, streaming + recording + SRT input running)
2 remotes polling `/remote.json` every 0.3 s, 3 tallies polling `/tally.json` every 0.25 s, 2 clients pulling 9 thumbnails every 4 s
(3,848 requests; the 90 "errors" are the expected 404 thumbnails of the audio-only input).

| | Result |
|---|---|
| Dropped frames | **0** |
| Render | avg 2.9–3.1 ms, worst 4.8 ms (frame 33 ms) |
| HongMix CPU | 63–84 % (avg 73 %) vs 60–70 % with one browser only — ~+10 % for 7 busy clients |
