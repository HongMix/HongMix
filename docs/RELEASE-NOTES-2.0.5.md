# HongMix 2.0.5

## New
- **PTZ Control window** (bottom bar › PTZ): live pictures of every PTZ camera input, numbered 1–9. Keys: 1–9 camera · W A S D pan/tilt (Shift = fast) · Q/E zoom · Z/X focus · F auto focus · U I O / J K L / M , . presets 1–9 · Tab next camera. Releasing a key stops; leaving the window stops all movement.
- **PTZ per input** (Input ⚙ › PTZ): VISCA over IP (Sony), VISCA TCP (PTZOptics), VISCA UDP, NDI PTZ. NDI inputs use NDI PTZ automatically; SRT/RTSP inputs pre-fill the camera IP. Presets, "move to preset when put in Preview" (never moves a camera on Program).
- **Drag files from Finder**: drop on the input area → new inputs (video, image, photo folder → Photos, PDF → PDF Slides). ⌥ several videos → one List. ⌘ on a tile → replace its file (always asks).
- **MIDI controllers** (Settings › MIDI): learn mode, templates for Akai APC mini mk1/mk2, Korg nanoKONTROL2, Behringer X-Touch Mini, LED tally.
- **Photos**, **PDF Slides** (export PowerPoint/Keynote/Google Slides as PDF) and **Virtual Set** inputs.
- **Desktop Capture audio**: a window captures that app's sound, a display captures the whole Mac (HongMix excluded). "Relaunch Chrome" keeps a hidden Chrome window drawing.
- **Recording safety** (REC ⚙): time left on disk on the REC button and a warning, backup recording to a second disk, continue on another disk when full.
- **Stream monitor** next to STREAM: bitrate graph per destination, drops, SRT RTT/loss, reconnects.

## Fixed
- Recordings survive a crash or power loss (fragmented MOV/MP4).
- A recording that can't be created shows an error instead of looking like it records; MultiCorder failures are shown.
- Broadcast delay is kept across a network drop; audio no longer drifts ahead after upload stalls.
- Live sources: clock drift is compensated (no audio jumps on long shows); cutting a camera back to air is click-free.
- Cameras/capture cards/audio devices reconnect after unplugging and never fall back to the MacBook camera or mic.
- Audio outputs and headphones recover after an interface is replugged.
- "New file every N min" splits without losing frames; file loops are gapless; replay recording no longer stalls the programme on slow disks.
- Desktop Capture lists windows on other desktops (e.g. Chrome in full screen) and no longer goes to "No Signal" when the screen is still.
- 50 device/stream status messages now appear in English in the English UI.

## Verified (M1 Max)
60-min recording soak (A/V drift −14.8 ms, 0 dropped frames) and 60-min SRT streaming soak (drift −5.3 ms); crash-during-recording test; display output 16/16; virtual second monitor 8/8; PTZ (fake VISCA camera, byte-exact) and keyboard; MIDI with virtual devices; file drop from Finder.
Not yet tested with real hardware: PTZ cameras, DeckLink, MIDI controllers, unplugging USB devices.
