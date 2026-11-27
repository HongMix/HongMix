# HongMix 2.4.0 — verification

- Builds: 188–191 (diagnostic and test builds; the 191 label was also used for a non-distributed symbolized build), 192 and 194 (signed test builds), 195 (first release candidate, replaced), 196–197 (diagnostic/test), **198 (release, ad-hoc)**.
- Base: `bda1673` (v2.3.10). Apple M1 Max, macOS 27.3.
- All tests used the operator's own project:
  - 9 inputs; replay CAM1 = Browser (YouTube), CAM2 = 4K H.264 file
  - replay recording ProRes Proxy, **AI slow motion on**
  - a Chrome dashboard running on the same Mac, so the GPU is shared.

## What the operator saw
Running instant replay with two cameras, everything stuttered: the Replay window, the main monitors, Program output and slow-motion playback. Opening secondary windows (Replay, Scopes, Display, Talent Cue …) also froze the UI for a moment.

## Causes (found with a symbolized build and `sample`)
1. **AI slow motion competed with the program mix for the GPU.**
   - What ran: loading Apple's frame-interpolation model, real-time AI interpolation during slow motion, and background AI clip rendering.
   - The render thread then waited 40–50 % of the time in `waitUntilCompleted`.
   - The same sequence with AI off gave 0 drops (table below).
2. **The Replay window queried free disk space on every redraw.** `volumeAvailableCapacityForImportantUsage` ran in `ReplayView.diskLine` → `estimate()` and in `refreshStatus` / `refreshLimit` on the main thread: 10+ times a second, up to 1–2 s each while the disk was busy with replay footage.
3. **Replay cameras: one GPU pass and wait per camera, every frame.** This is the same pattern as the MultiCorder ISO path fixed in 2.3.10.
4. **The whole Replay window rebuilt about 10 times a second.** Deck positions (`channelsUI`) and status were published by `ReplayEngine` itself, so every update re-diffed the clip list too.
5. **First open of a SwiftUI window:** building the window's view tree takes 0.15–0.3 s on the main thread. Opening the same window again later takes 13–60 ms.

## Changes
- **AI slow motion protection** (`SwitcherEngine.programStressed(within:)`):
  - The render thread notes when a frame is dropped or a tick uses more than 70 % of its frame time.
  - Real-time AI interpolation is skipped for 30 s after that; GPU blending is used instead.
  - Background AI clip rendering waits while the program has been stressed in the last 5 s.
  - With the new default (off), a project that has AI on starts loading the model when the project loads (at launch), not when recording starts.
- **AI slow motion is off by default** (`ReplaySettings.aiSlow = false`). Projects saved with it on keep it on.
  - New note under the toggle, KO and EN: GPU load, automatic fallback, and "turn it off if you see stutter on air".
- **Free space:** measured in the background at most every 3 s (`ReplayEngine.cachedFreeSpace`). The UI and status only read the cached value.
  - The auto-delete limit is not changed until the first value is in, so footage can't be deleted on a missing value.
- **Replay camera frames:** rendered in one GPU pass (`fullFrames`), shared with MultiCorder ISO, reusing a frame an output already drew. Removed inputs still give no frame, as before.
- **Replay window:** deck positions and status moved to `ReplayEngine.live` (`ReplayLiveState`). Only the status line, timecodes, deck panels, source tiles and transport redraw on those updates.
- **Window prewarm:** about 2 s after launch, the Replay, Talent Cue, MultiView, Scopes and Audio Mixer windows are built once, invisibly (alpha 0, closed right away).
  - A window that is already open is left alone.
  - To turn prewarm off, set the defaults key `disableWindowPrewarm`.
  - The Audio Mixer still re-lays out the main window when it pops out, but prewarming and separating its docked state reduce the measured opening stall to about 0.1 s.
- **API extensions:**
  - `OpenWindow` Value = `replay|scopes|audiomixer|talentcue|multiview|rundown|ptz`
  - `CloseWindow` Value = window title
  - `SnapshotView` gains `replaysettings`
- **EN text fix:** "1 cameras · …" → "Cameras: 1 · …".

## Results — operator's project, AI slow motion on
The sequence: start replay recording → open the Replay window → slow motion to Program → open Scopes, Mixer, MultiView and Talent Cue.

| Stage | 2.3.10 | **2.4.0** |
|---|---|---|
| Recording only | 0 drops | 0 drops |
| Replay window open (20 s) | **280–558 drops**, UI stall up to 1.4 s | **0 drops**, UI stall ≤ 20 ms |
| Slow motion to Program (12 s) | **538–548 drops**, replay 43–48 fps, gaps 135–146 ms | **0 drops**, 60.2 fps, gaps ≤ 28 ms |
| All windows open (20 s) | 10–99 drops, UI stall 0.7–1 s | **0 drops**, UI stall ≤ 20 ms |
| Same as 2.3.10, AI off (control) | 0 drops | — |

