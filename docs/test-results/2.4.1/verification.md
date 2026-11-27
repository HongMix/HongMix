# HongMix 2.4.1 — verification

- Builds: 199–200 (diagnostic and test; 201 was a 2.4.0-labelled rebuild, not used), **202 (release, ad-hoc)**.
- Base: `c66afff` (v2.4.0, build 198). Apple M1 Max, macOS 27.3.
- All tests used the operator's current project: 11 video inputs and a Browser input, the hardware look with the brushed-metal background on, and a Chrome dashboard on the same Mac.

## What the operator saw in 2.4.0
- AUTO transitions (Fade, Merge, …) looked like they dropped frames and stuttered at the end. Cuts were fine.
- After closing the Audio Mixer window, the mixer did not come back.

## Findings
Program output dropped **0** frames in every build. The stutter was in the switcher's own monitors: the Program/Preview monitors fell to 25–38 fps during transitions.

| Build | UI stall per transition | Monitor fps (min) |
|---|---|---|
| 2.3.10 | 164–326 ms | 46–57 |
| 2.4.0 (198) | **~590 ms** | **25–38** |
| 2.4.0 with window prewarm off | 327–340 ms | 50–59 |

1. **Window prewarm (new in 2.4.0) made it worse.** The prewarmed windows (Replay, Talent Cue, MultiView, Scopes, Audio Mixer) stay alive after they close, and every engine change rebuilt them too. That doubled the main-thread stall at each transition, and the monitors stalled with it.
2. **Each AUTO transition caused two full UI rebuilds.**
   - Start: `transitioning = true`. End: Program/Preview swap plus `transitioning` / `tbar`.
   - Every view that observes `SwitcherEngine` (~80) is rebuilt each time. A T-bar drag did this on every movement.

## Changes
- **Window prewarm removed.** First window opens are back to the 2.3.10 level; transitions matter more on air.
- **`transitioning` and `tbar` moved to `TransitionUI`**, which only the transition panel observes (the AUTO lamp and the T-bar). The engine API (`engine.transitioning`, `engine.tbar`, web remote, MIDI) is unchanged.

## Results (test build 200, operator's project)
- 5 × each AUTO transition 1–4:
  - **monitor fps min 53–60** (2.4.0: 25–38)
  - UI stall 171–336 ms (the end-of-transition Program/Preview swap is still a full refresh)
  - Program drops **0**
- Idle: HongMix GPU 6.5 % (2.4.0: 7.9 %).
- Regression: launch 30 s / 20 fades / 10 cuts → 0 / 0 / 0. Launch click: 0.
- Launch stress (5 launches, 5 windows opened while the AI model loads at ~20 s): 5/5 alive, 0 crash reports. Replay recording was not started in this round, at the operator's request.
- Audio Mixer: open → close → the mixer is back in the main window → it opens again. The operator's report was not reproduced with build 198 or 200 (`mix.sh`). Prewarm was the likely cause and is gone.
- First window opens (UI stall, ms, first/second): Replay 155/153, Scopes 112/28, Talent Cue 352/47, MultiView 141/32, Audio Mixer 436/146, Display output 164/201.
- `check-i18n.py` passed; no new strings.

## Still open (structural)
Any change to a published `SwitcherEngine` property costs 0.2–0.3 s on the main thread, because ~80 views observe the whole engine. Examples: the Program/Preview swap at the end of a transition, master mute, opening a window.

The real fix is moving the engine to Swift Observation (`@Observable`, per-property tracking). That brings back fast window opens without prewarm and makes button presses instant. It touches most views, so it is planned as its own release.

## Operator data
The project, settings, incident list, MultiCorder list and Application Support list were backed up before the tests and restored afterwards; hashes and values match. No replay recording was started.
