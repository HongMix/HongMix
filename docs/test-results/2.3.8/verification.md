# HongMix 2.3.8 — verification

Builds: 172 (test, signed "HongMix Code Signing"), 173 (release, ad-hoc). Apple M1 Max, macOS 27.3.
Base: `42aabd0` (v2.3.7, published) + the fix below.

## Problem (operator report on 2.3.7)
Program frames dropped heavily in normal use: ~400 drops within minutes, GPU 79 %, "Max" render time up to 56 ms.

## Setup (same for every row)
The operator's own project: 6 inputs (Colour, 2 × Live Captions, Web Browser playing YouTube, a 3840×2160 59.94 H.264 file at 80 Mbit/s, a 1080p60 file). Format 1080p 59.94, main window full screen in front. The 4K file is on Program and playing. A browser dashboard ran in Chrome the whole time (about 20 % GPU), as on the operator's Mac. Drop count from the API `renderStats dropped`; GPU use per process from IORegistry `accumulatedGPUTime`.

## Results (drops)
| Build | First 30 s after launch | 20 fades 4K ↔ 1080p | 10 cuts | 60 s playing | Slowest frame |
|---|---|---|---|---|---|
| 2.3.6 (168) | 0 | 0 | 0 | 0 | 6.0 ms |
| 2.3.7 (171) | 63 | 34 | 8 | 1 | 18.3 ms |
| 2.3.7 (171), Hardware look off | 0 | 0 | 0 | 0 | 3.3 ms |
| 2.3.7 test build, shadows removed only | 0 | 0 | 0 | — | — |
| 2.3.7 test build, meter clipping removed only | 90 | 116 | 38 | — | — |
| 2.3.7 test build, unchanged (repeat) | 71 | 150 | 35 | — | — |
| **2.3.8 (172), run 1** | **0** | **0** | **0** | — | — |
| **2.3.8 (172), run 2** | **0** | **0** | **0** | **0** | **3.6 ms** |

2.3.8, 60 s playing: GPU 33 % (whole Mac; Chrome dashboard 19 %, WindowServer 13 %, HongMix 7 %), HongMix CPU 36 %, average render time 1.08 ms.

## Cause
The hardware look (from PR #9) put SwiftUI `.shadow` on about 100 controls: every key on each input tile, the mixer strips, the fader caps, the Overlay keys and the transition slider. SwiftUI draws each of these shadows in a separate pass every time the view redraws. On a cut, a fade or at launch, many controls redraw at once. That GPU work held up the Program mix, which waits for the GPU (`waitUntilCompleted`), so frames were dropped. The render thread itself was idle about 85 % of the time.

## Fix
`HWDrop` (`ContentView.swift`) replaces each shadow with two plain fills of the same shape, set slightly lower behind the control. It looks almost the same and adds no extra GPU pass. It is used by `HMBevel` (raised keys) and by the slider thumb, the Overlay keys, the strip name plate and the fader cap (`SwitcherPanels.swift`). The second shadow on the strip audio button was removed, because its bevel already draws one.

## Checks
`check-i18n.py` PASS · `test-core.sh` PASS (`core-test.log`) · `hdiutil verify` VALID · `codesign --verify --deep --strict` OK · no absolute `/Users/` library paths in the release binary.

Before/after screenshots (shown to the operator): the mixer strips and tile keys look the same. The release build 173 was not run with the operator's project: it is ad-hoc signed, so macOS would ask for folder access again. It is the same source as test build 172.

The operator's project, settings and incident files were restored afterwards (hashes identical; settings identical by value).
