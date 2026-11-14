# HongMix 2.2.0 (build 121)

HongMix 2.2.0 includes the Position, Layer, AI Upscaling, preset and multi-layer editing work from 2.1.7–2.1.8, plus a fix for repeated Shortcuts activity in the macOS menu bar.

## Menu bar and upscaling status

- HongMix no longer runs its Do Not Disturb shortcut every 30 seconds. It now checks at launch, when the top-bar button is used and when the operator switches back to HongMix.
- In a roughly 27-minute process watch, the shortcut ran at app startup and shutdown but never during the 15-minute playout period.
- AI Upscaling now reports `waiting` while its input is off air, then changes to running in Preview, Program or an on-air layer.

## Included editing features

- Edit Position and Layers directly on a Program-matched preview with numeric values, crop handles, rotation, opacity, lock, Undo and off-frame canvas space.
- Save reusable layer placement presets across inputs and projects.
- Shift-click or Command-A to select, move, align, distribute and resize several layers; boxes snap to other layers' edges and centers.
- Earlier project files are converted on open to preserve the visible result of their crop settings.

## Compatibility and stability

- All 22 synthetic test files loaded and played: H.264, HEVC 4K/Main10, ProRes 422/4444 alpha, VP9, AV1, MPEG-2, vertical and interlaced video, mono/44.1 kHz/PCM/AC-3 5.1/audio-only sources, PNG/JPG/GIF and alpha images.
- A 15-minute build-120 soak with all 22 inputs loaded reported 0 dropped frames, 0 errors, 0 restarts and flat 1,055–1,120 MB memory. The worst measured render frame was 9.1 ms against a 33 ms frame interval.
- After the upscaling status fix, a 5-minute build-121 rerun also reported 0 dropped frames and 0 errors, with flat 1,070–1,149 MB memory.
- A project rewritten in the 2.1.6 format reopened with all 22 inputs and its previous crop appearance preserved.
- Core tests, translation checks, checksums, DMG verification and ad-hoc app signing passed.

## Known limitations

- Physical Shift-click, group drag, Command-A, snapping while dragging, rotated crop drag, arrow keys, Command-Z, number fields and the preset-name dialog still need wider hands-on verification.
- The menu bar icon itself still needs visual confirmation on the user's normal desktop workflow.
- Alignment and outlines use the unrotated box of a rotated layer. Presets are app-wide rather than embedded in project files. Undo history lasts for the current app session.
- The public app is ad-hoc signed and is not Apple-notarized yet.
