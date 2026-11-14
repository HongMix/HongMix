# HongMix 2.2.1 — handoff (Claude → GPT)

Date: 2026-11-14 · Mac: Apple M1 Max, macOS 27.3 · Repo: local `main`, last commit `e4c3254` = v2.2.0 (published)

**Publish 2.2.1** — a fix release on top of 2.2.0: SRT receive dropping out, plus quicker SRT settings. Everything below is **uncommitted** on top of `e4c3254`.

## 1. State

| What | Value |
|---|---|
| Version | `Resources/Info.plist` **2.2.1**, build **125** (122–124 were test builds) |
| Installers | `build/dist/HongMix-2.2.1.dmg` / `.pkg`, ad-hoc signed (`SIGN_ID="-"`) |
| SHA-256 | DMG `526fff1253a5972e18ed72c6370b3c9be5cf6d0ae14b8035258c6cfb8ee83d54` · PKG `48f45482461b1a5a34cf3cfa4c4c101c74fe8d06ee9c3dcad0ea05ddc4b2c746` (`build/dist/SHA256.txt`) |
| Copy for the user | `~/Desktop/HongMix/HongMix 2.2.1 배포/` (DMG, PKG, SHA256.txt, `screenshots/`, `test-results/`), `~/Desktop/HongMix 2.2.1.app` |
| Screenshots | `docs/screenshots/2.2.1/` — `ko-04-srt-settings.png`, `en-04-srt-settings.png` (separate KO / EN) |
| Test logs | `docs/test-results/2.2.1/` (no addresses in them) |

Changed files: `Sources/Core/mc_input.c` (the fix), `Sources/App/Engine/SRTPresets.swift` (new), `Sources/App/Engine/Monitoring.swift`, `Sources/App/Engine/APIFunctions.swift`, `Sources/App/UI/InputEditorSheet.swift`, `Sources/App/UI/SwitcherPanels.swift`, `Sources/App/UI/UISnapshots.swift`, `Resources/en.json` (+16), `Resources/Info.plist`.

## 2. How to publish
1. Use the DMG/PKG as is (if you rebuild: build **126**, `SIGN_ID="-" bash scripts/make-dmg.sh`). `scripts/test-core.sh` PASS, `check-i18n.py` PASS, `hdiutil verify` VALID.
2. Commit as `Seunghoon Hong <176268839+HongMix@users.noreply.github.com>`. New files: `Sources/App/Engine/SRTPresets.swift`, `docs/HANDOFF-2.2.1.md`, `docs/screenshots/2.2.1/*`, `docs/test-results/2.2.1/*`. Never add `HongMIX-signing/` or `build/`.
3. `docs/RELEASE-NOTES-2.2.1.md` / `.ko.md` / `-GITHUB.md` from §5. **KO notes use `ko-04-srt-settings.png`, EN notes / GitHub release use `en-04-srt-settings.png`.** US spelling; read the EN notes against the KO once. README "Latest update"; manuals + `docs/FUNCTIONS.md` (XML `<inputSrtStats>`, double-click behavior, SRT list).
4. `gh release create v2.2.1 --repo HongMix/HongMix --latest`, same asset set as v2.2.0. **Recommend the update to SRT users** (the fix is in the receive path of every SRT / RTMP / UDP live input).

## 3. The bug: SRT input drops out every few minutes (all versions with the live jitter buffer, incl. 2.2.0)

User report: the SRT picture they **receive** cuts out now and then. Blackbox log (`~/Movies/HongMix/Incidents/incidents.txt`): "SRT drop N packets" followed 1–2 s later by "signal lost (on air)", repeatedly; later ~420 packets dropped every 10 s, continuously.

Measured on the user's real link (caller, 1080p59.94 H.264, ~9.3 Mbps, RTT 5 ms, 0 % network loss):

| Build | libsrt receive buffer | Frames taken by HongMix | Drops |
|---|---|---|---|
| 123 (= 2.2.0 code) | **1,063 → 5,850 ms in 3 min (+27 ms/s)** | **~58.3 fps** (source 59.94, −2.7 %) | grow until libsrt's buffer is full, then steady drops → broken frames → "signal lost" |
| 124 / 125 (fixed) | 1,072–1,236 ms, flat (latency 1000); 286–437 ms (latency 200) | 59.7–60.4 fps | 0 |

Not the network: macOS "dropped due to full socket buffers" = 0, HongMix CPU 20 %, ping 5 ms / 0 %. Raising the latency only delays the overflow.

**Cause** (`mc_input.c` `pace()`, live branch): every frame that was released even a little late moved the whole playback clock later by that amount (`base_wall_us += now - target`), and every late frame cancelled the catch-up drain. At 60 fps small decode / wake-up lateness happens all the time, so the clock crept ~2.7 % slow and the drain (meant to remove the SRT backlog) never got to run.

