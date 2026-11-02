# HongMix 1.3.23 (Build 38)

## Performance changes

- Input-grid thumbnail rendering is limited to 6 fps, and large-frame thumbnail scaling is requested only while a tile is visible in a window. Program and Preview continue to use the original source frames.
- Off-air audio-follow-video sources now advance their PCM ring without copying samples or running per-sample DSP after their program fade reaches zero. The first fade-out block, transition pre-roll, and ISO recording continue through the normal mixer path.
- The existing VideoToolbox IOSurface/NV12-to-Metal path is retained. No new codec library or media conversion dependency was introduced.
- Media inputs remain cued on load and use the existing auto-play/auto-pause behavior on Take and when leaving Program. No always-on file decoding was introduced.

## Verification limits

- Release app compilation completed. No live multi-input playback, audio loopback, transition, or long-duration stress test was run for this release; real broadcast smoothness still requires an on-device session with the user's actual sources and routes.
