# HongMix mixed-frame-rate / audio test — 2026-11-05

Program/output format: 1080p59.94. Existing SRT caller output remained live. Each generated 1280×720 H.264/AAC input was placed on Program for 35 seconds.

| Source | Audio | Measured source FPS | Source drop | Mix underflow | SRT drop | Encoder drop | Render drop | Audio buffer |
|---|---:|---:|---:|---:|---:|---:|---:|---:|
| 23.976 fps | 44.1 kHz | 23.98 | 0 | 0 | 0 | 0 | 0 | 125.2 ms |
| 25 fps | 44.1 kHz | 25.00 | 0 | 0 | 0 | 0 | 0 | 109.2 ms |
| 29.97 fps | 48 kHz | 29.97 | 0 | 0 | 0 | 0 | 0 | 117.7 ms |
| 30 fps | 48 kHz | 29.97 observed | 0 | 0 | 0 | 0 | 0 | 97.8 ms |

SRT RTT stayed at 5.9–7.0 ms, loss at 0.00%, encoder queue at 0/8, and output monitor at 60 fps. Render time stayed between 1.85–2.01 ms average and 2.29–2.61 ms maximum.

`programReuseTicks` increased as expected because the 59.94 fps output repeats slower source frames. This is frame synchronisation, not a dropped-frame fault. The high cumulative `audioShortReads` on later-created inputs includes the time those inputs were waiting/paused before their test; the active-test indicator `mixUnderflows` remained zero and the CoreAudio output rings reported zero underflow callbacks/frames.

Result: no short-term audio interruption, source drop, SRT drop, encoder drop, or render drop was observed in any tested conversion. This 35-second-per-format run does not replace a multi-hour drift/field test.
