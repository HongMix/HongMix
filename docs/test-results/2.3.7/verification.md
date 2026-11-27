# HongMix 2.3.7 — verification

Builds: 169–170 (dev, signed "HongMix Code Signing"), 171 (release, ad-hoc). Apple M1 Max, macOS 27.3.
Base: `3637801` (v2.3.6) + PR #9 (`997243a`, @otiumvisuals) merged + fixes below.

## Automated
| Check | Result |
|---|---|
| `python3 -I scripts/check-i18n.py` | PASS |
| `bash scripts/test-core.sh` | PASS (`core-test.log`) |
| `bash tests/multiview/run.sh` (from PR #9) | all checks passed |
| `bash tests/talentcue/run.sh` (from PR #9) | all checks passed |
| `hdiutil verify HongMix-2.3.7.dmg` | VALID |
| `codesign --verify --deep --strict` | OK (app + Backstage helper) |

## Real app
| Test | Result |
|---|---|
| Operator's own project (5 inputs: colour, 2 × Live Captions, web, video) opens in 2.3.7 | OK, all 5 inputs |
| Backstage off by default | no helper process, port 8089 closed |
| Backstage on, build 169 | **FAILED**: helper exits at launch (`dyld: Library not loaded: @executable_path/../Frameworks/libssl.4.dylib`, referenced from libsrt). Fixed in `make-dmg.sh` (below) |
| Backstage on, build 170 / 171 | helper running, port 8089 listening; `kill -9` HongMix → relaunched after ~1 s with the project restored; normal Quit → HongMix and Backstage both gone, no relaunch |
| Display output regression (2.3.4 fix) | FullscreenOn + 5 × `TestScreensChanged` → still on |
| MultiView over NDI (Output 3 = MultiView, receiver at full bandwidth) | 1920×1080, ~58 fps received, labels + tally borders correct (`docs/screenshots/2.3.7/multiview-output.png`) |
| Talent Cue moderator link | right key 200 · wrong key 403 · no key 403 · cross-site page navigation 200 · cross-site `/talent/cmd` 403 · cross-site `/api` 403 · message text rendered with `textContent` (no HTML) |
| Talent Cue timer + message via the link | shown on the Talent Display (19:5x counting down, red message) |
| Hardware look on / off | both render; center column layout unchanged (same buttons and order) |
| Launch / quit × 6 | 6/6 OK |

## Found and fixed during testing
1. **Backstage helper could not start in the installed app** (PR #9 couldn't run the `make-dmg.sh` step). Bundled libraries referenced each other via `@executable_path/../Frameworks/`, which doesn't exist from the helper (4 folders deeper). `make-dmg.sh` now rewrites library-to-library references to `@loader_path/`.
2. **Backstage helper shipped unstripped** (23.5 MB vs 8.8 MB). `make-dmg.sh` now strips it like the main binary → 8.8 MB.
3. **Backstage default** changed to **off** (opt-in in Settings › General) — it adds a second process, port 8089 and automatic relaunch.
4. Korean UI showed "−1 min / +1 min" in Talent Cue → "−1분 / +1분" (EN unchanged).
5. "Background colour" → "Background color" (US spelling).

## Open / not tested
- One crash at launch (build 170, 1 of 8 launches): AppKit exception during cursor hit-testing (`NSWindow _postWindowNeedsDisplay` while a SwiftUI ScrollView resized). Not reproduced in 6 more launches; no HongMix frames in the stack. Watch for it.
- No second monitor here: MultiView/Talent Display "send to monitor", monitor rows in the new outputs panel and Backstage keeping the Talent window on a monitor were not tested on a real monitor.
- The Display ⚙ panel renders blank in the offscreen snapshot hook (test hook only; the panel itself could not be checked on screen — display asleep).
- Projects saved with the new MultiView / Talent sources don't open in 2.3.6 or older.
