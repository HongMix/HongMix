# HongMix 2.2.0 — handoff (Claude → GPT)

Date: 2026-11-14 · Mac: Apple M1 Max, macOS 27.3 · Repo: local `main`, base commit `bdb4a8d` = v2.1.8 (published)

**Publish 2.2.0.** 2.1.7 and 2.1.8 are already published and remain in GitHub history. Publish **2.2.0** above them as the latest release; it contains both plus the Focus fix below. The 2.2.0 changes are uncommitted on top of `bdb4a8d`. Details per part:

| Part | Doc |
|---|---|
| Position / Layers value entry, opacity, rotation, Trim fix, AI upscaling, layer compose speed-up, stability fixes | `docs/HANDOFF-2.1.7.md` |
| Layer presets, several layers at once (align / space / size), snap to other layers, rotated crop | `docs/HANDOFF-2.1.8.md` |
| Menu bar flicker (Focus shortcut every 30 s) — fixed; test media; 20-min compatibility + stability test | this file |

## 1. State

| What | Value |
|---|---|
| Version | `Resources/Info.plist` **2.2.0**, build **121** (120 = test build before the upscaler status fix in §6.4) |
| Installers | `build/dist/HongMix-2.2.0.dmg` / `.pkg`, ad-hoc signed (`SIGN_ID="-"`) |
| SHA-256 | DMG `8b92d3a0c68a0c314c0dd2b1179be9fe43a1e903a023cd602feaefe99c216ef8` · PKG `e4348863d0f343aeaaff95e1cc4d4167c2676e7dddd4a1c1f191d4194d511823` (`build/dist/SHA256.txt`) |
| Copy for the user | `~/Desktop/HongMix/HongMix 2.2.0 배포/` (DMG, PKG, SHA256.txt, `screenshots/`), `~/Desktop/HongMix 2.2.0.app` |
| Test media | `~/Desktop/HongMix/HongMix 2.2.0 테스트 파일/` (22 files, ~350 MB) — re-create with `scripts/make-test-media.sh` |
| Test results | `docs/test-results/2.2.0/` (contact sheet of all 22 files on Program, `compat.csv`, stability logs, shortcut-run log) — also in the Desktop 배포 folder |
| Screenshots | `docs/screenshots/2.2.0/` — **separate KO and EN files** (01 Position editor, 02 Layers editor + presets, 03 several layers / align) |

## 2. How to publish
1. Use the DMG/PKG as is (if you rebuild: build **122**, `SIGN_ID="-" bash scripts/make-dmg.sh`). `scripts/test-core.sh` PASS, `check-i18n.py` PASS, `hdiutil verify` VALID.
2. Commit as `Seunghoon Hong <176268839+HongMix@users.noreply.github.com>`. The 2.2.0 changes include `FocusGuard.swift`, the upscaler waiting-state files, `scripts/make-test-media.sh`, `docs/test-results/2.2.0/*`, `docs/HANDOFF-2.2.0.md` and `docs/screenshots/2.2.0/*`. **Never add** `HongMIX-signing/`, `build/`, or the test media (generated, large). (`docs/screenshots/2.0.9/*` are old untracked leftovers — not part of this release.)
3. Release notes `docs/RELEASE-NOTES-2.2.0.md` / `.ko.md` / `-GITHUB.md` = 2.1.7 §7 + 2.1.8 §5 + §4 here. **KO notes / KO README use `ko-*.png`, EN notes / EN README / GitHub release use `en-*.png` from `docs/screenshots/2.2.0/` — never mix.** EN text in US spelling like the app (color, center, gray); read the EN notes once against the KO before publishing. README "Latest update"; manuals + `docs/FUNCTIONS.md` (new API: `SetLayerOpacity`, `SetLayerRotation`, `SetLayerRect`, `LayerTrim`, `UpscaleOn/Off/Upscale`, `LayerPreset`, `LayerPresetSave`; XML `<inputUpscaleStats>`).
4. `gh release create v2.2.0 --repo HongMix/HongMix --latest`, same asset set as v2.1.6.

