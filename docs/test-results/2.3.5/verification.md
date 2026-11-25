# HongMix 2.3.5 — verification (Claude, 2026-11-25)

Real app, dev builds 162–164; the user's project, settings and incidents backed up and restored byte-identically. 2.3.4 checks: docs/test-results/2.3.4/verification.md.

| Case | Before (2.3.4, build 161) | After (2.3.5) |
|---|---|---|
| Stinger, 2 s clip with Loop on, cut point 500 ms | Program switched at 0.5 s, but the clip kept looping on top of Program (still running after 4 s) | Program switches at ~0.6 s; stinger clears at ~2.1 s; Loop restored, clip paused — twice in a row |
| Last frame of a clip (2 s, 30 fps) | stopped at ~1500 ms | reaches 1960 ms (stinger and plain clip) |
| Center column KO / EN screenshots | — | PASS (stacked CUT / AUTO / Quick Play, AUTO + "Fade 0.5 s" centred) |
| Build | — | check-i18n PASS · test-core PASS · build 165 ad-hoc · hdiutil VALID |

DMG `c07ff65d19dbd23f50a13522dd372f11d08419b05a2aa9fa3bd1540a9bc59859`
PKG `79f8d2de51030ecb5f0334fc48c9247f3b6e7093ffa35ee2a1569c924928204c`
