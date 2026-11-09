# HongMix 2.0.9 — handoff (Claude → GPT)

Date: 2026-11-09 · Mac: Apple M1 Max, macOS 27.3 · Repo: `/Users/deanhong/Documents/ChatGPT/HongMIX` (branch `main`)

**GPT publishes to GitHub.** v2.0.5 is released (commit `a50d30a`, GitHub Latest = v2.0.5). Everything from 2.0.6 → 2.0.9 is **uncommitted** in the working tree. 2.0.6–2.0.8 were internal steps (never released), so publish them together as **v2.0.9**.

## 1. State in one look

| What | Where / value |
|---|---|
| Last commit (pushed, released) | `a50d30a` — Release HongMix 2.0.5 (tag `v2.0.5`) |
| Working tree | 25 modified + 7 new files (+ `docs/HANDOFF-2.0.5.md`, untracked), ~+1.5k lines — see §4 |
| Version | `Resources/Info.plist` 2.0.9 (build 95) |
| Local installers (dev-signed, **not for public release**) | `build/dist/HongMix-2.0.9.dmg` / `.pkg` (local "HongMix Code Signing" cert) |
| Installed on the user's Mac | `/Applications/HongMix.app` = 2.0.9 build 95; copy on Desktop `HongMix 2.0.9.app` |
| Release notes drafts | `docs/RELEASE-NOTES-2.0.9.md` / `.ko.md` / `-GITHUB.md` |
| Signing material (never commit) | `/Users/deanhong/Documents/ChatGPT/HongMIX-signing/` |

## 2. How to publish (checklist)

1. **Public build must be ad-hoc signed** (the self-signed cert only works on this Mac):
   ```bash
   /usr/libexec/PlistBuddy -c "Set CFBundleVersion 96" Resources/Info.plist   # every build gets a new number
   SIGN_ID="-" bash scripts/make-dmg.sh
   ```
2. Check: `hdiutil verify build/dist/HongMix-2.0.9.dmg`, `codesign -dvv` → `Signature=adhoc`, the app contains `Contents/Resources/caption-terms-ko.txt` and `caption-corrections-ko.csv`.
3. Run `bash scripts/test-core.sh` (passed at handoff for 2.0.7; no C core changes since).
4. Commit author **must** be `Seunghoon Hong <176268839+HongMix@users.noreply.github.com>`. Don't add `HongMIX-signing/` or `build/`. Do add the two new `Resources/caption-*` files and `docs/HANDOFF-2.0.*.md`.
5. README / README.ko: latest update → 2.0.9 highlights (copy from release notes), download link text → 2.0.9.
6. `gh release create v2.0.9 --repo HongMix/HongMix --latest` with the same asset set as v2.0.5 (dmg, pkg, manuals EN/KO, `SHA256.txt`, `THIRD-PARTY-NOTICES.txt`), notes from `docs/RELEASE-NOTES-2.0.9-GITHUB.md`.
7. `docs/THIRD-PARTY-NOTICES.txt` now includes the MIT notice for the caption glossary (from "vMix AI Captions v4") — keep it in the release assets.
8. Manuals (`docs/HongMix-Manual-EN.txt`, `docs/HongMix-설명서.txt`) don't describe 2.0.6–2.0.9 yet: AI background removal, replay clip export, caption look / new engine / glossary. `docs/FUNCTIONS.md` needs the API additions in §6.

## 3. What changed (by version step)

- **2.0.6 — UI clipping pass.** Every number row uses one shape `Label … [box] unit [⌃⌄]` (`NumberField` gained `step:`; new `DecimalField`) — Keyframe interval, split minutes, MultiCorder bitrate, audio Delay, Overlay durations, Stinger cut point, Captions clear-after, Web Browser width/height (no thousands comma), capture/browser fps, Photos seconds. Settings › MIDI Learn row split into rows (labels were wrapping "Inpu/t"). Virtual Set foreground label shortened. Replay: empty CAM box = one "＋ Choose source" button; Replay settings CAM picker no longer blank for a deleted input. Title editor field rows: labels hidden into prompts, Bold/Shadow → checkboxes. PTZ window top-aligned. Empty-state hints (Shortcuts, Layers, PTZ presets).
- **2.0.7 — AI background removal + replay clip export.**
  - Input ⚙ › Key › "AI background removal": Vision person segmentation (`BackgroundRemoval.swift`), two-stage pipeline (Vision on one queue, Core Image composite on another, render thread never waits; newest result used). Background: transparent / blur / image. Quality Fast (default — ≈10 ms/frame 1080p on M1 Max) / Balanced (≈20 ms, warns at 59.94) / Accurate. Render pass: `SwitcherEngine.composeLayers` step 1c (after LUT and alpha key).
  - Replay clip export (`Replay.swift` extension + `ReplayExportSheet.swift`): ⬇ per clip, ⌘-multi-select, 16:9 / 9:16 / 1:1 with crop position, clip angle / every angle, normal / 50 % / AI slow, handles 0–2 s, H.264 / HEVC / ProRes, folder `~/Movies/HongMix Highlights`. AVAssetWriter with `requestMediaDataWhenReady` on both tracks (the first blocking version deadlocked at ~68 frames). Audio only at normal speed. Stops safely when the replay store closes (epoch check).
