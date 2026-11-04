# HongMix technical and UI review

Date: 2026-11-04  
Baseline: HongMix 1.3.39, commit `3691de5`, local branch `codex/development`

## Product definition

HongMix should remain a native Apple Silicon live-production switcher, not a general scene compositor. Its strongest position is:

> A vMix-style production workflow for Mac, with reliable SRT/RTMP/NDI/DeckLink I/O, hardware media processing, replay, audio buses, recording, and Companion/Stream Deck control.

The current code already goes well beyond a prototype. It contains project autosave/restore, input failover, preflight checks, SRT history and guidance, incident capture, CoreAudio bus routing, multitrack recording, replay, broadcast delay, vMix-compatible control, and health history.

## Verified during this review

- Release build succeeded with local LGPL FFmpeg 9.0.2 and CEF 156.
- SRT loopback succeeded when run with normal local-network permissions:
  - hardware encoder: `h264_videotoolbox`
  - SRT output: 149 video frames, approximately 147 kbps
  - SRT input: 133 video frames at 640×360
  - received audio: 231,424 frames
  - H.264 video and AAC audio detected
- The earlier SRT failure was caused by the restricted command sandbox being unable to open the local listener socket. It was not evidence of an HongMix SRT defect.
- RTMP was reported by the owner as operational; it was not independently exercised in this review.
- DeckLink source adapters exist, but the local source build excludes full DeckLink support until the proprietary Desktop Video SDK headers are supplied. Hardware capture/output still requires a physical card and Desktop Video driver validation.

## Current UI assessment

### What is working

- Preview orange and Program green follow a familiar production convention.
- The central transition area is recognizable to vMix operators.
- Input tiles expose the most-used transport, overlay, replay, and cut controls.
- Audio is visible beside the inputs instead of being hidden in a separate page.
- Replay has a strong operational model: two decks, four camera slots, system time, TC, speed, IN/OUT, and clip bin.

### Main UI problems

1. **Information density has outgrown the visual hierarchy.** Almost every control has equal visual weight. Operators must scan many small buttons during a live event.
2. **Connection health is fragmented.** Render FPS, API address, SRT status, disk, recording, NDI, and output state appear in different windows or small labels.
3. **Small click targets increase on-air risk.** Input tile controls and overlay buttons are compact, especially on laptop displays.
4. **The lower workspace does not adapt clearly to operator roles.** A technical director, audio operator, replay operator, and single-person operator need different panel emphasis.
5. **Warnings need action-oriented language.** A warning should show the cause, likely impact, and the next safe action.

## Recommended UI direction

### 1. Persistent safety/status strip

Keep a narrow strip visible at all times with:

- Stream and record state
- SRT/RTMP/NDI/DeckLink connection state
- actual output bitrate
- render average/peak and dropped frames
- disk recording time remaining
- audio clipping/silence state
- last recovered failure

Clicking a status opens the detailed diagnostic view. Normal state should stay quiet; only actionable conditions become amber or red.

### 2. Dockable workspaces

Provide saved layouts for:

- Switching
- Audio
- Replay
- Network/remote production
- Graphics/rundown
- Single-operator compact mode

The current main screen can remain the default. Panels should resize or detach without changing the underlying operating model.

### 3. Preflight becomes an operational gate

The existing preflight engine should evolve from a list into a readiness workflow:

- check inputs, format consistency, audio, output authentication, SRT health, record/replay disk, API exposure, and backup routes
- distinguish advisory warnings from blockers
- allow outputs to be armed before GO LIVE
- export a diagnostic bundle
- remember accepted exceptions for the current event only

### 4. Network & Transport workspace

Build on the existing SRT monitor and health history. Show one card per active network route with endpoint/mode, codec, FPS, bitrate, RTT, loss, retransmissions, latency, jitter, last-frame age, reconnect count, and two-minute graphs. Include an explicit local loopback test.

## Highest-priority engineering work

### P0 — reliability and test truth

1. **Make integration tests fail when transport fails.** The current core test previously printed SRT failures but still exited successfully. Assertions must cover received video/audio counts, output frame counts, codec detection, and timeouts.
2. **Use the same LGPL FFmpeg build in tests and releases.** `test-core.sh` currently reported a Homebrew GPL FFmpeg build while the application release uses the local LGPL build. Test/release dependency drift can hide defects.
3. **Add repeatable SRT tests:** caller→listener, listener→caller, encrypted link, stream ID, forced disconnect/reconnect, packet loss/jitter, bad password, occupied port, IPv4/LAN, and multi-hour soak.
4. **Add an RTMP local test server** and verify publish, reconnect, authentication failure, keyframe interval, and audio continuity.
5. **Run 8–12 hour soak matrices** on representative M1, base M-series, Pro/Max, and current-generation Macs.

