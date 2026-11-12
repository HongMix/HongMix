# HongMix 2.1.2

## What’s new

- **Layer media follows its parent input.** A video or countdown used as a layer starts when its parent goes on air and follows its own Auto Pause/Restart settings when the parent leaves. A shared looping layer stays running across camera cuts while it remains visible elsewhere.
- **VBR / CBR stream bitrate mode.** SRT and RTMP outputs can use VBR or CBR from Stream Settings › Encoding. For SRT/MPEG-TS, CBR also pads the transport stream toward a fixed mux rate. If the Mac encoder refuses constant bitrate, HongMix warns and uses capped VBR.
- **Input tiles now match Program placement.** Fit, Fill, Stretch, zoom, pan and crop are represented in the tile; Fill and Stretch receive a small status tag.
- **Independent input monitor window.** The monitor button on an input tile opens a large, resizable, view-only window with tally, audio meter and safe transport controls.
- **Finished clips restart correctly.** Playing or cutting to a clip that reached its end now restarts it. An on-air watchdog also recovers unexpectedly paused or stuck media and records the incident.
- **Lower background CPU work.** Unused title tickers render at tile rate, audio meters share one animation commit and transport timing has its own view.

## Why Mac cleanup exists

On a Mac that stays running for days, a macOS helper such as the Live Activities widget renderer can become stuck and block WindowServer composition every few seconds. The stream itself can remain smooth while the HongMix Preview and Output monitors appear frozen for 0.5–2 seconds.

HongMix 2.1.2 detects repeated UI stalls, identifies the high-CPU process and offers **Clean Up**. It restarts only the affected macOS widget helpers; it does not close other applications, change system settings or require a reboot. Optional automatic cleanup is available for unattended 24-hour operation, together with a one-time broadcast-Mac setup guide.

## Verification and limitations

- Core recording, file input and SRT loop tests passed; the tested build is 2.1.2 (109), ad-hoc signed.
- A 29-input load test reported zero output drops, with repeated 4K/10-bit cuts and fades continuing to play.
- CBR code and fallback compile and pass the core test, but a captured SRT stream was not yet measured end to end for constant transport rate.
- Reported audio dropouts were not reproduced because no listening output device was enabled during the test. The listening path still needs to be checked.
- Actual layer-media behaviour should still be confirmed in a real production project.
- HongMix is not yet notarized by Apple.
