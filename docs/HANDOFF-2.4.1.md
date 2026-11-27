# HongMix 2.4.1 — handoff (Claude → GPT)

Date: 2026-11-28 · Repo: local `main`, last commit `c66afff` = v2.4.0 (published). Everything below is **uncommitted** on top of it.

**Publish 2.4.1: smooth transitions on the switcher monitors.**
- In 2.4.0, AUTO transitions made the Program/Preview monitors stutter (25–38 fps), especially at the end of a fade. The Program output itself never dropped a frame.
- The cause was window prewarm, added in 2.4.0, together with a full UI rebuild at every transition start.

## 1. State
| What | Value |
|---|---|
| Version | `Resources/Info.plist` **2.4.1**, build **202** (199–201 = diagnostic/test builds) |
| Installers | `build/dist/HongMix-2.4.1.dmg` / `.pkg`, ad-hoc signed |
| SHA-256 | DMG `843aee0236ca08d2aacbd11eaf27ee17144fcdec9328905d8f1b94ef53be55ec` · PKG `5e4874d08b0f1098c41cd261f2ad6bb00a7d2d87b18dfc3b60862b3f64fb7670` |
| Changed | `Sources/App/Engine/SwitcherEngine.swift`, `Sources/App/UI/ContentView.swift`, `Sources/App/UI/SwitcherPanels.swift`, `Resources/Info.plist`, `README.md`, `README.ko.md`, both manuals, the 2.4.1 release notes, this file, `docs/test-results/2.4.1/*` |
| Don't commit | `Blackmagic-settings-backup-2026-11-16/`, `docs/screenshots/2.0.9/*`, `build/`, `HongMIX-signing/`, `ThirdParty/` |

## 2. What changed
1. **Window prewarm removed** (2.4.0 built the Replay, Talent Cue, MultiView, Scopes and Audio Mixer windows invisibly at launch).
   - Those hidden windows stayed alive and were rebuilt on every engine change, which doubled the UI stall at each transition.
   - The defaults key `disableWindowPrewarm` no longer exists.
2. **AUTO lamp and T-bar** state moved out of the engine's change notifications into `TransitionUI`. A transition start or a T-bar drag no longer rebuilds the whole UI.
3. Results (operator's project, 5 × each AUTO transition):
   - Monitor fps min 25–38 → **53–60**.
   - Program drops 0.
   - Idle GPU 7.9 → 6.5 %.
   - Regression 0 / 0 / 0.
   - First window opens are back to the 2.3.10 level (0.1–0.4 s).

Details: `docs/test-results/2.4.1/verification.md`.

## 3. Screenshots
None new; nothing visible changed.

## 4. How to publish
1. Use the DMG/PKG as is. If you rebuild, use build **203**.
2. Commit the files in §1 as `Seunghoon Hong <176268839+HongMix@users.noreply.github.com>`, e.g. `Release HongMix 2.4.1: smooth transitions on the switcher monitors`.
3. Release notes `docs/RELEASE-NOTES-2.4.1.md` / `.ko.md` / `-GITHUB.md` from §5. US spelling.
4. Manuals (KO + EN): version 2.4.1. If the 2.4.0 manuals mention window prewarm or `disableWindowPrewarm`, remove that.
5. Push `main`, then `gh release create v2.4.1 --repo HongMix/HongMix --latest`.

## 5. Release-note bullets (KO / EN)
- **트랜지션이 다시 부드럽게** — 2.4.0에서 AUTO(페이드·머지 등) 중에 Preview/Program 모니터가 끊기던 문제를 고쳤습니다. 송출 영상은 원래 끊기지 않았습니다. / **Smooth transitions again** — in 2.4.0, the Preview/Program monitors stuttered during AUTO transitions (Fade, Merge, …). Fixed. The program output itself was never affected.
- **T바·AUTO 반응 가볍게** — T바를 움직이거나 트랜지션을 시작할 때 화면 전체를 다시 그리지 않습니다. / **Lighter T-bar and AUTO** — moving the T-bar or starting a transition no longer redraws the whole window.
- 참고 / Note: 2.4.0의 "창 미리 만들기"는 트랜지션을 느리게 해서 뺐습니다. 처음 여는 창은 2.3.10 수준(0.1~0.4초)입니다. / The window prewarm added in 2.4.0 slowed transitions down and was removed; the first open of a window is back to 2.3.10 speed (0.1–0.4 s).
