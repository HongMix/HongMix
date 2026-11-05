# GitHub release draft — HongMix 1.4.0

## Release title

`HongMix 1.4.0 — Camera Audio Matching, Continuity Camera, DeckLink Fill/Key UI`

## Tag

`v1.4.0`

## Release body

HongMix 1.4.0 improves live capture, audio monitoring, startup feedback, and professional output configuration on Apple Silicon Macs.

### What's changed

- Added automatic camera/audio-device matching.
- Added device refresh and manual audio selection in the Camera input editor.
- Enabled iPhone Continuity Camera discovery and capture support.
- Verified live FaceTime camera capture at 1080p29.97 with active audio metering.
- Improved native NV12 camera/capture preview handling.
- Added DeckLink SDK build integration without redistributing Blackmagic SDK files.
- Added DeckLink output routing and Fill & Key modes:
  - Normal video
  - Fill & Key — Straight
  - Fill & Key — Premultiplied
- Added a five-second animated startup screen.
- Smoothed audio meter ballistics.
- Added mixed-frame-rate and audio-queue diagnostics for 29.97/30 fps sources in 59.94/60 fps productions.

### Validation status

- iPhone / Continuity Camera: supported and previously connected successfully.
- FaceTime camera + Mac microphone: verified in the current session.
- SRT: user test reported working.
- RTMP: existing operation retained.
- DeckLink: SDK integration and configuration UI are implemented; physical input/output and Fill/Key hardware validation are still pending.

### Screenshots

#### Main switcher

![HongMix 1.4.0 main switcher](docs/screenshots/1.4.0/1.4.0-main-switcher-redacted.png)

#### Live camera and audio metering

![Live camera and audio](docs/screenshots/1.4.0/1.4.0-camera-live-audio-redacted.png)

#### Camera/audio matching

![Camera audio matching](docs/screenshots/1.4.0/1.4.0-camera-audio-match-redacted.png)

#### DeckLink output configuration

![DeckLink output settings](docs/screenshots/1.4.0/1.4.0-decklink-output-settings-redacted.png)

#### DeckLink Fill & Key modes

![DeckLink Fill and Key options](docs/screenshots/1.4.0/1.4.0-decklink-fill-key-options-redacted.png)

#### Startup screen

![HongMix startup](docs/screenshots/1.4.0/1.4.0-launch-redacted.png)

### Privacy

Public screenshots are privacy-redacted. The full left Preview canvas is mosaicked, and identifiable faces elsewhere are mosaicked. Unredacted screenshots must not be linked from public README or release pages.

### Known limitations

- DeckLink hardware validation is pending.
- Long-duration capture, SRT recovery, and A/V drift testing should continue before production certification.
- Blackmagic SDK/runtime files are not included in this repository or installer.
