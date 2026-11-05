# Community issue validation — 2026-11-05

Community reports reviewed: vMix Forum and Reddit /r/vmix, /r/VIDEOENGINEERING.

## Phase 1 — live log soak (5 minutes)

Conditions: HongMix 1080p59.94, 10 poker/news inputs, input 4 on Program, active SRT caller output at about 4.4–5.0 Mbps, 1000 ms latency. No output setting was changed.

| Check | Result |
|---|---|
| Program/source frame drops | PASS — `sourceDropped=0`, render/output drops `0` |
| SRT loss recovery | PASS — lost/retransmitted `3→6`, SRT dropped `0`, loss `0.00%` |
| Encoder pressure | PASS — queue `0/8`, encoder drops `0` |
| Render timing | PASS — avg `1.85–2.33 ms`, max `2.26–5.96 ms` |
| Memory growth | PASS for this short window — main RSS about `560→520 MB` |
| File-loop audio continuity | **FAIL candidate** — `mixUnderflows 1→3→5`; increases coincided with media PTS wrapping at loop boundaries |
| UI monitor cadence | WARN — `outputMonitorFps` briefly reported `38`, while render/output drops remained `0`; likely preview/UI-only but needs a longer test |

Raw log: `build/logs/forum-soak-2026-11-05.log`.

## Harness finding

`scripts/test-core.sh` returned exit code 0 even though the SRT listener failed to open and transmitted/received zero frames. The environment also denied VideoToolbox compression and the harness fell back to libx264. Therefore this run does not certify SRT loopback; the harness must treat `frames=0` or listener-open failure as a failing exit status.

## Community-derived matrix still to run

1. 30–120 minute A/V drift soak with an objective clapper/timestamp source.
2. SRT input under controlled packet loss, jitter and reconnection; 120/500/1000/2000 ms latency.
3. Static/black/high-motion scenes to measure CBR/VBV behavior.
4. SRT video-loss/audio-continues and sender restart recovery.
5. Browser input add/remove cycles and retained-memory measurement.
6. Simultaneous stream + record + 10/20/30 inputs, including mixed 23.976/25/29.97/30/59.94 fps.
7. NDI source-drop test with NDI Analysis (requires a live NDI sender/network).
8. DeckLink input/output Fill/Key, format change and signal-loss recovery (requires connected hardware).

Short tests are evidence only for their stated duration; they do not prove multi-hour broadcast stability.