**First-round window test (builds 192/194)** (UI stall in the 5 s after `OpenWindow`; 2.3.10 numbers are the first open; the Audio Mixer and Display results were improved in the second round below):

| Window | 2.3.10 | 2.4.0 |
|---|---|---|
| Replay | 244–260 ms | **13–16 ms** |
| Talent Cue | 183–323 ms | **12–56 ms** |
| MultiView | 149–155 ms | **12–20 ms** |
| Scopes | 83–89 ms | **10–88 ms** |
| Audio Mixer | 200–244 ms | 224–392 ms (not yet prewarmed in this test build) |
| Display output (window) | 292 ms | 247 ms |

**Regression (build 192/194):**
- Program drops (launch 30 s / 20 fades / 10 cuts): 0 / 0 / 0.
- Launch click: 0 speaker opens.
- Browser input (YouTube, window visible): 30.3 fps, jitter 5.3 ms. 4 of 20 one-second windows had a gap > 50 ms (worst 460 ms, at the start of the run). This is worse than the 2.3.10 measurement (0–1/24); YouTube content varies between runs, so watch it.

**Checks:**
- `check-i18n.py` passed: new KO string with its EN translation, US spelling.
- `tests/multiview/run.sh` passed.
- Release binary 198: `hdiutil verify` VALID, `codesign --verify --deep --strict` OK, no `/Users/` or scratch paths, no probe strings, CEF bundled.
- Screenshots `docs/screenshots/2.4.0/{ko,en}-replay-settings.png`: new project, so AI is off by default, with the new note. Captured separately in each language.

## Second round (builds 196–198): the remaining items
- **Crash (found in this round, fixed):**
  - Test build 191 crashed once at launch: `EXC_BREAKPOINT` in `MTLLibraryDataWithArchive::parseArchiveSync` → `CFRelease`, under `VTFrameProcessor.startSession` (AI model load) on the AI load queue.
  - It happened while window prewarm, CEF and the monitors were creating Metal state.
  - `prepareAI` now waits until 20 s after `ReplayEngine` was created.
  - Stress test: 10 launches, replay recording at 5 s, four windows opened during the load at ~20–26 s → 10/10 alive, 0 crash reports.
- **Engine-wide refreshes:**
  - The pop-out mixer (`mixerVisible` → `MixerDock`) and the display output (`FullscreenOutput` is now an `ObservableObject`; its 6 `engine.objectWillChange.send()` calls notify only its own views) no longer rebuild every view that observes the engine.
  - The Audio Mixer joins the prewarm list.

UI stall when opening (first / second, ms), operator's project:

| Action | 195 code | 197 |
|---|---|---|
| Audio Mixer window | 394 / 294 | **120 / 102** |
| Display output (window) | 149 / 179 | **82 / 98** |
| Mixer dock hide / show | 247 / 302 | **134 / 67** |
| Replay, Scopes, Talent Cue, MultiView | 12–158 | 9–86 |
| Master mute (any engine change) | 220 / 225 | 225 / 225 (unchanged, see below) |
| Unhide → front | 326 | 316 |

- **Browser input (YouTube), 40 s steady, window visible:** 33.5 fps, jitter 3.8 ms, worst gap 55 ms, 2/40 one-second windows with a gap > 50 ms. The earlier 460 ms gap was the activation moment.
- **AI-on sequence on 197:** 0 drops in every stage, replay at 60 fps.
  - One 405 ms UI stall about 20 s after launch: the AI model loading in the background. Program had 0 drops.
- **Regression on 197:** 0 / 0 / 0 drops, 0 launch clicks.
- **Not fixed (structural):**
  - Any change to a published engine property (e.g. master mute) still costs ~0.2 s on the main thread, because ~80 views observe the whole `SwitcherEngine` (`ObservableObject`).
  - The full fix is migrating to Swift Observation (`@Observable`, per-property tracking). It touches most views and is planned as its own release.

## Operator data
- Project, settings, incident list, MultiCorder list and Application Support list were backed up and restored; hashes and values match.
- **Note:** starting replay recording in the tests replaced the temporary replay buffer (`~/Movies/HongMix/Replay/session`). HongMix always starts a new buffer when recording starts. Exported clips are elsewhere and were untouched.

Test scripts: `phase.sh` (stage measurement) and `winopen.sh` (window-open measurement). `$SCRATCH` = the test work folder.
