# HongMix 2.3.10 — verification

2.3.10 = the engine work prepared as 2.3.9, which was never released, plus pull requests #10–#14 by @otiumvisuals, with two of them changed to options.
- Builds: 174–181 (2.3.9 work: test builds and an unreleased release), 182–186 (PR test builds from a scratch clone), **187 (release, ad-hoc)**.
- Apple M1 Max, macOS 27.3. Base: `4ced42f` (v2.3.8).

Part A (below, up to "Operator data") covers the engine work. Part B (at the end) covers the pull requests and the options.

## Part A — engine changes
1. **MultiCorder ISO: one GPU wait per tick** (`SwitcherEngine.swift` step 6, `MetalMixer.renderTiles(batch:)`). All ISO frames are encoded into one command buffer and the render thread waits once. Before, it waited once per ISO. An input that was already rendered full-frame this tick for an output or monitor is reused instead of being drawn again. Suggested on Reddit by Hawk_Super.
2. **MultiView labels cached on the GPU** (`MetalMixer.swift`, `Mixer.metal` `labelFragment`). Each label (bar + text) is drawn once on the CPU, kept as a texture and blended in the same command buffer as the tiles. Before, every MultiView frame locked its IOSurface and redrew every label with CoreText. The CPU path is kept only as a fallback if the shader is missing. Also suggested by Hawk_Super.
3. **No click at launch** (`mc_web.mm`: Chromium switch `disable-audio-output`). Chromium's audio service opened the real speaker device for ~0.1 s on every launch, even though page audio only reaches the mixer through `CefAudioHandler`. Many interfaces and speakers click when an output opens.

## Standalone benchmark (real `MetalMixer.swift` from v2.3.8 vs the new one, 1080p, NV12 sources, 400 runs)
| Case | 2.3.8 | new |
|---|---|---|
| MultiView 4×4 + 16 labels | 1.23 ms | **0.71 ms** (no labels: 0.61 ms) |
| ISO × 2 | 0.85 ms | **0.54 ms** |
| ISO × 4 | 1.67 ms | **0.79 ms** |
| ISO × 8 | 3.36 ms | **1.28 ms** |

Pixels: the ISO frames are identical. The MultiView frames (1080p 4×4 and 720p 3×3, which has fractional cell edges) differ by at most 2/255 in anti-aliased label pixels, which is rounding (`label-compare.png`: left 2.3.8, right 2.3.9).

## Real app (operator's project: 8 inputs, video input playing)
MultiView in a display window + MultiCorder ISO on 4 inputs, 40 s each, two runs per build:

| Build | Drops | Tick time (avg) | Slowest frame |
|---|---|---|---|
| 2.3.8 (172) | 0 / 0 | 6.12 / 6.51 ms | 10.9 / 13.8 ms |
| new (174) | 0 / 0 | **4.80 / 4.83 ms** | 10.8 / 9.2 ms |

- ISO files: 16 files (4 per run), all 1920×1080, ~2,675 frames in ~44.6 s (59.94p). The video ISO frame (new build) checked visually.
- Regression (launch 30 s / 20 fades 4K↔1080 / 10 cuts): **0 / 0 / 0 drops**.

## Launch click (per-process CoreAudio "is running output", 20 ms polling, launch to +14 s)
| Build | HongMix processes that opened the speaker |
|---|---|
| 2.3.8 (3 launches) | `HongMix Helper` (Chromium `audio.mojom.AudioService`) for 70–120 ms at ~4.6 s, every launch |
| new (174–175, 3 launches) | none |

A system-sound event (`systemsoundserverd`, ~0.6 s at ~2.2 s) appeared in 2 of 3 launches of 2.3.8 and in none of the new builds. It is not attributable to HongMix code (HongMix plays no sound at launch).

Page audio after the change: checked with a test page playing a 440 Hz tone (see below).

## Automated
| Check | Result |
|---|---|
| `python3 -I scripts/check-i18n.py` | PASS (no new strings) |
| `bash scripts/test-core.sh` | PASS (`core-test.log`) |
| `bash tests/multiview/run.sh` | all checks passed |
| `hdiutil verify HongMix-2.3.10.dmg` | VALID |
| `codesign --verify --deep --strict` | OK |
| release binary | 2.3.10 (187), no `/Users/` or scratch paths, no probe strings, CEF bundled, `disable-audio-output` and `labelFragment` present |

## Browser input stutter (fixed)
The operator reported YouTube in a Browser input looking jerky. Before the fix, HongMix's own per-input cadence (`inputStats`, sampled each second) was:

| Source | Window | Delivered fps | Jitter | Worst gap | Seconds with a gap > 50 ms |
|---|---|---|---|---|---|
| Operator's YouTube page (30 fps live) | visible | 30–44 | 13.8 ms | 493 ms | 13/30 |
| Same | hidden | 60 | 2.9 ms | 85 ms | 1/30 |
| Test VP9 1080p30 video | visible | 30 | 6.4 ms | 171 ms | 6/20 |

Chromium itself played smoothly. On test pages, `requestAnimationFrame` ran at 16.7 ms, and the video element dropped 1 frame in 1,692.