### P0 — security and recovery

1. `OutputConfig` is Codable and includes RTMP stream keys/passwords and SRT passphrases. Do not write these secrets into portable project JSON by default. Store them in Keychain and save only a reference, or provide an explicit “include credentials” export option.
2. The remote-control password is stored in UserDefaults. Move it to Keychain, avoid logging credentials, and use constant-time comparison where practical.
3. Replace silent critical `try?` paths for autosave, incident files, and output storage with visible, rate-limited health events.
4. Maintain multiple rotating autosave generations and validate a project before replacing the last known-good autosave.

### P1 — real-time robustness

1. Audit lock ordering and shutdown ownership. The C media layer contains many mutexes and threads across input, decode, audio release, SRT, NDI, DeckLink, replay, and output paths.
2. Replace application-level `fatalError` paths for audio-ring and Metal allocation with a recoverable startup/error screen. A production tool should fail closed with diagnostics rather than terminate without explanation.
3. Add watchdogs for last video frame, last audio frame, output packet progress, encoder progress, and disk-write progress.
4. Add bounded queues and explicit high-water telemetry everywhere a media producer can outrun a consumer.
5. Verify audio-device removal, sample-rate changes, aggregate devices, and multichannel channel-map recovery.

### P1 — maintainability

Several files are becoming subsystem monoliths: `SwitcherEngine.swift` (~1,815 lines), `mc_input.c` (~1,718), `SwitcherPanels.swift` (~1,432), `Replay.swift` (~1,263), and `mc_output.c` (~1,236). Split by ownership and lifecycle before adding major features. Recommended boundaries:

- transport session vs codec/mux vs reconnect policy
- live input vs file playback vs playlist/preload
- engine state vs project persistence vs automation
- main switcher layout vs input tiles vs mixer workspace
- replay recording vs deck playback vs clip library vs AI interpolation

### P2 — valuable new technology

Only after P0/P1:

- Network Link Conditioner-style test profiles integrated into diagnostics
- VideoToolbox encoder capability probe and automatic safe presets per Mac
- Metal Performance Shaders/Core ML only where measured benefit exists
- HDR/SDR color-management pipeline with explicit transfer function, matrix, range, and monitoring transforms
- timecode/PTP/LTC support for professional synchronization
- OSC/MIDI control in addition to vMix API
- signed/notarized updates with stable and beta channels
- structured diagnostic bundle with redaction of endpoints and credentials

## DeckLink conclusion

The application has DeckLink input/output source code and conditional build support. That means DeckLink capture is an intended capability, but source presence alone is not proof that every card, format, key/fill mode, and driver version works. Completion requires:

1. Owner-supplied Blackmagic Desktop Video SDK headers
2. Desktop Video driver installation
3. Build with `DeckLinkAPIDispatch.cpp`
4. Physical tests for capture, output, audio channels, device removal/reconnect, format changes, and fill/key

Blackmagic's redistribution restriction applies to its SDK, not to the HongMix code written by the project owner. HongMix source can remain under its own chosen license while respecting the SDK's separate terms.

## Concept images

These are design studies, not implemented screens:

- `docs/design-concepts/main-switcher-concept.png`
- `docs/design-concepts/network-transport-concept.png`
- `docs/design-concepts/preflight-safety-concept.png`

They were generated with the built-in image generation tool. The first uses the HongMix 1.3.39 screenshot as its reference; the other two are new HongMix-aligned UI concepts.

## Recommended next implementation milestone

Call the next milestone **Reliability Foundation**, not a feature release:

1. Correct integration-test pass/fail behavior and dependency alignment.
2. Build SRT and RTMP local test harnesses.
3. Protect credentials with Keychain and redact diagnostics.
4. Add rotating autosave and recoverable startup errors.
5. Implement the persistent health strip using existing health/SRT/preflight data.
6. Perform a measured four-hour run, then eight-hour run, recording every drop, underrun, reconnect, memory trend, and disk-write event.

