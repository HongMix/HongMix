# HongMix 2.1.4 (build 111)

## Important after updating

**Remote control is now off by default.** If you use Companion, Stream Deck or the web remote, turn it on once in **Settings › Network › Remote Control**. When off, HongMix does not open ports 8088 or 8099. Existing users who previously selected an access mode keep their choice.

## What's new

- **Virtual Input.** Right-click an input › Create Virtual Input. It reuses the same decoded picture while keeping its own position, crop and layers; playback and sound follow the original. The `CreateVirtualInput` API function is also supported.
- **Layer crop.** Move/Crop modes, orange canvas handles and Left/Right/Top/Bottom sliders let each layer be cropped without loading the source again.
- **Live position preview.** Input Settings › Position shows crop, zoom and placement as they appear in Program.
- **vMix-style double-click.** The first click previews immediately; the second opens Input Settings.
- **Smoother input thumbnails.** Choose 6, 15 or 30 fps in Settings › General › Playback. Program, recording and outputs always stay full rate.
- **Safer Command-W.** ⌘W closes tool windows and sheets, but never the main switcher or Display output.
- **Remote-control privacy.** The new master switch applies immediately and leaves both control ports closed when off.
- **Calmer health reporting.** Display-lag alerts clear after a calm minute, renderer health uses the last five minutes, and off-air meter reads no longer inflate audio-underrun counts.
- **Complete Korean and English UI.** Remaining untranslated labels, launch status lines and language-switching lists were completed; builds now fail if an English translation is missing.

## Verification and limits

- Virtual inputs were saved/reloaded and tested on air at 59.94 fps with no added decoder and zero render drops. Layer crop and live previews were visually verified.
- Core tests, translation checks and ad-hoc signature verification passed.
- Automated inspection covers double-click routing, crop values and ⌘W policy, but physical mouse double-click, crop-handle dragging and ⌘W on every sheet should still be tried once on the target Mac.
- Local CBR SRT loopback held about 1.84–1.95 Mbps with zero frame drops and decode errors, but the MPEG-TS muxer still emitted recurring DTS/PCR warnings; strict receiver compatibility needs further work.
- Reported listening-path audio dropouts were not reproduced. Real Mac speaker/headphone/HDMI/USB/DeckLink routes still need a long listening test.
- This public build is ad-hoc signed and not notarized.
