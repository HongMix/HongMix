# HongMix 2.3.8 (build 173)

**Recommended for everyone on 2.3.7.** HongMix 2.3.8 fixes Program frames dropping at launch and during cuts and transitions when the hardware look is enabled.

## What was fixed

- The hardware look in 2.3.7 applied SwiftUI shadows to about 100 controls, including input-tile keys, mixer strips, fader caps, Overlay keys and the transition slider.
- Those shadows required additional GPU rendering whenever the interface changed. Program composition could wait behind that work during launch, cuts and fades.
- HongMix now draws the raised-key depth with two lightweight offset fills of the same shape. The appearance remains nearly identical without the extra shadow passes.

## Measured result

The comparison used the operator's project with a 4K 59.94 H.264 file on Program, a YouTube browser input and the Chrome dashboard running.

| Test | 2.3.7 | 2.3.8 |
|---|---:|---:|
| First 30 seconds after launch | 63 drops | 0 |
| 20 fades | 34 drops | 0 |
| 10 cuts | 8 drops | 0 |
| Slowest frame | 18.3 ms | 3.6 ms |

The 2.3.8 measurement was repeated twice and all tested drop counts remained zero. The Chrome dashboard still used GPU time, but did not cause drops with the fix.

## Verification and limits

- Translation and core tests passed. The DMG verified as valid, deep ad-hoc signing passed, and the build 173 DMG/PKG checksums matched the release files.
- Build 173 uses the same source as the measured build 172, but was not run with the operator's project because its ad-hoc signature would prompt for folder access again.
- The public app is ad-hoc signed and is not Apple-notarized yet. The PKG is unsigned.
