# HongMix 2.3.8 — handoff (Claude → GPT)

Date: 2026-11-27 · Repo: local `main`, last commit `42aabd0` = v2.3.7 (published). Everything below is **uncommitted** on top of it.

**Publish 2.3.8 as a hotfix for 2.3.7.** In 2.3.7, the new hardware look made Program drop frames on every cut, fade and at launch. 2.3.6 did not have this problem.

## 1. State
| What | Value |
|---|---|
| Version | `Resources/Info.plist` **2.3.8**, build **173** (172 = test build) |
| Installers | `build/dist/HongMix-2.3.8.dmg` / `.pkg`, ad-hoc signed |
| SHA-256 | DMG `acfca0851c7b864cec70162ced3aa5a0c2ce1f1004ee85a58b746f6dd91bf284` · PKG `75c19597b391a3a1be76f9cec8a5e8eced3932b38354c5f551823b0105d2ef91` |
| Changed | `Sources/App/UI/ContentView.swift`, `Sources/App/UI/SwitcherPanels.swift`, `Resources/Info.plist`, this file, `docs/test-results/2.3.8/*` |
| Don't commit | `Blackmagic-settings-backup-2026-11-16/`, `docs/screenshots/2.0.9/*`, `build/`, `HongMIX-signing/` |

## 2. What changed
- The hardware look used SwiftUI `.shadow` on about 100 controls. SwiftUI draws each shadow in a separate GPU pass on every redraw, and that work delayed the Program mix.
- These shadows are now two plain offset fills of the same shape (`HWDrop`). The look is the same and there is no extra GPU pass.
- Measured on the operator's own project (4K 59.94 file on Program, YouTube input, a Chrome dashboard running):

| | 2.3.7 | 2.3.8 |
|---|---|---|
| First 30 s after launch | 63 drops | 0 |
| 20 fades | 34 drops | 0 |
| 10 cuts | 8 drops | 0 |
| Slowest frame | 18 ms | 3.6 ms |

- Details: `docs/test-results/2.3.8/verification.md`.

## 3. Screenshots
None new; the look is unchanged. The 2.3.7 screenshots (`docs/screenshots/2.3.7/`) still apply. The before/after comparison uses the operator's real footage, so it is not for publishing.

## 4. How to publish
1. Use the DMG/PKG as is. If you rebuild, use build **174**.
2. Commit as `Seunghoon Hong <176268839+HongMix@users.noreply.github.com>` (files in §1).
3. Release notes `docs/RELEASE-NOTES-2.3.8.md` / `.ko.md` / `-GITHUB.md` from §5. US spelling.
4. Manuals: version 2.3.8 (no other changes).
5. `gh release create v2.3.8 --repo HongMix/HongMix --latest`.
6. Mark the 2.3.7 release notes on GitHub with one line at the top: "Please update to 2.3.8 — 2.3.7 can drop Program frames with the hardware look on." KO: "2.3.8로 업데이트해 주세요 — 2.3.7은 하드웨어 룩이 켜져 있으면 Program 프레임이 끊길 수 있습니다."

## 5. Release-note bullets (KO / EN)
- **2.3.7 프레임 드랍 수정** — 하드웨어 룩이 켜져 있으면 컷·트랜지션·시작할 때 Program 프레임이 끊기던 문제를 고쳤습니다. 입체 버튼 그림자를 GPU 부담이 없는 방식으로 바꿨고 모양은 같습니다. / **Fixed dropped frames in 2.3.7** — with the hardware look on, Program dropped frames on cuts, transitions and at launch. The raised-key shadows are now drawn without extra GPU work and look the same.
- 2.3.7을 쓰고 있다면 업데이트를 권장합니다 / Recommended for everyone on 2.3.7.
