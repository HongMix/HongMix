# HongMix 1.4.2 — handoff (Claude → next engineer)

Date: 2026-11-06 · Mac used: Apple M1 Max, macOS 27.3, one built-in display (3456×2234, UI 1728×1117).

## 1. Where things are

| What | Where |
|---|---|
| Source (this repo) | `/Users/deanhong/Documents/ChatGPT/HongMIX` |
| Git | base `acd86e4` (Release 1.4.0) → handoff commit on branch `claude/1.4.2` (not pushed) |
| Previous state backup | `../HongMIX-backup-1.4.1/` (sources before 1.4.2, without build/ThirdParty) |
| Installers | `build/dist/HongMix-1.4.2.dmg`, `.pkg` (ad-hoc signed, LGPL FFmpeg bundled) |
| Release notes | `docs/RELEASE-NOTES-1.4.2.md` / `.ko.md` (1.4.1 notes: `docs/RELEASE-NOTES-1.4.1*.md`) |
| Window regression test | `tests/window/test-display-output.sh` (+ `spaces.swift`, `windows.swift`) |

Version: `Resources/Info.plist` 1.4.2 (build 61). The user identifies builds by version — bump it every build.

## 2. What 1.4.2 changed (files)

- **Display output / full screen** — `Sources/App/UI/FullscreenOutput.swift`
  - Output windows never use macOS full-screen Spaces (`.fullScreenNone`, borderless fill). The 1.4.1 bug: a window put into
    macOS full screen was only ordered out, never left full screen nor closed → empty black "Full Screen" desktop.
  - Green (zoom) button is retargeted to `fillDisplay(_:)`: borderless fill of the window's display; Esc / double-click /
    right-click → `exitPressed()` returns to the saved frame. `hide()` = close completely (clears the return frame);
    `closeWindow()` = internal close that keeps it.
  - Opens on the active Space incl. full-screen Spaces (`.fullScreenAuxiliary + .moveToActiveSpace`). Before this, with the
    switcher in macOS full screen, macOS jumped to another desktop and the switcher disappeared ("full screen doesn't work").
  - `switcherWindow` finds the switcher window (not `NSApp.mainWindow`, which can be the output window).
  - Fill follows its own display on screen changes; if that display is unplugged it returns to the window.
- **Per-gear output settings** — `Sources/App/UI/OutputsSheet.swift`: `scope` from `focusKind`
  (Record → record, External → ndi+decklink (+ Output 2–4 bar), Stream → stream + return feed). Tools › All Outputs… = everything.
- **Monochrome skin (default)** — `ContentView.swift` (`AppSkin`, `Theme`, `HMGlass`, `TopBar`, `MonitorPane`, `BottomBar`,
  `OutputBarButton.monoLabel`, `OnAirChip`, `FullscreenBarButton`, `DisplaySettingsPanel`, `ToolBarWindowButton`),
  `SwitcherPanels.swift` (`FlatButton.Style`, tile header/tally border, `InputAudioState` colours), `AboutView.swift` (picker).
  - Skins: `mono` and `classic` only (Graphite removed). One-time migration to mono (`appSkinRev` = 2).
  - `AppSkin.current` is cached; `HongMixApp` calls `AppSkin.sync(skin)` and uses `.id(language + skin)` on every window.
  - Glass: `.glassEffect` on macOS 26+, `.ultraThinMaterial` fallback. Tally: Program red, Preview green (mono only).
- **Bottom bar** — Display ⚙ = `DisplaySettingsPanel` popover; Replay and Scopes buttons (moved out of Tools).
- **Outputs.swift** — `liveSince` (start time while running) for the bar timers.
- **Localisation** — every new Korean key is in `Resources/en.json` (L()/Lf() keys are the Korean text). Keep it that way:
  the user runs the English UI and wants both languages.
- **Test API (HongMix extensions, APIFunctions.swift)** — `MainWindowFullscreen` (on/off/toggle), `DisplayOutputMode`
  (window/fullscreen), `OutputWindowZoomButton` (real click), `OutputWindowSystemFullScreen` (⌃⌘F), `OutputWindowFill`,
  `OutputWindowExit`.

## 3. Build, run, test

```bash
bash scripts/build-cli.sh release          # compile check → build/cli/HongMix.app (dev build)
bash scripts/make-dmg.sh                   # DMG + PKG in build/dist (libraries bundled) — use this app to run/test
bash scripts/test-core.sh                  # C core tests
bash tests/window/test-display-output.sh   # needs the app running (API :8088); prints PASS/FAIL per step
```

**Important:** do not run the dev build from another folder. It links FFmpeg from `~/Documents/.../build/ffmpeg-lgpl/lib`,
so macOS shows a Documents-folder access prompt and the app hangs at launch (inside dyld) until it is answered — again after
every rebuild. Mount the DMG and copy `HongMix.app` out instead (`otool -L` shows only `@rpath`/system paths).

Quit the app cleanly with `kill -TERM <pid>` (it autosaves); check `<recording>`/`<streaming>` in `http://127.0.0.1:8088/api/` first.
Screen capture tools need Screen Recording permission; the app's own `SnapshotWindow` API does not render the glass bars.

## 4. Verified (this Mac)

- Window test: switcher normal and in macOS full screen × 8 steps = **16/16 PASS** (no Space switch, no HongMix full-screen Space,
  window sizes 960×540 ↔ 1728×1117).
- `scripts/test-core.sh` exit 0. Release build: no new warnings. DMG app: no external library paths, signature valid.

## 5. Not verified / open items

1. **Multiple displays** (output on a second monitor, unplug/replug while filled).
2. **Look of the glass bars** on screen (only verified by the user's eye so far; snapshot API can't capture them).
3. **Stream monitoring popover** (proposed, not built): per-destination status, bitrate graph, drop counts next to the Stream button.
4. Black "Full Screen" desktops left from 1.4.1 sessions stay until closed in Mission Control (×). Two current full-screen Spaces
   on this Mac are Chrome windows (one shows the HongMix remote page) — not HongMix.
5. ad-hoc signing: other Macs show the unidentified-developer warning; Developer ID + notarisation needed for clean installs.

## 6. Working rules from the user

- Show a UI mockup image and get approval before UI changes.
- Bump the version for every build; put the built app on the Desktop as `HongMix <version>.app`.
- The user also uses other Apple Silicon Macs: detect per-chip capabilities instead of assuming this M1 Max.
- Korean and English UI both required.
