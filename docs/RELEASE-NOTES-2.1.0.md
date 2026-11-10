# HongMix 2.1.0

- **Video loop default:** new video inputs no longer loop by default. Change it under Settings › General › Playback. Existing projects keep each input's saved loop state.
- **Fit / Fill / Stretch and X/Y zoom:** match wide LED walls and non-16:9 sources with separate horizontal and vertical zoom controls.
- **Reliable quit:** HongMix now quits correctly even when a settings sheet or focused text field is open.
- **Sleep-aware monitoring:** Mac sleep and lid-close pauses are reported as a warning instead of inflating dropped-frame counts.
- **Clear stream warning:** STREAM and the affected output blink orange while connecting, reconnecting or in an error state.

Verified on an Apple M1 Max: loop defaults, Fit / Fill / Stretch, X/Y zoom, XML reporting and quit through keyboard, menu, Apple Event and SIGTERM. The Metal build and core SRT test passed. A real lid-close sleep cycle and the on-screen orange disconnected-stream state were not directly tested for this release.

## API additions

- `SetZoomX`, `SetZoomY`
- `SetFitMode`, `SetPositionFit` with `fit|fill|stretch`
- `SetZoom` resets X/Y to proportional zoom; XML reports effective `zoomX` and `zoomY`.

## First launch

HongMix is ad-hoc signed and not yet Apple-notarized. If macOS blocks it, use System Settings › Privacy & Security › Open Anyway, or run `xattr -dr com.apple.quarantine /Applications/HongMix.app`.