**Fix:**
- Lateness up to one frame period: show the frame now, don't move the clock (the 80 ms jitter margin absorbs it). Only lateness > 1 frame (real stall, slower sender clock) moves it.
- A drain started because of the libsrt backlog (`drain_backlog`) runs to the end; a late frame no longer cancels it. Only the slack-based drain stops at a late frame.
- Backlog > 1 s: drain at 12.5 % (was max 8 %); max drain 3 s (was 0.6 s).

## 4. New: SRT settings in two clicks
- **Double-click a stream input's tile** (SRT, RTMP, UDP…) → its connection settings (address, port, mode, latency, passphrase). Other inputs: double-click still opens Input Settings (vMix habit). Single click = Preview, unchanged.
- **Recent and saved SRT** list at the top of the SRT settings (`SRTPresets.swift`, app-wide, UserDefaults `srtPresets`): every SRT input that is added or changed is remembered (last 10); ★ "Save to List…" / right-click "Save with Name…" pins one with a name. Click = fill in the fields, double-click = fill in and reconnect, right-click = rename / remove. Passphrases are stored like the project file already stores them (not the Keychain — HongMix is ad-hoc signed, so every update would trigger a Keychain prompt) and are never shown.
- **Link advice line** in the SRT settings while the input is connected: RTT, loss, packets dropped in the last 30 s, and the recommended latency with a "Use Recommended" button. The recommendation now also reacts to drops (≥ 2× current latency when packets were dropped) — `SRTMonitor.Link.recommendedLatency`, `recentDrops`.
- Input editor sheet height 560 → 640.
- API XML: `<inputSrtStats number connected mode rttMs lossPercent lost retransmitted dropped recentDrops rateMbps bufferMs latencyMs recommendedLatencyMs/>` per SRT input (no peer address).

## 5. Release-note bullets (KO / EN)
- **SRT 수신이 몇 분마다 끊기던 문제 해결** — 60fps 등에서 받는 영상을 실제보다 조금 느리게(약 2.7%) 꺼내 써서 SRT 버퍼가 넘치고 패킷이 버려지던 문제. 이제 버퍼가 Latency 근처에서 일정하게 유지 / **Fixed SRT input dropping out every few minutes** — HongMix consumed live streams about 2.7 % too slowly (most visible at 60 fps), so the SRT buffer overflowed and dropped packets. The buffer now stays at the latency.
- **SRT 입력 더블클릭 = 연결 설정** — 주소·Latency를 바로 수정 / **Double-click an SRT input** to edit its address and latency.
- **최근·저장한 SRT 목록** — 쓰던 주소를 골라 바로 다시 연결, 이름 붙여 저장 / **Recent and saved SRT** — pick a previous connection and reconnect; save favorites by name.
- **연결 상태와 권장 Latency 표시** — RTT·손실·드롭을 보고 권장값을 한 번에 적용 / **Live link advice** — RTT, loss, drops and a one-click recommended latency.

## 6. Verification (user's project + defaults backed up, restored byte-identical; the user's HongMix was quit for the test with their OK and restarted after)
| Test | Result |
|---|---|
| Real link, build 123 (old pacing), latency 1000, 3 min | buffer +27 ms/s, 58.3 fps — reproduces the bug (`srt-link-before-fix-build123-latency1000.log`) |
| Real link, build 124, latency 1000, 6 min | buffer flat 1,088–1,226 ms, 59.7–60.4 fps, 0 drops, 0 signal loss |
| Real link, build 124, latency 200, 4 min | buffer 286–437 ms, 59.2–60.1 fps, 0 / 0 |
| Real link, build 125 (final), latency 1000, 5 min | buffer 1,072–1,236 ms, 58.6–60.1 fps, 0 / 0 |
| Local: ffmpeg 1080p59.94 → HongMix SRT **listener** input, 4 min | buffer 284–327 ms, 59.9–60.0 fps, 0 / 0 |
| Local: HongMix SRT **output** (caller) → ffmpeg listener, 4 min (same run) | 7,192 frames = 29.97 fps (project format), speed 1.0×, no errors |
| Local: HongMix SRT **caller** input → ffmpeg listener, 2.5 min | starts at 510 ms backlog, drained to ~320 ms within 30 s, then flat; 0 / 0 |
| Recent / saved list, link advice | screenshots KO / EN (example addresses from the documentation ranges) |
| Build, `test-core.sh`, `check-i18n.py` (16 new EN strings read one by one), `hdiutil verify` | PASS |
| **Not verifiable by Claude** | mouse double-click on a tile, clicking list rows, the name dialog — the user checks these |

## 7. Known / open
- The user's own saved SRT input is at latency 1000 ms (they raised it while we investigated). With the fix 200 ms works on their link (RTT 5 ms); they can lower it again.
- The release thread still drops a frame that is > 1.5 frame periods behind the clock (by design: current motion over a burst).