## 3. Menu bar flicker fixed (`FocusGuard.swift`)
User: an icon kept popping in and out of the menu bar. Cause, measured on the installed app: HongMix ran `shortcuts run "HongMix Focus"` (status check for the Do Not Disturb lamp) **every 30 s** since 2.1.1 (≈120 runs/hour); macOS shows the Shortcuts "running" icon in the menu bar for each run.
Now: no periodic check. The Focus state is read when HongMix starts, when the top-bar Do Not Disturb button is used (it reads the state as it switches), and when the operator comes back to HongMix from another app (`NSApplication.didBecomeActiveNotification`, at most once per 10 s) — e.g. after changing Focus in Control Center. Trade-off: if Focus is changed while HongMix stays in front, the lamp updates on the next return to HongMix or button press.
Verified (process watch every 50 ms for ~27 min, `docs/test-results/2.2.0/shortcut-runs-27min.log`): the shortcut ran only at app start (2 runs: status, Do Not Disturb on) and at quit (1 run: off) — **no run during 15 min of playout**. Before (installed 2.1.8): a run every 30.0 s (15:28:18, :48, 15:29:18, :48, 15:30:18 …).

## 4. Release-note bullet (KO / EN) — add to the 2.1.7 and 2.1.8 lists
- **메뉴 막대 아이콘 깜빡임 해결** — 방해 금지 상태를 30초마다 단축어로 확인하던 것을 없애고, 앱을 켤 때·버튼을 누를 때·HongMix로 돌아올 때만 확인 / **No more menu bar flicker** — HongMix no longer runs its Do Not Disturb shortcut every 30 seconds; it checks at launch, when you use the button, and when you switch back to HongMix.

## 5. Test media (`scripts/make-test-media.sh <folder> [seconds]`)
Synthetic only (test patterns, color bars, sine tones) — safe for public screenshots. 20 s clips:

| # | File | What it exercises |
|---|---|---|
| 01 | H.264 1080p29.97, AAC stereo 48k | everyday file |
| 02 | H.264 720p59.94 | high frame rate |
| 03 | H.264 640×360 25p, mono AAC 44.1k | low-res (AI upscaling ×2), mono, 44.1k |
| 04 | H.264 1080p50 color bars | PAL-rate HD |
| 05 | HEVC 2160p30 | 4K decode + downscale |
| 06 | HEVC 1080p 10-bit, no audio | Main10, silent file |
| 07 | ProRes 422 HQ 1080p23.976, PCM 24-bit | edit-suite file, 23.976 |
| 08 | ProRes 4444 + alpha, lower third on transparent 1080p | alpha, overlay, Trim |
| 09 | VP9 1080p30 + Opus (WebM) | browser / screen-recording codecs |
| 10 | MPEG-2 720×576 25i TFF + MP2 | PAL SD interlaced, 4:3 |
| 11 | H.264 720×480 29.97i TFF | NTSC SD interlaced |
| 12 | H.264 1080×1920 | vertical phone video |
| 13 | AV1 1080p30, no audio | AV1 software decode |
| 14 | H.264 1080p + AC-3 5.1 (MKV) | 6-channel audio, MKV |
| 15 | H.264 720p, 2 s | very short clip, end / loop |
| 20–22 | WAV 48k / MP3 44.1k / M4A 48k | audio-only files |
| 30–33 | PNG 1080p, PNG alpha logo, JPG 4032×3024, animated GIF | images, alpha, large photo, GIF |

## 6. 20-minute compatibility + stability test (build 120, watched live)
User's project and defaults backed up first and restored byte-identical afterwards; API local-only during the test, off again after. The test media were copied to a temporary folder (no Desktop/Documents access → no macOS permission prompt).

### 6.1 Compatibility — every file on Program (5 s each)
All 22 files load and play; no crash, no signal loss, 0 dropped frames. Contact sheet: `docs/test-results/2.2.0/compat-22-files-program.png`; table: `compat.csv`.