- **2.0.8 — Caption look + robustness.**
  - Captions are drawn line-by-line by `CaptionRenderer` (`CaptionStyle.swift`) instead of one shrinking title line: presets Right column (4 lines/31 px) · Bottom cinema (2/38) · Bottom band (3/37) · Custom; lines, chars per line, font px, **letter spacing**, line spacing, gap, glyph width, X/Y/W/H, alignment, background per-line/box/band/none + opacity, colour, outline, font, label "AI 자막" (on/off, text, size, position above captions / area top-left / custom). Lines scroll up with animation; in-progress line light blue. Video is never resized.
  - Recognition bookkeeping by non-space characters (Korean re-spacing broke word counts), pause/clear decided by audio level.
  - **Speech-service exhaustion fix**: failed requests were retried instantly (~2,000/min) → the system `localspeechrecognition` service ran out ("sandbox_extension_consume failed: 12 Cannot allocate memory") and the app's main thread spent ~75 % in `supportsOnDeviceRecognition`. Now: back-off 0.5 → 5 s, on-device check cached once, "no speech" (1110) treated as normal, recogniser recreated after repeated failures, status shown. Same-language translation counts as off; a failed translation stops retrying and shows a hint.
  - Preview monitors follow the window's screen (`MonitorView.swift`: CVDisplayLink re-targeted on screen change + 16 ms watchdog timer when the link stops).
- **2.0.9 — New caption engine.** `CaptionAnalyzer.swift`: macOS 26 `SpeechAnalyzer` + `SpeechTranscriber` (preset options `[.volatileResults, .fastResults]`, `.audioTimeRange`) — one continuous on-device session, no one-minute limit, no restarts. Falls back to the classic `SFSpeechRecognizer` path on macOS < 26, unsupported language or error. Audio is never dropped (classic path keeps up to 15 s while reconnecting; new engine buffers 30 s while the model loads). Reading pace ("minimum time per line", default 1.5 s; catches up when > 2× lines behind). Glossary: built-in `Resources/caption-terms-ko.txt` (440 terms → contextual strings) and `caption-corrections-ko.csv` (literal fixes, Hangul word-boundary safe), replaceable in the Captions window. SRT uses the recogniser's own audio times.

## 4. Files

Modified: `Resources/{Info.plist,en.json}`, `Sources/App/Engine/{APIFunctions,Captions,InputModel,Replay,SwitcherEngine,Titles}.swift`, `Sources/App/HongMixApp.swift`, `Sources/App/UI/{CaptionsSheet,ContentView,FormFields,InputEditorSheet,InputPropertiesSheet,LayersEditor,MIDISettingsView,MonitorView,OutputsSheet,OverlaySettingsSheet,PTZControlWindow,PTZPanel,ReplayView,ShortcutsEditor}.swift`, `docs/THIRD-PARTY-NOTICES.txt`, `scripts/build-cli.sh` (copies the caption resources).

New: `Sources/App/Engine/{BackgroundRemoval,CaptionAnalyzer,CaptionStyle}.swift`, `Sources/App/UI/{BGRemovalSection,ReplayExportSheet}.swift`, `Resources/caption-terms-ko.txt`, `Resources/caption-corrections-ko.csv`, `docs/HANDOFF-2.0.9.md`, `docs/RELEASE-NOTES-2.0.9*.md`.

