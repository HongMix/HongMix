# HongMix 2.3.1 — handoff (Claude → GPT)

Date: 2026-11-24 · Repo: local `main`, last commit `2a585d6` = v2.3.0 (published). Everything below is **uncommitted** on top of it.

**Publish 2.3.1** — answers GitHub issues #5 (Remove button) and #6 (Web input crash).

## 1. State
| What | Value |
|---|---|
| Version | `Resources/Info.plist` **2.3.1**, build **149** (144–148 test builds; 147 was an earlier 2.3.1 without the web fix — replaced) |
| Installers | `build/dist/HongMix-2.3.1.dmg` / `.pkg`, ad-hoc signed |
| SHA-256 | DMG `f08ac268fb4a4d0b862829afb9b804df75ee51928a77472889f0c1fd50b4cb05` · PKG `a4aac90578ddd2b33d341ad77fea267ff6a820333d099b5de32345c2476d0544` |
| Changed | `Sources/Core/mc_web.h`, `Sources/Core/mc_web.mm`, `Sources/App/Engine/CaptureInputs.swift` (web input lifetime, #6), `Sources/App/UI/SafetyPrompts.swift` (**new**), `Sources/App/UI/SwitcherPanels.swift` (tile ✕ + tile menu), `Sources/App/HongMixApp.swift` (crash notice at launch), `Sources/App/UI/AboutView.swift` (Settings › General toggle), `Sources/App/UI/UISnapshots.swift` (`closeinput-<n>` test hook), `Sources/App/Engine/APIFunctions.swift` (`DismissSheet` test hook finds a sheet on any window), `Resources/en.json` (+9), `Resources/Info.plist`, this file |
| Don't commit | `Blackmagic-settings-backup-2026-11-16/`, `docs/screenshots/2.0.9/*`, `build/`, `HongMIX-signing/` |

## 2. Issue #5 — "Remove button": ask before closing an input
User report: the tile ✕ closes an input at once; inputs were lost by accident.
- Tile ✕ and the tile menu's **Close Input** now ask: "Close input “Camera 1”? — You can restore it with Undo at the top." [Cancel] [Close] (Close in red), with **Don't ask again**. Shown as a sheet on the front window.
- **Settings › General › Safety › Ask before closing an input** (on by default) turns it back on after "Don't ask again" (UserDefaults `confirmInputClose`).
- API / Companion / Stream Deck `RemoveInput` never asks (automation must not block).
- Undo still restores the last closed input.
- Verified on the real app (build 146): dialog shown; Cancel → input kept; Close → input closed; API `RemoveInput` → closed without a question.

## 3. Issue #6 — "Web input": crash when adding a web page input (Mac mini M4 16 GB, macOS 26.5, 2.3.0)
Reporter's details (issue comment): added a **Suno overlay URL, 50 fps, Chromium**; the app crashed **when pressing OK**; it didn't happen again; no crash report found.

**Likely cause (found in code, matches "once, right at OK, not again"):** the embedded Chromium calls back into the web input from its own threads — audio packets on the audio thread, frames, status. The callbacks carried an **unretained** pointer to the `BrowserInput`, and the only guard was a plain (non-atomic) `closed_` flag. While an input is created / re-created / removed, a packet from a page that plays sound at once (Suno) could arrive just as the old browser was being torn down and reach a freed object → crash. A narrow timing window, so it shows up once and then not again.

**Fix (`mc_web.h`, `mc_web.mm`, `CaptureInputs.swift`):**
- The web input is now **retained by the engine** (`passRetained`) and released only when Chromium destroys its client (`~Client` → new `on_closed` callback, released on the main thread). CEF drops its last reference only after every render / audio / status callback has returned, so no callback can reach a freed input. `on_closed` is called exactly once per `mc_web_open()` (also when opening fails).
- `closed_` is `std::atomic<bool>` (read on the audio thread).
- A browser whose close was requested before it finished creating is closed in `OnAfterCreated` instead of living on unowned.

**Verified** (dev build 148, local page that plays audio as soon as it opens, like Suno): **120 cycles** of adding 1–2 web inputs, waiting 0–2.5 s, sometimes cutting one to Program, then removing them — page audio was flowing in 102 of them; **no crash**, 0 dropped frames, helper processes back to the base count, memory 348 → 376 → 387 MB (no per-input leak — a leaked web input would add tens of MB each).
Earlier (2.3.0, no crash either): fresh web-engine cache, downloaded-file quarantine on the engine, URLs `example.com` / `google.com` / YouTube / Twitch / `about:blank` / `file://`, on Program / Preview / overlay.

**Crash notice (new):** if a crash happens anyway, the next launch says "HongMix quit unexpectedly last time — A crash report was saved. Attaching this file to a GitHub issue helps us find the cause." [Show Report] (reveals the `.ips`) [Close]. Only HongMix's own reports (`~/Library/Logs/DiagnosticReports/HongMix-*.ips`) newer than the previous launch count; shown 8 s after launch. Verified with a test report file (removed afterwards).

**Reply to post on issue #6** (after release):
> Thanks for the details — that helped a lot. A page that starts playing sound right away (like a Suno overlay) could, in a short timing window, crash HongMix while the web input was being created. 2.3.1 fixes this: the web input now stays alive until the embedded browser has fully shut down. We tested it by adding and removing audio pages 120 times without a crash.
> If anything still goes wrong, 2.3.1 also shows the crash report on the next launch — please attach that file here.
> Could you update to 2.3.1 and let us know?

**Reply to post on issue #5** (after release):
> Added in 2.3.1: closing an input with the tile ✕ (or the tile menu) now asks first, with "Don't ask again". You can turn the question back on in Settings › General › Safety. Undo at the top still restores the last closed input.

## 4. How to publish
1. Use the DMG/PKG as is (if you rebuild: build **150**). `check-i18n.py` PASS, `test-core.sh` PASS, `hdiutil verify` VALID.
2. Commit as `Seunghoon Hong <176268839+HongMix@users.noreply.github.com>` (files in §1).
3. Release notes `docs/RELEASE-NOTES-2.3.1.md` / `.ko.md` / `-GITHUB.md` from §5. No new screenshots needed (two system dialogs and one toggle). US spelling.
4. Manuals: title / installer names 2.3.0 → 2.3.1; add to the inputs chapter: "Closing an input asks first (Settings › General › Safety)"; add to Troubleshooting: "After a crash HongMix offers the crash report — attach it to your GitHub issue".
5. `gh release create v2.3.1 --repo HongMix/HongMix --latest`; then post the replies in §3, close #5, and close #6 if the reporter confirms (or after a while without new crashes).

## 5. Release-note bullets (KO / EN)
- **입력을 닫을 때 확인** — 타일의 ✕나 메뉴로 닫을 때 한 번 더 묻고, "다시 묻지 않기" 선택 가능 (설정 › 일반 › 실수 방지에서 다시 켜기) / **Ask before closing an input** — the tile ✕ and menu now ask first, with "Don't ask again" (turn it back on in Settings › General › Safety).
- **웹 페이지 입력 추가 시 드물게 앱이 종료되던 문제 수정** — 바로 소리가 나는 페이지(Suno 등)에서 발생 / **Fixed a rare crash when adding a web page input** — with pages that play sound right away (e.g. Suno).
- **충돌 후 다음 실행 때 충돌 보고서 안내** — GitHub 이슈에 첨부할 파일을 바로 열어 줌 / **Crash report offered after a crash** — the next launch points you to the file to attach to a GitHub issue.