**Cause.** A temporary probe (`HM_WEBPROBE`, removed before release) timed `OnAcceleratedPaint` and Chromium's pump work. With the window visible:
- Chromium painted 25 frames/s with a ~53 ms gap every second, while the 60 Hz backup pump timer and the pump calls themselves were on time.
- "Do this now" requests (`OnScheduleMessagePumpWork(0)`) went through `dispatch_after` on the main queue. macOS coalesced these with other timers, so Chromium's frame work slipped, and once a second it ran up to 0.65 s late.

**Fix.** Immediate work runs through `CFRunLoopPerformBlock` (common modes) + `CFRunLoopWakeUp`. Delayed work uses a `CFRunLoopTimer` with zero tolerance.

Variants tried, window visible, operator's YouTube page:

| Variant | Paints/s | One-second windows with a gap > 45 ms |
|---|---|---|
| 2.3.8 scheduling | 25.5 | 24/24 |
| External BeginFrame at 60 Hz | 32.0 | 24/24 |
| Immediate work on the run loop | 37.9 | 1/24 |
| **Final (immediate + zero-tolerance timers), two runs** | 33–35 | 0–1/24 in steady state |

After the fix:
- Test VP9 1080p30, window visible: 30.0 fps, jitter **3.0 ms**, worst gap 45 ms, 0/20 seconds with a gap > 50 ms.
- One stall of ~1 s remains right when the window is first brought to the front. The whole main thread stops then (the 60 Hz timer gap was also 1.1 s), and it happened in 2.3.8 too. It is not part of this fix.
- Page audio still reaches the mixer: 440 Hz tone, `meterF1` 0.08, audio buffer ~120 ms.
- Drops (launch 30 s / 20 fades / 10 cuts): 0 / 0 / 0.
- Launch click: 0 HongMix speaker opens in 2 launches.

## Operator data
`last-session.bmix`, the defaults domain, `incidents.txt`, the incident folder list and the MultiCorder folder list were backed up before testing and restored afterwards. File hashes match the backup and the defaults are identical by value. Test incident folders and ISO files were moved to the scratch folder.

## Part B — pull requests #10–#14 and options (build 186 = release source, 187 = release)
**Merged:** #10 green launch check marks, #11 overlay-key ring, #12 Scopes windows, #13 MultiView labels, #14 hardware look.

**Changed on top, at the operator's request:**
- **#14:**
  - The brushed-metal background is an option: Settings › General › Appearance, **off by default**, available only with the hardware look on.
  - Tally borders on the Preview/Program monitors stay at **100 %**; the PR had 50 %.
  - Kept as in the PR: grey tones, squarer corners, hardware keys in Talent Cue.
- **#13:** automatic names are an option per MultiView (`simpleLabels`), shown in the editor's second row:
  - "With input name" is the **default** and is unchanged from 2.3.8: "PREVIEW <input>" and "OUTPUT".
  - "PREVIEW · PROGRAM" is the alternative.
  - "On picture / Below picture" and the per-cell names are kept from the PR.
- **#13 conflict:** #13 changed the CPU label drawing. In this release the labels are drawn on the GPU (Part A, item 2), so #13's "labels below" and the clipping of long names were ported to the GPU path. Both paths share one routine (`labelBar` / `drawLabel`).

**Checks:**

| Check | Result |
|---|---|
| `check-i18n.py` | PASS (new strings: Brushed-metal background · With input name · automatic-name help) |
| `tests/multiview/run.sh` | all checks passed, including the PR's checks and new label-style checks: the default is classic, older projects decode as classic, the setting round-trips |
| Rehearsal of the publish steps in a fresh clone | the resulting tree is identical to the tested tree; contributor commits keep their author |

Operator's project, window visible, 40 s per run:

| Build | Drops | HongMix GPU | WindowServer GPU | Slowest frame |
|---|---|---|---|---|
| engine work only (180) | 0 | 6.6 % | 21.4 % | 5.2 ms |
| 2.3.10 (185), two runs | 0 / 0 | 6.6 / 6.6 % | 21.7 / 21.4 % | 5.1 / 4.6 ms |
| 2.3.10, brushed metal on | 0 | 6.9 % | 21.6 % | 4.5 ms |

- Launch 30 s / 20 fades / 10 cuts: 0 / 0 / 0.
- The hardware keys use the 2.3.8 `HWDrop` fills, with no SwiftUI `.shadow`, `.blur` or material.

**Screenshots** (`docs/screenshots/2.3.10/`):
- Synthetic inputs only (bars, pattern, colour, a test page), renamed Camera 1/2, Graphics, Lower third, Web page. LAN address masked.
- Separate KO and EN captures, each with the app in that language: `ko-`/`en-` + `main`, `multiview` (editor with the two name options), `settings` (General › Appearance with the new toggle), `talentcue`.
- `multiview-labels.png`: MultiView output, default names, on picture.
- `multiview-labels-below.png`: MultiView output, PREVIEW · PROGRAM, below picture.

**Not checked:**
- Scopes windows (#12): there is no snapshot hook, and the extra windows weren't opened in the real app.
- Monitor outputs on a real second monitor.