Notes:
- Localisation: all new strings are `L("한국어")` with English in `Resources/en.json`. **Insert lines, never re-serialize the JSON.**
- `@available(macOS 26.0, *)` guards the new engine; the deployment target stays macOS 14.
- Caption settings live in UserDefaults key `captionSettings` (JSON; new fields decode with defaults). Replay export options: `replayExportOptions`.

## 5. Verification done (in the real app, API-driven; user's project backed up and restored each time)

- AI background removal: transparent → 13.7 % of a 1080p person frame opaque (person only); blur/off 100 %. Fast 10.4 ms, Balanced 20.4 ms on 1080p59.94, program render 1.0 ms / 0 drops while on. Standalone harness compared to Vision directly.
- Replay export: 16:9 1920×1080, 9:16 1080×1920 (crop centred, upright), 1:1 1080×1080 — 6.0 s with 1 s handles, H.264 + AAC (−24 dB test tone); 50 % ProRes 8 s; AI slow HEVC 16 s (4 s clip). Row progress, multi-select, sheet layout checked by screenshot.
- Captions (25 s Korean TTS clip looping on Program, captions on Master):
  - classic engine 2 min: key sentences present 0–4 of 4 loops (whole sentences lost); new engine 3.5 min: 8 of 8 (one misrecognised word), live word-by-word updates (~1 s), longest unchanged 0 s, 0 speech-service errors, SRT times match the audio.
  - App hidden behind Finder: captions keep updating.
  - 40 s silence then speech: first caption after 0.9 s, no false warning.
  - All 3 layout presets, label positions, letter spacing, re-wrap after layout change: rendered snapshots checked.
- Unit/C tests: `scripts/test-core.sh` passed (2.0.7). No new automated tests were added for 2.0.6–2.0.9 (verification was manual through the HTTP API + screenshots).

## 6. API additions (HTTP 8088 / TCP 8099)

- Background removal: `BackgroundRemovalOn/Off/OnOff` (Input), `SetBackgroundRemoval` (Input, Value=`transparent|blur|image[,fast|balanced|accurate]`).
- Replay: `ReplayExportLastEvent` (Value=`horizontal|vertical|square`), `ReplayExportEvent` (Value2/Selection = clip number), `ReplaySetSource` (Input, Value=CAM 1–4).
- Captions: `StartCaptions`, `StopCaptions`, `StartStopCaptions`, `CaptionsTest`, `ClearCaptions`, `SetCaptionLayout` (`right|bottom|band`), `SetCaptionLines`, `SetCaptionSize`, `SetCaptionLetterSpacing`, `SetCaptionLineSpacing`, `SetCaptionChars`, `CaptionLabelOn/Off/OnOff`.
- XML extras: `<hmReplay events= recording= exporting=>message</hmReplay>`, `<hmCaptions running= rows= layout= status=>text</hmCaptions>`.

## 7. Not verified / known issues

- **Quit is blocked while a sheet is open** (Captions, Properties, Settings …) — pre-existing since 2.0.5. A fix attempt (close sheets in the Quit Apple Event / SIGTERM handler, `ProjectIO.closeSheets()`) did **not** work; closing the sheet first quits normally. Still open.
- Captions tested with synthetic speech only — real meetings (overlapping speakers, room noise) and the glossary's real effect not measured.
- Background removal not tested with a real live camera (still photo + test video only).
- Monitor display-link retargeting not tested on a second physical monitor (this Mac has one display).
- The main window spends a lot of main-thread time in SwiftUI layout (seen in samples); not investigated further.
- Old `localspeechrecognition` processes from earlier sessions may linger; a reboot cleans them. If the speech service is ever exhausted again, quitting HongMix lets it recover (verified).
- Still from 2.0.5: real PTZ/NDI PTZ, DeckLink, MIDI hardware, USB replug untested.

## 8. Working rules from the user

- Show a UI mockup and get approval before UI changes.
- New version/build number for every build; app on the Desktop as `HongMix <version>.app`; final deliverable DMG (+PKG).
- Korean and English UI both required.
- The user runs several Apple Silicon Macs — detect capabilities per chip/OS (e.g. the caption engine falls back below macOS 26).
- Don't touch the user's project in tests: add test inputs, address them by key, back up `~/Library/Application Support/HongMix/last-session.bmix` (and `defaults export com.hongseunghoon.HongMix`) first, restore after. Check the user is idle / not on air before swapping the running app. Never start real stream destinations.
- Reply to the user in Korean.
