# HongMix 2.1.1

HongMix 2.1.1 adds production-safety controls, a pre-show system check and reliable multi-monitor output.

## What is new

- **Do Not Disturb during the show:** HongMix can turn Do Not Disturb on when it opens and restore it when it quits. Approve the bundled macOS Shortcut once, then use the top-bar chip to toggle it.
- **Pre-show check:** review Mac load, memory, disk, battery, thermal state, network interfaces and speed, remote-control addresses, microphone permission and connected displays in one window.
- **Per-monitor outputs:** assign Output, Preview, a bus or an input to each connected monitor. Assignments return automatically after a monitor is reconnected.
- **Desktop-aware display output:** choose **Always on this display** or **This desktop only**. The selected display is remembered by its hardware identity.
- **Keyboard control warning:** an orange bar appears while another app owns the keyboard during a live output; click it to return to HongMix.
- **Safer operation:** display sleep is prevented while HongMix runs, and the first-launch language follows the Mac.
- **Live captions:** translation now remains visible while the speaker continues talking instead of being cancelled by every recognition revision.

## API additions

`SetMonitorOutput`, `MonitorOutput`, `MonitorOutputOff`, `IdentifyMonitors`, `DoNotDisturbOn`, `DoNotDisturbOff`, `DoNotDisturbOnOff`, `StartupCheck` and `ShowStartupCheck`.

## Verification

Verified on an Apple M1 Max Mac with a Sidecar display: Do Not Disturb approval/on/off, display-sleep assertion, Korean/English pre-show check, network speed test, keyboard-control warning, monitor identification, per-monitor output, desktop pinning, display disconnect/reconnect recovery, caption translation, build and DMG verification. A physical HDMI/USB-C monitor, three or more monitors, hotspot networking and first launch on a non-Korean Mac remain untested.

HongMix is ad-hoc signed and is not yet notarized. If macOS blocks first launch, open **System Settings › Privacy & Security › Open Anyway**.
