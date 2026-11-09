# HongMix 2.0.9

## New
- **AI background removal** (Input ⚙ › Key): keeps people, no green screen needed. Background transparent / blur / image; quality Fast (default, ≈10 ms per 1080p frame) / Balanced / Accurate. Runs on the Mac and never makes the programme wait.
- **Replay clip export** (⬇ on a clip, ⌘ for several): horizontal 16:9, vertical 9:16, square 1:1 (crop position), clip angle or every angle, normal / 50 % / AI slow motion, 0–2 s handles, H.264 / HEVC / ProRes. Runs in the background without pausing the programme or replay playback.
- **New caption engine** (macOS 26+): one continuous long-form recognition session — no one-minute restarts, so sentences are no longer lost. On-device, word-by-word within about a second, SRT with the real spoken times. Older macOS keeps the classic engine.
- **Caption look** (Tools › Captions): Right column / Bottom cinema / Bottom band / Custom; lines, characters per line, font size, letter spacing, line spacing, gap, glyph width, position and size, alignment, background (per line / box / band / none) and opacity, colour, outline, font, and an "AI captions" label (on/off, text, size, position). Lines scroll up; the sentence being spoken shows in light blue. The video is never resized.
- **Reading pace**: a line stays at least 1.5 s (adjustable); a long backlog catches up automatically.
- **Glossary and corrections**: 440 Korean parliamentary/budget terms are given to the recogniser, and fixed spellings are corrected literally (e.g. "국정 감사" → "국정감사"). Files can be replaced.
- "Send test sentence" and "Clear captions" buttons, plus API functions for captions, background removal and replay export (Companion/MIDI).

## Fixed
- Captions froze after a long time: failed recognition requests were retried instantly without limit and exhausted the Mac's speech service. Retries now back off and the state is shown.
- Audio that arrives while recognition reconnects is no longer dropped.
- Captions no longer squeeze into one shrinking line — they wrap.
- Lines no longer get scrambled or cleared mid-speech when Korean spacing is revised.
- Translating into the spoken language counts as off; a failed translation shows a hint instead of retrying.
- Preview monitors follow the screen their window is on and keep drawing if the display clock stops.
- All number fields in the settings now share one layout; clipped labels fixed (MIDI Learn, Virtual Set, Replay sources, title editor) plus empty-state hints.

## Verified (M1 Max)
- **Captions**: 25 s Korean speech looping.
  - Classic engine (2 min): lost whole sentences.
  - New engine (3.5 min): 8 of 8 loops complete, one misrecognised word, 0 speech-service errors.
- **Background removal**: Fast 10.4 ms at 1080p59.94, programme render 1.0 ms, 0 drops.
- **Replay export**: horizontal, vertical and square, slow motion, ProRes and HEVC files checked.

Not yet tested: captions in real meetings (overlapping speakers, noise), background removal with a live camera, a second monitor. Quit doesn't work while a settings sheet is open — close it first.
