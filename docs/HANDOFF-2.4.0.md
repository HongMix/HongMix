# HongMix 2.4.0 — handoff (Claude → GPT)

Date: 2026-11-28 · Repo: local `main`, last commit `bda1673` = v2.3.10 (published). Everything below is **uncommitted** on top of it.

**Publish 2.4.0: smooth instant replay and faster windows.**
- With AI slow motion on, the Program output dropped hundreds of frames while the Replay window was open and during slow motion.
- Secondary windows froze the UI for up to 0.3 s when they opened.
- 2.4.0 fixes both and turns AI slow motion off by default.

## 1. State
| What | Value |
|---|---|
| Version | `Resources/Info.plist` **2.4.0**, build **198** (188–197 = diagnostic/test builds) |
| Installers | `build/dist/HongMix-2.4.0.dmg` / `.pkg`, ad-hoc signed |
| SHA-256 | DMG `366be5210b2340ab1982265f7e84917c0cd9c6acde001c04897175fdaa84e8e5` · PKG `4f572dda4ade07cf11cf382e903cc10f6106e1ab72873550b9232c5272411d8c` |
| Changed | `Sources/App/Engine/Replay.swift`, `Sources/App/Engine/SwitcherEngine.swift`, `Sources/App/Engine/APIFunctions.swift`, `Sources/App/UI/ReplayView.swift`, `Sources/App/UI/ContentView.swift`, `Sources/App/UI/UISnapshots.swift`, `Sources/App/UI/FullscreenOutput.swift`, `Sources/App/UI/MultiViewEditor.swift`, `Sources/App/UI/OutputWindows.swift`, `Sources/App/UI/SafetyChips.swift`, `Resources/en.json`, `Resources/Info.plist`, `README.md`, `README.ko.md`, both manuals, `docs/FUNCTIONS.md`, the 2.4.0 release notes, this file, `docs/test-results/2.4.0/*`, `docs/screenshots/2.4.0/*` |
| Don't commit | `Blackmagic-settings-backup-2026-11-16/`, `docs/screenshots/2.0.9/*`, `build/`, `HongMIX-signing/`, `ThirdParty/` |

## 2. What changed
Details and measurements: `docs/test-results/2.4.0/verification.md`.
1. **AI slow motion no longer slows the program.**
   - Real-time AI interpolation runs only while the program has room. After a dropped or tight program frame, GPU blending is used for 30 s.
   - Background AI clip rendering pauses while the program is busy.
   - The model loads with the project (at launch) instead of when recording starts.
2. **AI slow motion is off by default for new projects**, with a note under the toggle (KO/EN). Projects that have it on keep it on.
3. **Replay window:**
   - Free disk space is measured in the background every 3 s; before, it was queried on every redraw on the main thread and froze it for up to 1–2 s.
   - Deck positions and status redraw only the parts that show them, not the whole window.
4. **Replay cameras** are rendered in one GPU pass per frame (shared with MultiCorder ISO).
5. **Windows open instantly.**
   - The Replay, Talent Cue, MultiView and Scopes windows are built once, invisibly, right after launch.
   - First open: 150–320 ms → 10–60 ms.
   - Audio Mixer: about 0.1 s (it re-lays out the main window when it pops out).
6. **Pop-out mixer and display output no longer refresh the whole UI.**
   - The mixer's docked state moved to `MixerDock`, and the display output publishes to its own observers. Before, they went through `engine.objectWillChange`, which rebuilt every view that observes the engine.
   - The Audio Mixer is prewarmed too.
   - Results: Audio Mixer open 394 → 120 ms, Display output 149 → 82 ms, mixer dock toggle 247 → 134 ms.
7. **Crash fix (found during 2.4.0 testing):**
   - Loading the AI slow-motion model at launch, while window prewarm, the browser engine and the monitors were also creating Metal state, crashed inside Metal once (test build 191).
   - Model loading now waits until HongMix has been up for 20 s.
   - Check: 10 launches with recording and window opening during the load, 0 crashes.
8. **API:**
   - `OpenWindow` (Value = `replay|scopes|audiomixer|talentcue|multiview|rundown|ptz`)
   - `CloseWindow` (Value = window title)
9. EN text: "Cameras: 1 · … per hour" (was "1 cameras").

**Result** (operator's project, AI on):
- Replay window open: 280–558 → **0** drops.
- Slow motion to Program: 538 → **0** drops, 60 fps.
- All windows open: up to 99 → **0** drops.
- Regression 0 / 0 / 0; no launch click.

## 3. Screenshots
`docs/screenshots/2.4.0/ko-replay-settings.png` and `en-replay-settings.png`:
- Replay settings in a new project, so AI frame interpolation is off.
- The new note sits under the toggle.
- Captured separately with the app in each language.
- No paths or IPs are visible.

## 4. How to publish
1. Use the DMG/PKG as is. If you rebuild, use build **199**.
2. Commit everything in §1 "Changed" as `Seunghoon Hong <176268839+HongMix@users.noreply.github.com>`, e.g. `Release HongMix 2.4.0: smooth instant replay with AI slow motion, faster windows`.
3. Release notes `docs/RELEASE-NOTES-2.4.0.md` / `.ko.md` / `-GITHUB.md` from §5. US spelling. EN notes use `en-*`, KO notes use `ko-*`.
4. Manuals (KO + EN), version 2.4.0:
   - Replay › Slow motion: AI is off by default, plus the GPU note and the automatic fallback.
   - API: `OpenWindow`, `CloseWindow`.
5. Push `main`, then `gh release create v2.4.0 --repo HongMix/HongMix --latest`.
6. No GitHub comments or Reddit posts unless the operator asks.

## 5. Release-note bullets (KO / EN)
- **리플레이가 송출을 끊지 않음** — AI 슬로모션이 켜져 있어도 리플레이 창·슬로 재생 중 Program 프레임이 끊기지 않습니다. 송출이 바빠지면 자동으로 GPU 블렌딩으로 바꾸고, 백그라운드 AI 작업은 잠시 멈춥니다. / **Instant replay no longer disturbs Program** — with AI slow motion on, Program keeps every frame while the Replay window is open and during slow motion. When Program gets busy, HongMix switches to GPU blending and pauses background AI work.
- **AI 슬로모션 기본 꺼짐** — GPU 부담이 커서 새 프로젝트는 꺼진 상태로 시작합니다. 설정에 안내를 달았습니다. / **AI slow motion off by default** — it is heavy on the GPU, so new projects start with it off. The setting now explains the trade-off.
- **창이 바로 열림** — 리플레이·Talent Cue·MultiView·스코프·오디오 믹서·디스플레이 출력 창이 처음 열 때도 멈칫하지 않습니다. / **Windows open instantly** — the Replay, Talent Cue, MultiView, Scopes, Audio Mixer and Display output windows open without a hitch, even the first time.
- **리플레이 창 가볍게** — 디스크 확인과 화면 갱신을 줄여 리플레이 창이 부드러워졌습니다. / **Lighter Replay window** — fewer disk checks and redraws keep it smooth.
- API: `OpenWindow`, `CloseWindow` 추가 / added.
