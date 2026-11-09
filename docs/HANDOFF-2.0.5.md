# HongMix 2.0.5 — handoff (Claude → GPT)

Date: 2026-11-09 · Mac: Apple M1 Max, macOS 27.3 · Repo: `/Users/deanhong/Documents/ChatGPT/HongMIX` (branch `main`)

**GPT publishes to GitHub.** Nothing from 1.4.6 → 2.0.5 is committed yet. Everything below is in the working tree.

## 1. State in one look

| What | Where / value |
|---|---|
| Last commit (pushed, released) | `fbd8596` — Release 1.4.5 (GitHub Latest = v1.4.5) |
| Working tree | 27 modified + 25 new files, ~+3.8k lines (see §4) |
| Version | `Resources/Info.plist` 2.0.5 (build 80) |
| Local installers (dev-signed, **not for public release**) | `build/dist/HongMix-2.0.5.dmg` / `.pkg` (signed with the local "HongMix Code Signing" cert) |
| App on the user's Desktop | `~/Desktop/HongMix 2.0.5.app` (same build) |
| Release notes drafts | `docs/RELEASE-NOTES-2.0.5.md` / `.ko.md` |
| Signing material (never commit) | `/Users/deanhong/Documents/ChatGPT/HongMIX-signing/` |

## 2. How to publish (checklist)

1. **Public build must be ad-hoc signed** (the self-signed cert only works on this Mac, other Macs would never apply Screen Recording permission):
   ```bash
   SIGN_ID="-" bash scripts/make-dmg.sh
   ```
   Bump `CFBundleVersion` first (user rule: every build gets a new number; version string stays 2.0.5).
2. Check: `hdiutil verify`, `codesign -dvv` shows `Signature=adhoc`, `otool -L` on the app binary shows no external library paths.
3. Run the tests in §5 (at least the unit ones).
4. Commit author **must** be `Seunghoon Hong <176268839+HongMix@users.noreply.github.com>` (never the personal email). Don't add `HongMIX-signing/` or `build/`.
5. README / README.ko: replace "Latest update · 1.4.5" with 2.0.5 highlights (copy from the release notes), Download link text → 2.0.5. Keep the "macOS permissions" reset section (still true for ad-hoc releases).
6. `gh release create v2.0.5 --repo HongMix/HongMix --latest` with assets: dmg, pkg, `HongMix-Manual-EN.txt`, `HongMix-Manual-KO.txt` (= `build/dist/HongMix-설명서.txt`), `SHA256.txt`, `THIRD-PARTY-NOTICES.txt`, notes from `docs/RELEASE-NOTES-2.0.5*.md`. Versions 1.4.6–1.4.9 were never released (internal steps).
7. The user's manuals (`docs/HongMix-Manual-EN.txt`, `docs/HongMix-설명서.txt`) don't describe the 2.0.5 features yet — update them (PTZ window/keys, file drop, MIDI, Photos/PDF/Virtual Set, recording safety).

## 3. What changed (by version step)

