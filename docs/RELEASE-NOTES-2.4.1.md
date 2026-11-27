# HongMix 2.4.1 (build 202)

HongMix 2.4.1 fixes Preview/Program monitor stutter during AUTO transitions introduced in 2.4.0.

## Smooth transitions again

- Fade, Merge, Wipe and Fly transitions keep the switcher monitors at 53–60 fps in the measured operator project, up from 25–38 fps in 2.4.0.
- Program output itself was not dropping frames; this was a switcher-monitor and interface issue.
- AUTO state and the T-bar now update only the transition controls instead of redrawing every view that observes the switcher engine.

## Window prewarming removed

The hidden-window prewarming added in 2.4.0 kept those windows alive and made transition-time interface work heavier. It has been removed to prioritize smooth on-air operation. Opening a secondary window for the first time is back to the 2.3.10 range of about 0.1–0.4 seconds.

## Verification and known limits

- Five runs of each AUTO transition 1–4 recorded 53–60 fps on the switcher monitors and zero Program drops.
- Regression checks recorded 0 / 0 / 0 drops for launch, 20 fades and 10 cuts; five launch-stress runs completed with no crashes and there was no launch click.
- Replay recording was not started in this test round. The Replay code and protection verified for 2.4.0 were not changed.
- The reported Audio Mixer return problem could not be reproduced in either build 198 or test build 200. Prewarming was the leading suspect and is now removed; please report the exact close/open sequence if it recurs.
- Translation, core and MultiView tests passed. The build 202 DMG verified as valid and deep ad-hoc signing passed.
- The end-of-transition Program/Preview swap and other engine-wide changes can still pause the interface for about 0.2–0.3 seconds. Fixing that fully requires the planned Swift Observation migration.
- The public app is ad-hoc signed and not Apple-notarized; the PKG is unsigned.
