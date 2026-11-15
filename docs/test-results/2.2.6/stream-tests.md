# HongMix 2.2.6 — live PREVIEW / PROGRAM test results (2026-11-15, Apple M1 Max, build 135–136)

Synthetic test project (test-pattern clips, local SRT input, recording + SRT stream output running). `stream-test.py` reads `/stream.mjpg` like a browser.

## Frame rate and network per quality (PROGRAM, 1080p29.97 source, 8 s each)
| Quality | Request | Measured | Network | JPEG size |
|---|---|---|---|---|
| Smooth (desk) | 15 fps · 854 px | **15.2 fps** | 4.64 Mbps | 37 KB |
| Smooth (phone) | 15 fps · 480 px | **15.3 fps** | 1.15 Mbps | 9 KB |
| Medium (desk) | 8 fps · 640 px | **8.1 fps** | 1.51 Mbps | 23 KB |
| Medium (phone) | 8 fps · 400 px | **8.1 fps** | 0.59 Mbps | 9 KB |
| Data saver (desk) | 2 fps · 480 px | **2.1 fps** | 0.16 Mbps | 9 KB |
| Data saver (phone) | 2 fps · 320 px | **2.1 fps** | 0.12 Mbps | 7 KB |
First picture arrives within 0.01–0.08 s. (Test patterns are detailed; camera pictures are usually smaller.)

## Load: 6 viewers at Smooth (3 × PROGRAM, 3 × PREVIEW, 854 px) for 60 s while recording and streaming
| | Result |
|---|---|
| Each viewer | 14.8 fps, 4.2–4.5 Mbps |
| Dropped frames | **0** (render avg 2.1 ms, max 2.9 ms before / after) |
| HongMix CPU | 46 % (2 encoders shared by 6 viewers) |

## Page
- Quality menu (Smooth 15 / Medium 8 / Data saver 2 fps) changes the stream URL at once; remembered per device.
- Picture width follows the layout (desk 854 / 640 / 480, tablet 640 / 480 / 400, phone 480 / 400 / 320).
- Streams close when not shown: phone on the Audio tab → **0** open stream connections on the Mac; back on Switcher → reopened.
- Monitor stays black (no broken-image icon) until the first frame arrives.
- Real-app regression (`../2.2.5/verify-real-app.py`): 47 / 47 PASS, 0 dropped frames.

Not tested: real iPhone / iPad / Android browsers.