- **1.4.6** — Desktop Capture: window list includes windows on other Spaces / full-screen apps (`onScreenWindowsOnly:false`, layer-0 only); still screen no longer counts as signal loss (`linkAlive` while SCStream runs); SCStream stopped by macOS restarts after 2 s.
- **1.4.7** — Recording: crash-safe fragmented mov/mp4 (kill -9 keeps all but <1 s); failed file open stays ERROR (no "stopped" overwrite) and `<recording>` reports False; MultiCorder failures shown (orange button + message). Audio output double free fixed. Cameras/audio devices: no fallback to the built-in device when the chosen one is missing, auto-reopen on plug/unplug/runtime error. Broadcast delay survives network reconnect (held packets air from where they stopped, timeline continues). Audio PTS advances when the FIFO drops samples (no permanent lip-sync slide). 50 untranslated C status strings translated + template matching in `L()`.
- **1.4.8** — Live input clock-drift compensation (PI-controlled resampler ±0.5 %, Catmull-Rom); off-air inputs keep a cushion (click-free cut back). Audio output routes/headphones recover after device change. Replay disk I/O moved to a writer thread. Seamless file split (`mc_output_split`, same encoder, forced keyframe) + generation-safe status callbacks. Gapless file loop. test-core.sh fails properly. DeckLink audio locked to card buffer level (simulated only). New: Desktop Capture audio (SCK, app/whole-Mac, HongMix excluded), "Relaunch Chrome keep-drawing", MIDI (CoreMIDI, learn, templates APC mini mk1/mk2 · nanoKONTROL2 · X-Touch Mini, LED tally), PTZ engine (VISCA IP/TCP/UDP + NDI PTZ, presets, recall on Preview), Photos / PDF Slides / Virtual Set inputs, recording safety (disk-time warning, backup mirror to 2nd disk, spill to another disk), stream monitor history, list/layer API functions, Video Call hidden.
- **1.4.9** — PTZ panel layout fix (one field per row).
- **2.0.5** — **PTZ Control window** (bottom bar › PTZ): live pictures of PTZ inputs numbered 1–9; keys 1–9 camera, WASD pan/tilt (Shift fast), Q/E zoom, Z/X focus, F auto, U I O / J K L / M , . presets 1–9, Tab next; key-up stops, losing focus stops all; keys matched by key code (works with Korean input). PTZ auto-config (NDI → NDI PTZ, SRT/RTSP URL host pre-filled). **Finder file drop**: drop anywhere in the input area → new inputs (after the tile you drop on); ⌥ several videos → one List; ⌘ on a tile → replace that input's file, **always asks** (Cancel is default; Return does nothing).

## 4. Files

Modified: `Resources/{Info.plist,en.json}`, `Sources/App/Engine/{APIFunctions,AudioMixer,CaptureInputs,InputModel,Inputs,Localization,MediaBuffers,Outputs,Replay,SwitcherEngine}.swift`, `Sources/App/{HongMixApp.swift,UI/ContentView,UI/InputEditorSheet,UI/InputPropertiesSheet,UI/OutputsSheet,UI/SwitcherPanels}.swift`, `Sources/Core/{mc_audio_ring.c,mc_core.h,mc_decklink.cpp,mc_input.c,mc_ndi.c,mc_output.c,mc_replay.c}`, `scripts/test-core.sh`, `tests/core_test.c`.

New engine: `ChromeKeepAlive.swift`, `MIDIControl.swift`, `PTZ.swift`, `SlideInputs.swift`. New UI: `FileDrop.swift`, `MIDISettingsView.swift`, `PDFThumbStrip.swift`, `PTZControlWindow.swift`, `PTZPanel.swift`, `SafetyViews.swift`. New tests: see §5.

Where things live:
- Recording safety: `Outputs.swift` (`RecordingSafety`, `OutputChannel.history/backupFile/remainingSeconds`), `mc_output.c` (mirror muxer, spill, checkpoints — movflags now `+frag_custom+empty_moov+default_base_moof` with ~1 s checkpoints).
- PTZ: `PTZ.swift` (`PTZManager.shared`, `PTZController`, VISCA encoder/transport, NDI backend), C wrappers `mc_ndi_recv_ptz` / `mc_ndi_ptz_source` in `mc_ndi.c`.
- Localisation: every user string is `L("한국어")`/`Lf`, English in `Resources/en.json`. **Insert lines, never re-serialize the JSON** (it rewrites thousands of lines). A scan for missing keys returned 0 at handoff.

## 5. Tests (all PASS at handoff)

