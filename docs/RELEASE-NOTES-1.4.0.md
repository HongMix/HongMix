# HongMix 1.4.0 (Build 54)

Release date: 2026-11-05

## Highlights

- Added camera/audio device pairing so a video capture source can retain its matching microphone or embedded capture-device audio.
- Added automatic audio matching and device refresh controls to the Camera input editor.
- Enabled macOS Continuity Camera discovery for iPhone camera capture.
- Improved native NV12 camera/capture preview handling.
- Added DeckLink SDK build integration and Fill/Key configuration UI for input/output workflows.
- Added a five-second animated launch screen with initialization status.
- Smoothed audio-meter movement for more stable visual monitoring.
- Added mixed-frame-rate and audio-queue diagnostics used for 29.97/30 fps sources in a 59.94/60 fps program.

## Validation status

| Area | Status | Notes |
| --- | --- | --- |
| iPhone / Continuity Camera capture | Supported and previously connected successfully | A fresh screenshot requires the iPhone to be visible in the current macOS camera list. |
| FaceTime camera + Mac microphone pairing | Live capture verified in the current session | 1080p29.97 camera preview and active audio meters were captured together. |
| DeckLink SDK build | Implemented | Builds when the SDK is supplied locally. Blackmagic SDK/runtime files are not redistributed. |
| DeckLink Fill/Key configuration | Implemented in UI/code | Physical DeckLink input, embedded SDI audio, Fill/Key output, and format negotiation still require hardware validation. |
| SRT / RTMP | Existing workflow retained | RTMP and the user's SRT test were reported working; extended network-loss and long-duration soak testing remains separate. |
| Mixed frame rates | Diagnostic coverage added | Continue long-duration A/V sync and underflow testing with real capture hardware. |

## Release screenshots

- `screenshots/1.4.0/1.4.0-main-switcher-redacted.png` — main switcher, ten-input poker/news production example.
- `screenshots/1.4.0/1.4.0-camera-audio-match-redacted.png` — camera and audio-device pairing controls.
- `screenshots/1.4.0/1.4.0-camera-live-audio-redacted.png` — live FaceTime camera preview with active audio metering.
- `screenshots/1.4.0/1.4.0-decklink-output-settings-redacted.png` — DeckLink output routing with the honest no-device status.
- `screenshots/1.4.0/1.4.0-decklink-fill-key-options-redacted.png` — normal, Straight Fill/Key, and Premultiplied Fill/Key choices.
- `screenshots/1.4.0/1.4.0-launch-redacted.png` — animated launch/initialization screen.

All public screenshots use privacy-redacted assets. The complete left Preview canvas is mosaicked, and visible faces elsewhere are mosaicked.

## Known validation gaps

- DeckLink hardware has not yet been connected and verified on this build.
- A current iPhone device-list screenshot was not fabricated because the iPhone was not visible to macOS during this capture session.
- Real-world claims such as uninterrupted long-duration streaming, zero A/V drift, and reliable signal recovery require dedicated soak tests.
