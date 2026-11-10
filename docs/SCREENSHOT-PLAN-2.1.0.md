# HongMix 2.1.0 screenshot plan

Public screenshots must use generated test media only. Do not show real people, third-party programme footage, stream keys, IP addresses or personal project names. Produce matching Korean and English captions.

| # | Feature | Capture | Safe test method | Public caption |
|---|---|---|---|---|
| 1 | New video loop default | Settings › General › Playback with “New video input default loop” off; a newly added test-video tile with Loop inactive | Generated 10 s colour bars/video; no user project | New videos start once · opt in to looping |
| 2 | Fit / Fill / Stretch + X/Y zoom | One 1440×1080 generated grid shown as a 2×2 comparison: Fit, Fill, Stretch, Zoom X 1.333 | Generated labelled aspect-ratio grid | Match non-16:9 sources and wide LED walls |
| 3 | Quit with a sheet open | Settings or Captions sheet open with a small callout “⌘Q / menu / Dock quit supported” | Static explanatory capture; do not actually interrupt an on-air session | Quit safely even while settings are open |
| 4 | Disconnected stream warning | STREAM button and one output row blinking orange, with all destinations pointed to an unreachable local test port | Loopback-only dummy destination; never use a real stream key | Orange means connecting, reconnecting or error |

## Do not stage as a claimed verification screenshot

- Real lid-close sleep: not directly tested for this release. Document it as an unverified implementation note until a controlled off-air test is completed.
- A still image cannot prove blinking. If the orange stream warning is published, include a short screen recording or two-frame GIF in addition to the still.

## File names

- `guide-01-loop-default-ko.png` / `guide-01-loop-default-en.png`
- `guide-02-fit-fill-axis-zoom-ko.png` / `guide-02-fit-fill-axis-zoom-en.png`
- `guide-03-quit-with-sheet-ko.png` / `guide-03-quit-with-sheet-en.png`
- `guide-04-stream-warning-ko.png` / `guide-04-stream-warning-en.png`
- Optional motion proof: `guide-04-stream-warning.mp4`
