# HongMix 1.4.2

## Display output full screen
- Fixed the empty black "Full Screen" desktop left behind after closing an output window that had been put into macOS full screen
  (the window was hidden without leaving full screen and never actually closed).
- The output window no longer uses macOS full-screen Spaces. Its green button fills the display it is on, borderless;
  Esc, double-click or right-click returns to the window's size and position. Swipes and Mission Control can no longer move the broadcast picture away.

## Separate output settings
- Record ⚙ shows recordings only, External ⚙ shows NDI and DeckLink (plus Output 2–4 routing), Stream ⚙ shows streams and return feeds.
  "Add" offers only that kind. Tools › All Outputs… shows everything.

## Monochrome UI (default skin)
- Black and white, colour only where it means something: Program red, Preview green, ON AIR / REC red.
- Floating Liquid Glass top and bottom bars (macOS 26+; translucent material before).
- Monitors: thin tally border, dot + PREVIEW / PROGRAM label, rounded corners. CUT is a white button; Quick Play is outlined.
- Output buttons show live status ("● REC 00:12:31 · 30.0 Mb/s"); ON AIR elapsed time in the top bar.
- Mixer: ON AIR red, ON white, AUTO outlined, MUTE red text; Follow (→) grey.
- Skins: Monochrome and Default (Graphite removed). Settings › General › Appearance.

## Bottom bar
- Display ⚙ opens a display settings panel: mode, display, source, always on top, 16:9, on/off.
- Instant Replay and Scopes moved from Tools to bottom-bar buttons.

## Test API (HongMix extensions)
- MainWindowFullscreen, DisplayOutputMode, OutputWindowZoomButton, OutputWindowSystemFullScreen, OutputWindowFill, OutputWindowExit.

## Output window jumping to another desktop (follow-up fix)
- With the switcher window in macOS full screen, turning Display on made macOS switch to another desktop, so the switcher
  vanished and Display seemed not to work. The output window now opens on the current Space, full-screen Spaces included
  (fullScreenAuxiliary + moveToActiveSpace); presentation options are left alone inside a full-screen Space.
- Fixed: a stale return-from-fill frame reopening the window on the next Esc; a filled window moving to another display on
  screen-parameter changes; the switcher-screen check mistaking the output window for the switcher.

## Cleanup
- Skin cached (no UserDefaults read per colour); a skin change rebuilds every window (.id(language + skin)).
- Monochrome overlay 8 is slate instead of red. Output-button 1 s timer only while on. Removed the unused full-screen exit path and the leftover Graphite string.

## Development builds (important)
- build/cli development builds load FFmpeg from ~/Documents/..., so macOS asks for Documents-folder access and the app hangs at
  launch until answered (asked again after every rebuild because the ad-hoc signature changes). Run and test the app from the DMG
  made by scripts/make-dmg.sh (libraries bundled).

## Verification (M1 Max, one built-in display, DMG build)
- tests/window/test-display-output.sh: switcher normal and in macOS full screen × 8 steps = 16/16 PASS
  (no Space switch, no HongMix full-screen Space added, window sizes and visibility checked).
- Green button: 960×540 → 1728×1117 → Esc → 960×540. scripts/test-core.sh passes. No new build warnings; DMG app has no external library paths.
- Not verified: multiple displays; on-screen look of the Liquid Glass bars.

## Release screenshots
- `screenshots/1.4.2/1.4.2-main-switcher-test-patterns.png` — Monochrome switcher, generated 59.94p inputs and live audio meters.
- `screenshots/1.4.2/1.4.2-display-settings-test-patterns.png` — Output Window / Display Fullscreen and source selection.
- `screenshots/1.4.2/1.4.2-statistics-monitoring-test-patterns.png` — independent monitoring window.
- `screenshots/1.4.2/1.4.2-external-output-settings.png` — NDI, DeckLink and Output 2–4 routing.
- `screenshots/1.4.2/1.4.2-stream-settings.png` — dedicated RTMP/SRT settings and dual-path backup.

The public images use locally generated test patterns only. They contain no people, third-party programme footage or stream keys.