```bash
bash scripts/test-core.sh                 # C core: file→record, SRT loopback (fails on 0 frames now)
bash tests/delay_reconnect_test.sh        # delay buffer survives a 3 s SRT drop (old code FAILs)
bash tests/split_test.sh                  # seamless split, 6 codec/container cases
bash tests/loop_gap_test.sh               # gapless file loop (old code lost 92 ms)
bash tests/rec_safety_test.sh             # backup mirror, disk-full spill (RAM disks, auto-detached)
bash tests/ptz/run.sh                     # 64 checks, fake VISCA camera, byte-exact
bash tests/midi/run.sh                    # 67 checks incl. CoreMIDI virtual devices
cc -std=gnu11 -O2 -ISources/Core tests/audio_drift_test.c Sources/Core/mc_audio_ring.c -lm -o /tmp/adt && /tmp/adt
# replay store: see header of tests/replay_store_test.c for the cc line
```
App-level (needs the app running, API :8088):
```bash
bash tests/window/test-display-output.sh  # 16/16
bash tests/window/test-multi-display.sh   # 8/8, virtual 2nd monitor (private CGVirtualDisplay, test only)
bash tests/soak/app-soak.sh 60            # 60 min recording: drift −14.8 ms, 0 decode errors, 0 render drops
bash tests/soak/stream-soak.sh 60         # 60 min SRT: 107 989/108 000 frames, drift −5.3 ms
```
Test notes: keep the built-in display awake during the multi-display test (when it sleeps macOS keeps the removed virtual display alive). Never run soak/stream tests against the user's configured stream destinations — the scripts refuse when streaming is on.

## 6. API additions (HTTP 8088 / TCP 8099)

vMix names: NextItem, PreviousItem, SelectIndex, ListAdd/Remove/RemoveAll/Shuffle, LayerOn/Off/OnOff, SetLayer, MoveLayer, MultiViewOverlay*, NextPicture/PreviousPicture, PTZMove*/PTZHome/PTZZoom*/PTZFocus*, PTZMoveToVirtualInputPosition(ByIndex).
HongMix extensions: DesktopCaptureAudio, RelaunchChromeKeepDrawing (Value=confirm), MIDILearn, MIDIEnable, PTZPresetRecall/Store, PTZSetCamera (Value=transport,host[,port[,address]]), VirtualSetPresenter, VirtualSetPreset, RecordDiskWarning, SetRecordBackup, SetRecordSpill, AddInput types Photos|/PDF|/VirtualSet|.
**Test hooks** (keep out of user docs): SetMultiCorder, DisplayOutputDisplay, TestReplaceFile (opens the replace confirmation). XML extras: `<outputStats state= message= backupFile= remaining= kbpsHistory= …>`, `<hmMultiCorderError>`, slide `selectedIndex`/`hmSlideCount`.
`docs/FUNCTIONS.md` is not updated yet.

## 7. Not verified / risks

- **Hardware not available:** real PTZ cameras and NDI PTZ (fake VISCA camera only), DeckLink (simulated card clock), USB audio/capture-card unplug/replug, real MIDI controllers (virtual CoreMIDI only; APC mini mk2 fader CCs and X-Touch LED channel from community sources), Chrome **window** audio capture (Chrome plays audio from a helper process; display capture audio verified).
- **Incident during testing:** with the 2.0.5 pre-release build (no confirmation yet) a test drag ended up replacing the user's input 4 with a test clip. Root cause not pinned down (synthetic ⌘/mouse events). Project restored from backup and verified identical; replace now always asks. Watch for any report of unexpected replaces.
- Projects saved by 2.0.5 with Photos/PDF/Virtual Set inputs can't be opened by older versions.
- Photos/PDF render sRGB; Image/Title inputs use device RGB (slight colour difference possible).
- Fragmenting changed for every mov/mp4 recording (`frag_custom` checkpoints). With a spill folder set, up to ~2 fragments of packets stay in RAM (ProRes HQ: 100–200 MB).
- `SwitcherEngine.recordRemaining` (older estimate) still exists next to `RecordingSafety`; UI uses the new one.
- 3 render drops were seen during the last UI test session (window toggling + modal dialogs); the 60-min soak had 0.
- PTZ keyboard relies on a local NSEvent monitor; text fields keep their keys (Esc/Return leave the field).

## 8. Working rules from the user

- Show a UI mockup and get approval before UI changes.
- New version/build number for every build; put the app on the Desktop as `HongMix <version>.app`; final deliverable = DMG (+PKG).
- Korean and English UI both required.
- The user runs several Apple Silicon Macs — detect capabilities per chip.
- Don't touch the user's project inputs in tests: add test inputs, address them by key (UUID), back up `~/Library/Application Support/HongMix/last-session.bmix` first.