| Files | Decode | Measured fps | Audio meter | Picture |
|---|---|---|---|---|
| 01 H.264 1080p29.97 · 02 720p59.94 · 03 360p25 mono 44.1k · 04 1080p50 | VideoToolbox | 29.96 / 59.91 / 25.00 / 49.99 | moving | correct |
| 05 HEVC 2160p30 · 06 HEVC 10-bit | VideoToolbox | 29.97 / 29.98 | 05 moving, 06 silent (no track) | correct (4K downscaled) |
| 07 ProRes 422 HQ 23.976 PCM24 · 08 ProRes 4444 alpha | VideoToolbox | 23.97 / 29.98 | 07 moving | 08: lower third, transparent elsewhere |
| 09 VP9 + Opus (WebM) | VideoToolbox | 29.98 | moving | correct |
| 10 MPEG-2 576i25 · 11 H.264 480i29.97 | Software | 25.00 / 29.97 | moving | 4:3 pillarboxed, no combing |
| 12 vertical 1080×1920 | VideoToolbox | 29.97 | moving | pillarboxed |
| 13 AV1 | Software (dav1d) | 29.98 | silent (no track) | correct |
| 14 H.264 + AC-3 5.1 (MKV) | VideoToolbox | 29.97 | moving (6 ch → mix) | correct |
| 15 2-second clip, 33 GIF | VT / Software | — | — | play to the end and stop (new video inputs don't loop by default — vMix behavior); loop on → loop |
| 20–22 WAV / MP3 / M4A | — | — | moving | black (audio only) |
| 30–32 PNG / PNG alpha / JPG 4032×3024 | — | — | — | correct; alpha transparent; 4:3 photo pillarboxed |

### 6.2 Stability — 15 minutes, all 22 inputs loaded and looping
Load: Program changed every 8 s (Cut/Fade, random input incl. 4K HEVC, ProRes, AV1, interlaced SD), a layered input (4 video layers, one rotated + semi-transparent) gets a random preset every 7 s, the ProRes alpha lower third flies in/out on Overlay 1 every 20 s, a PNG logo toggles on Overlay 2, AI upscaling on the 360p / 576i / 480i inputs switched off/on every 90 s.

| Measure (15 min, build 120) | Result |
|---|---|
| Dropped frames | **0** |
| Errors / app restarts / signal loss | 0 / 0 / 0 |
| Memory (RSS) | 1,055–1,120 MB with 22 inputs incl. 4K HEVC and ProRes, flat |
| Render | avg 1.1–2.6 ms, worst single frame 9.1 ms (frame = 33 ms) |
| AI upscaling (360p, 576i, 480i) | ×2 when on air; 0 failures |

Log: `docs/test-results/2.2.0/stability-15min-build120.log`.

### 6.3 Project compatibility
The 22-input test project was rewritten in **2.1.6 form** (no `opacity` / `rotation` / `locked` / `cropFills` on layers, no `upscale` on inputs, a layer cropped L25 R5 T10 B20 in the old meaning) and opened in 2.2.0: all 22 inputs load and play, 0 drops; the old cropped layer is converted exactly (x 0.1→0.2, y 0.1→0.14, w/h 0.4→0.28 — the part that was visible, so it looks as before; 2.1.7 §4.4); missing keys take defaults (opacity 1, rotation 0, upscale off); saved again with `cropFills: true` so the conversion runs once.

### 6.4 Found while watching, fixed in build 121
AI upscaling showed "Loading the model…" for an input that wasn't on air (state stayed `starting`). New state **`waiting`** (Settings shows "Starts when the input is on air or in Preview"; XML `state="waiting"`). Verified: off air → waiting; in Preview → running; on Program → running; as a layer of the on-air input → running. Build 121 re-run 5 min with the same load: 0 drops, 0 errors, memory 1,070–1,149 MB (`stability-5min-build121.log`).

## 7. Known / open
- Rotated layers: align / outline use the unrotated box. Presets are app-wide (not in the project file). Undo per app session.
- **Not verifiable by Claude:** mouse / keyboard (⇧-click, group drag, ⌘A, snapping while dragging, rotated crop drag, arrow keys, ⌘Z, number fields), the preset name dialog, and seeing the menu bar icon itself — the user checks these.
- Working rules: Korean replies; new build number every build; KO + EN UI complete (append to `en.json`, never re-serialize); tests never touch the user's project; never connect to real stream destinations.
