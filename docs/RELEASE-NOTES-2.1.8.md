# HongMix 2.1.8 (build 119)

HongMix 2.1.8 includes all Position, Layer, AI Upscaling and performance work from 2.1.7, plus reusable presets and multi-layer editing.

## Layer presets

- Save a layer's position, size, crop, rotation, opacity, border and Fit/Fill by name, then apply it to any layer in any input or project.
- Presets are stored app-wide and survive relaunch. They do not change the layer's source input, visibility or lock state.
- Rename and delete presets from the menu. Applying a preset is one Undo step.
- Companion and Stream Deck workflows can use `LayerPreset` and `LayerPresetSave`.

## Several layers at once

- Shift-click or Command-A in the picture to select several layers, then move or nudge them together.
- Align left, horizontal center, right, top, vertical center or bottom; space evenly across/down; match width, height or both.
- Choose Selected boxes, Frame or First selected box as the alignment reference. Locked layers stay fixed.
- Moving boxes now snap to the edges and centers of other visible layers.
- Cropping a rotated layer moves that edge of its box like an unrotated layer.

## Included from 2.1.7

- Exact number fields and −/+ controls, 1 px arrow-key nudge, Undo and a gray margin for off-frame boxes.
- Layer opacity, rotation, lock, Fit in Frame, Center, Source Aspect, Full Screen and Copy/Paste Position.
- Corrected layer crop and transparent-background trimming with automatic conversion of earlier projects.
- Optional AI Upscaling for supported low-resolution on-air sources and faster cached layer composition.

## Stability and verification

- Fixed seven review findings in build 119, including spacing around locked layers, heavily cropped handle jumps, duplicate preset renames, damaged stored presets and stale drag state.
- A 10-minute automated soak applied presets about 85 times while switching, changing layers and toggling upscaling: 0 dropped frames, 0 errors, 0 restarts; memory remained flat at 344–450 MB.
- Core tests, translation checks, checksums, DMG verification and ad-hoc app signing passed.

## Known limitations

- Physical Shift-click, group drag, snapping, rotated crop drag, Command-A, arrow keys and the preset-name dialog still need wider hands-on verification.
- Alignment and distribution use the unrotated box of a rotated layer.
- Presets are app-wide, not embedded in project files; moving a project to another Mac does not move its presets.
- Undo history lasts for the current app session only.
- The public app is ad-hoc signed and is not Apple-notarized yet.
