# HongMix 2.1.6 (build 114)

## What's new

- **Edit Position and Layers on the picture.** Drag inside to move, use yellow corners to resize, orange edge handles to crop, and Option-drag to slide the visible part. No mode switch is required, and values are shown in output pixels.
- **The preview stays visible.** Position and Layers keep the Program-matched picture fixed on the right while controls scroll on the left.
- **Trim Transparent Edges.** Title and PNG layers can remove empty alpha margins so Fill uses the actual graphic rather than its full transparent canvas.
- **Virtual Input audio fix from 2.1.5.** When a Virtual Input is on air and its original input uses Auto audio, the original audio now follows video correctly.

## Verification

- Position render geometry and pixel readout matched the Program calculation in a 1080p59.94 graphics-only test.
- The two-layer editor rendered its list, editable pixel fields, crop controls and selected canvas handles correctly.
- Core tests, translation checks, installer checksums and ad-hoc signature verification passed.

## Known limitations

- Physical mouse dragging (move, resize, crop and Option-drag) and Trim Transparent Edges still need wider hands-on testing.
- Layer locking and copying/pasting placement between layers are not implemented yet.
- Input resize preserves aspect ratio; independent X/Y zoom remains available through the sliders.
- This public build is ad-hoc signed and is not Apple-notarized yet.
