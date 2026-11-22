# HongMix 2.3.0 — handoff (Claude → GPT)

Date: 2026-11-22 · Repo: local `main`, last commit `9547e0e` = v2.2.8 (published). Everything below is **uncommitted** on top of it.

**Publish 2.3.0** — one fix: H.264 outputs now carry their frame rate in the stream header. (Built first as 2.2.9, build 142, never published; the user chose to release it as **2.3.0**. Don't publish 2.2.9.)

## 1. State
| What | Value |
|---|---|
| Version | `Resources/Info.plist` **2.3.0**, build **143** (142 = the unpublished 2.2.9, same code) |
| Installers | `build/dist/HongMix-2.3.0.dmg` / `.pkg`, ad-hoc signed |
| SHA-256 | DMG `f5fe38cca107d1fb636df287a9078dec4b0b2a3515b65c5b8bc8030124540989` · PKG `0cc11fdac115a82250b4feecc40aeb11c483caf01035f123c625dab760051fc5` |
| Changed | `Sources/Core/mc_output.c`, `Resources/Info.plist`, this file, `docs/test-results/2.3.0/` |
| Don't commit | `Blackmagic-settings-backup-2026-11-16/` (user's own folder, untracked), `docs/screenshots/2.0.9/*`, `build/`, `HongMIX-signing/` |

## 2. The problem
User sent a 1080p59.94 SRT stream from HongMix 2.2.8 to an AJA BRIDGE LIVE; its input detector showed `H.264 1920x1080p @58.94Hz` instead of 59.94.
- HongMix's timestamps are exact: one PTS per render tick, time base 1001/60000 (`drops 0 · queue 0/8` in the stream window).
- But the VideoToolbox H.264 encoder writes **no VUI** in the SPS (`vui_parameters_present_flag = 0`, verified with `trace_headers`), so the stream carries no frame rate. Receivers that read it from the header have to guess from arrival / timestamps; BRIDGE LIVE's guess came out one frame per second low (58.94 = 59.94 − 1).
- libx264 always writes VUI timing, which is why software-encoded streams never showed this.

## 3. Fix (`mc_output.c`)
- New `open_timing_bsf()`: for H.264 VideoToolbox outputs (stream, SRT, recording — not the instant-replay packet store) an `h264_metadata` bitstream filter with `tick_rate = 2 × fps` (59.94 → 120000/1001, 29.97 → 60000/1001, 50 → 100/1) adds `timing_info` to the SPS. Header only; picture data and timestamps are untouched.
- The stream's `codecpar` (extradata for MP4/MOV global headers) is taken from the filter's output, also for split recording files.
- Packets go through the filter 1-in-1-out; a packet the filter rejects is passed through unchanged; if the filter can't be created the output works as before. Freed with the session.
- `fixed_frame_rate_flag` is deliberately not set (setting it on a VUI created from scratch makes FFmpeg's writer fail on the inferred `low_delay_hrd_flag`).

## 4. Verification
- Same encoder with the filter (ffmpeg 9 CLI, 59.94 test pattern): SPS gets `timing_info_present_flag 1, num_units_in_tick 1001, time_scale 120000`; ffprobe `r_frame_rate 60000/1001`; decodes cleanly.
- `scripts/test-core.sh` PASS — its recording goes through the real output path with VideoToolbox: SPS now has `timing_info_present_flag 1` (`time_scale 60 / num_units_in_tick 1` = its 30 fps setting).
- **Verified by the user on the AJA BRIDGE LIVE** with the same code (installed as 2.2.9, build 142): the input detector now shows 59.94.
- 2.3.0 (build 143): `check-i18n.py` PASS, `test-core.sh` PASS, `hdiutil verify` VALID.

## 5. How to publish
1. Use the DMG/PKG as is (if you rebuild: build **144**).
2. Commit as `Seunghoon Hong <176268839+HongMix@users.noreply.github.com>`: `Sources/Core/mc_output.c`, `Resources/Info.plist`, `docs/HANDOFF-2.3.0.md`, `docs/test-results/2.3.0/*`. Never add `HongMIX-signing/`, `build/`, `docs/screenshots/2.0.9/*`, `Blackmagic-settings-backup-2026-11-16/`.
3. Release notes `docs/RELEASE-NOTES-2.3.0.md` / `.ko.md` / `-GITHUB.md` from §6. No new screenshots (no UI change). US spelling; read EN against KO.
4. Manuals (`docs/manual/HongMix-Manual.ko.md` / `.en.md`): title and installer names 2.2.8 → 2.3.0 (lines 1, 34, 40); optional FAQ line: "A receiver shows 58.94 instead of 59.94 → update to 2.3.0".
5. README "Latest update"; `gh release create v2.3.0 --repo HongMix/HongMix --latest`, same asset set as v2.2.8.

## 6. Release-note bullet (KO / EN)
- **H.264 송출·녹화에 프레임레이트 정보 기록** — AJA BRIDGE LIVE 등 수신 장비가 59.94를 58.94로 잘못 인식하던 문제 수정 / **H.264 streams and recordings now carry their frame rate** — fixes receivers such as AJA BRIDGE LIVE detecting 59.94 as 58.94.
