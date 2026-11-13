# HongMix 2.1.7 (build 117)

## Precise Position and Layer editing

- Every Position and Layer value has a number field with −/+ buttons. Arrow keys change one step; Shift changes ten.
- A gray margin keeps boxes and handles reachable outside the frame and reports the overflow in pixels.
- Arrow keys nudge by 1 px (Shift: 10 px), and Command-Z or the Undo button restores placement changes.
- Layers add opacity, rotation, lock, Fit in Frame, Center, Source Aspect, Full Screen and Copy/Paste Position.

## Crop, transparency and compatibility

- Layer crop now fits or fills the cropped source into its box, matching the vMix rectangle workflow.
- Earlier projects are converted on open so existing cropped layouts keep their previous appearance.
- Trim Transparent Background now works for supported alpha graphics and explains inline when a source has no transparent edge.

## AI Upscaling and performance

- Optional AI Upscaling uses Apple's real-time VideoToolbox model for supported low-resolution on-air sources. It is off by default and requires macOS 26 or later.
- Unchanged layer compositions are cached and changed compositions share one GPU wait per frame. In the measured layer-heavy 1080p29.97 scene, average render time improved from 5.91 ms to 3.07 ms.

## Stability and verification

- Fixed non-finite API/field values that could crash the app or prevent project saving, stale upscaled off-air frames, failed-upscaler retry behavior, resolution-change results, layer editing races and a nested-layer batch delay.
- A 40-minute automated soak completed with 0 dropped frames, 0 API errors, 0 restarts and flat 302–365 MB RSS.
- Resolution changes 360p → 480p → 1080p → 360p completed with 0 drops. Core tests, translation checks, installer checksums, DMG verification and ad-hoc app signing passed.

## Known limitations

- Physical mouse drags, arrow-key nudge, number-button clicks, field typing and Command-Z still need wider hands-on verification.
- Undo history lasts for the current app session only.
- Rotated-layer crop handles change crop without moving the box edge.
- The public app is ad-hoc signed and is not Apple-notarized yet.
