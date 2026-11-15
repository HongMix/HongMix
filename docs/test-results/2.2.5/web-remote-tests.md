# HongMix 2.2.5 — web remote test results (2026-11-15, Apple M1 Max)

## 1. Every control, three layouts (virtual switcher)
`mock.py` serves the page straight from `WebRemotePage.swift` / `WebRemote.swift` (KO + EN strings from `en.json`) and simulates the switcher state;
`suite.js` clicks the real page controls and checks the state after each action (`/_state`, `/_log`).

| Layout (viewport) | Result |
|---|---|
| desk — laptop / desktop (1440×900) | **65 / 65 PASS** |
| tab — iPad portrait (820×1180) | **65 / 65 PASS** |
| phone (390×844) | **66 / 66 PASS** (after the fix below) |

Covered: tap tile → Preview · CUT · tile Cut · tile ⏮ / ▶ / ❚❚ / Loop / mute · overlay 1–8 from tiles (lit state) · phone hides 5–8 ·
OVERLAY bank (out / Last / empty hint) · transition 1–4 effect + time + button · Quick Play · T-Bar middle and complete (slider back to 0) · FTB ·
PROGRAM transport (play, seek by tapping the bar, hidden for non-media) · STREAM / REC confirmation (cancel = nothing sent, start, red stop dialog, stop) ·
EXTERNAL without outputs (hint, no dialog) · mixer faders / M / Master / meters · countdown start / +1 min / stop · tile Edit → Titles, field labels,
typing kept while polling, Apply, preset next, IN, overlay 1 · help · 한 / EN switch · page fits the screen width.

Found and fixed: on a phone the bottom bar (4 tabs + REC · STREAM · EXTERNAL with times) was 515 px wide, so phones laid the page out at 515 px and shrank
everything. The phone bar now has two rows (tabs, outputs); the suite now checks the page width equals the screen width.

## 2. Real app (build 132/133, synthetic test project, local SRT in/out, recording to a temp folder)
`verify-real-app.py`: **47 / 47 PASS** — all page functions against the engine, new state (`bank`, 4 `trans`, `pos`/`dur`, `stream`/`record`/`external`),
`/thumb?source=program` and `source=preview`, Transition2, QuickPlay, OverlayInputNLast, SetPosition, password / cross-site rules, **0 dropped frames**.
The user's project, settings and incident log were backed up and restored byte-identical (test incidents moved out).

## 3. Not testable here
Real phones / iPad (touch, Safari, Basic-auth prompt, tally keep-awake over http).
