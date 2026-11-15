# HongMix 2.2.5 (build 134)

HongMix 2.2.5 turns the web remote into a responsive browser-based switcher and adds a complete illustrated English and Korean user manual. It includes the unpublished 2.2.4 tally and remote-control work.

## The switcher in a browser

- The web remote follows the app: Preview, transition controls, Program, input tiles, Audio Mixer, overlays 1–8, T-Bar and FTB.
- Tap an input tile for Preview, use its **Cut** button to take it straight to Program, and use **1–8** to put that input on an overlay. Media tiles include restart and play/pause; Program includes transport and seek controls for the media on air.
- Record, Stream and External always ask for confirmation. This also fixes Stream stopping and then starting again after a long press.
- Switch between Korean and English on the page, and open built-in help with **?**.

## Laptop, iPad and phone layouts

- Desktop and iPad landscape use the full switcher layout with a side panel.
- iPad portrait uses two monitors, a transition strip, four-column input tiles and bottom tabs.
- Phones use compact monitors, two-column input tiles and Switcher, Audio, Title and More tabs. The layout recalculates after rotation.
- Camera tally is view-only, requires no password and asks the device to keep its screen awake.

## Complete illustrated manual

- The [English manual](manual/HongMix-Manual.en.md) and [한국어 설명서](manual/HongMix-Manual.ko.md) each have 16 chapters and 14 language-matched screenshots.
- They cover installation, the main screen, inputs, switching, overlays, Position and Layers, audio, titles, outputs, replay, captions, broadcast safety, web remote, tally, API, settings and troubleshooting.
- Public screenshots use generated test patterns. Device names and private/public IP addresses were replaced with documentation examples.

## Verification

- Virtual switcher UI suite: desktop 65/65, iPad 65/65, phone 66/66.
- Real-app integration suite: 47/47 with 0 dropped frames.
- Translation checks, core tests, checksum verification, DMG verification and ad-hoc signing checks passed.
- The tests found and fixed a phone overflow that expanded a 390 px page to 515 px.

## Known limitations

- Physical phone and iPad testing is still pending; the responsive layouts were tested at their actual viewport sizes in a browser.
- The page polls every 0.4 seconds on desktop and 0.7 seconds on smaller layouts. A previous load test measured about 10% CPU for seven busy clients.
- The public app is ad-hoc signed and is not Apple-notarized yet.
