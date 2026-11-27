# Pull requests #10–#14 (otiumvisuals) — review (released in 2.3.10)

Date: 2026-11-27. All five PRs were opened today and are all `MERGEABLE` against `main` (v2.3.8).

**How they were tested.** In a scratch clone (not the working repo): v2.3.8 + the 2.3.9 changes, then #10, #11, #12, #14 and #13 were merged in that order. Builds 182–183 were made from the clone (183 includes the bundled CEF). Nothing was posted on GitHub.

## Summary
| PR | What | Size | Verdict |
|---|---|---|---|
| #10 | Launch screen: green check marks in every skin (were red in Black & White) | +1/−1 | Merge. Correct; red ✓ reads as "failed". |
| #11 | Input tile: a white ring on the Overlay key whose channel remembers this input while it is off air | +7/−4 | Merge. The claim checks out: the old `assigned` (`overlayChannels(of:)`) already meant "on air". |
| #12 | Scopes: "+" opens extra Scopes windows (own source and layout); hardware-look keys/slider | +48/−13, 1 new string | Merge after the operator OKs the look. |
| #13 | MultiView labels: own label per cell, PREVIEW / PROGRAM (was "PREVIEW name" / "OUTPUT"), labels on or below the picture | +147/−14, 7 new strings | Merge **only with the 2.3.9 port below**; the operator decides the new default labels. |
| #14 | Hardware look: lighter grey, brushed-metal background, squarer monitors/tiles, **tally borders at 50 %**, Talent Cue hardware keys | +91/−23 | Ask to keep tally at 100 %; the operator decides the look. |

## Test results (merged build 183, operator's project, window visible, 40 s × 2)
| | 2.3.9 | 2.3.9 + #10–#14 |
|---|---|---|
| Program drops | 0 / 0 | 0 / 0 |
| HongMix GPU | 6.4–6.7 % | 6.1–6.5 % |
| WindowServer GPU | 22.3–23.4 % | 24.1–24.6 % |
| Render avg / slowest frame | 1.27–1.39 / 5.0–5.3 ms | 1.36–1.40 / 8.4–10.6 ms |
| Launch 30 s / 20 fades / 10 cuts | 0 / 0 / 0 | 0 / 0 / 0 |

- The brushed-metal background costs the system compositor ~1.5 % more GPU.
- The slowest frame is a few ms higher, still well under the 16.7 ms budget.
- No SwiftUI `.shadow`, blur or material is added.

Also checked: `tests/multiview/run.sh` (with #13's new checks) passes, and `check-i18n.py` passes.

## Issues found
1. **#13 conflicts with 2.3.9.**
   - #13 changes `MetalMixer.drawLabels` (CPU). In 2.3.9 that is only the fallback; labels are drawn once and blended on the GPU (`labelImage`).
   - Merged as is, "labels below" and the clipping of long names would not reach the output.
   - In the test clone, the conflict was resolved by sharing one drawing routine between both paths:
     - `labelBar` gives the bar rect: on the picture, or a full-width strip under it.
     - `drawLabel` draws bar + text, with the text clipped to the bar and centred when below.
     - The cache key includes `labelBelow`. The bar height comes from `MultiViewConfig.labelBarHeight`.
   - Rendered output checked: `pr-mv-labels.png` (on picture), `pr-mv-labels-below.png`.
   - **Suggestion:** ask the contributor to rebase #13 on 2.3.9, or apply that resolution when merging.
2. **#14: tally borders at 50 % opacity.** The red/green border on Preview/Program monitors is the operator's on-air cue, so halving it is a function change, not just a look. Suggest keeping 100 %, or 50 % only for the non-tally hairline.
3. **#13: default labels change.** "PREVIEW Camera 2" becomes "PREVIEW", and "OUTPUT" becomes "PROGRAM", on every MultiView output, so the preview cell no longer names its input. Operator decision.
4. **#13 nit:** long names are clipped hard at the cell edge with no "…".
5. **#12 nits:**
   - Extra Scopes windows are a `WindowGroup`, so macOS may reopen them at the next launch, and each runs its own 10 Hz analysis.
   - In the clean look, the source menu now gets the bevel modifier (`replayKey`), so it looks slightly different from before.
6. **#14 nit:** the small Talent Cue "Quick Setup" buttons (5′, 10′, …) become full-size hardware keys (12 pt).

## Screenshots (synthetic project: bars / pattern / colour / test page; IP and paths masked)
- `pr-cmp-main.png`: main window. Grey brushed background, squarer monitors, dimmer tally borders, ring on overlay key 1 of input 3.
- `pr-cmp-talentcue.png`: Talent Cue control window, hardware keys.
- `pr-cmp-mveditor.png`: MultiView editor, "On picture / Below picture" and PROGRAM.
- `pr-mv-labels.png`: MultiView output, 2.3.9 vs merged (on picture).
- `pr-mv-labels-below.png`: MultiView output, labels below, one custom label ("STAGE").
- `pr-cmp-replay.png`: Replay window.

Not checked: the Scopes window (no snapshot hook), and the Display/MultiView output window on a real second monitor.

## Decision (operator, 2026-11-27)
All five are merged in 2.3.10, with these changes:
- #14's brushed-metal background becomes an option (off by default), and the tally stays at 100 %.
- #13's automatic names become an option. The default keeps the 2.3.8 names.

See `verification.md` Part B.
