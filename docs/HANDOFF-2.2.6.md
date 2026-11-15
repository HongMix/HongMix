# HongMix 2.2.6 — handoff (Claude → GPT)

Date: 2026-11-15 · Historical handoff. v2.2.5 was subsequently published as commit `ee4c900`.

**Do not publish 2.2.6 separately.** v2.2.5 is already public, and this work is included in v2.2.8. This document remains as the implementation and test record for live PREVIEW/PROGRAM streaming.

## 1. State
| What | Value |
|---|---|
| Version | `Resources/Info.plist` **2.2.6**, build **137** (135–136 test builds) |
| Installers | `build/dist/HongMix-2.2.6.dmg` / `.pkg`, ad-hoc signed |
| SHA-256 | DMG `df32ff02b107040aec57b51bfc70ab6575f4b182b6b2861e20d373e1fb3c53d1` · PKG `7a81e2989210469d287ef6bb5a0a916ea10172a00cebf5bd13dc231391f2ea28` |
| Manual | `docs/manual/` (now titled 2.2.6; quality option added to chapter 12) |
| Test results | `docs/test-results/2.2.6/` (+ 2.2.4, 2.2.5) |
| Copy for the user | `~/Desktop/HongMix/HongMix 2.2.6 배포/` |

New since 2.2.5: `Sources/App/Engine/WebStream.swift` (new), `ControlAPI.swift` (`/stream.mjpg` route), `WebRemotePage.swift` (quality menu, live monitors), `Resources/en.json` (+3), `docs/FUNCTIONS.md`, manuals, `docs/HANDOFF-2.2.6.md`, `docs/test-results/2.2.6/*`. If you rebuild: build **138**.

## 2. What's new: smooth PREVIEW / PROGRAM with a quality choice
User: on iPad / Windows / iPhone the monitors looked choppy (2.2.5 replaced a still picture every 0.6–1 s).
- `GET /stream.mjpg?source=program|preview&fps=&w=` — continuous JPEG (MJPEG) in an `<img>`, works in Safari (iPhone/iPad), Chrome, Edge, Android. Latency ≈ 0.1 s.
- `WebStreamHub`: one encoder per (source, fps, width), shared by all viewers; starts with the first viewer, stops with the last; a viewer still receiving the previous frame skips frames (no queueing, no growing delay); JPEG encoding on its own queue, never on the main thread. Password rules as for the remote.
- Page: **Quality** menu in the top bar — **Smooth** 15 fps / **Medium** 8 fps (default) / **Data saver** 2 fps, remembered per device (EN uses the existing "Medium" string for 보통). Picture width follows the layout. Tile thumbnails refresh every 2 / 3 / 8 s with the same choice. Streams close when the monitors aren't visible (phone/iPad tabs, page hidden). Help (?) has a line with the Mbps figures.
- Measured (`docs/test-results/2.2.6/stream-tests.md`): exact 15.2 / 8.1 / 2.1 fps; desk 4.6 / 1.5 / 0.16 Mbps per picture, phone 1.2 / 0.6 / 0.12 Mbps; 6 viewers at Smooth while recording + streaming: 14.8 fps each, **0 dropped frames**, CPU 46 %.

## 3. Release-note bullets (add to 2.2.5's)
- **웹 리모트 PREVIEW·PROGRAM이 부드럽게 움직임 — 화질 선택(부드럽게 15fps · 보통 8fps · 절약 2fps)** / **Smooth PREVIEW and PROGRAM in the web remote — choose Smooth (15 fps), Medium (8 fps) or Data saver (2 fps).**
- **여러 기기가 봐도 HongMix 부담은 그대로, 안 보는 화면은 전송 중지** / **Many viewers cost HongMix one encoder; pictures not on screen aren't sent.**

## 4. Notes
- Manual screenshots `ko/en-09…11` were taken with 2.2.5 and don't show the Quality menu in the top bar yet; everything else on them is current. Recapture with a 2.2.6 build if you want them exact (mask IPs / device names as described in HANDOFF-2.2.5 §4).
- Not tested on real phones / iPad. The user checks smoothness on iPhone, iPad and Windows.
- Working rules: Korean replies; new build number every build; every improvement changes the last digit; KO + EN complete; tests never touch the user's project (backed up and restored byte-identical this time too; test incidents moved out).
