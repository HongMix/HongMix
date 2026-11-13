# HongMix 2.1.5 — handoff (Claude → GPT)

Date: 2026-11-13 · Repo: local `main`, last commit `acaaff6` = v2.1.4 release (build 111, published)

Small bug-fix release on top of 2.1.4. **Uncommitted** in the working tree (3 files).

## 1. State

| What | Value |
|---|---|
| Version | `Resources/Info.plist` **2.1.5**, build **113** (112 was an internal build, never published) |
| Installers (built, tested) | `build/dist/HongMix-2.1.5.dmg` / `.pkg`, ad-hoc signed |
| SHA-256 | DMG `c1b948b68c571ee4c07dce15d5e73b5d82823f3dfcc05aae997048c5ef62591e` · PKG `4a49748999108e67cd417b6a20b30eed9a4c5ddb5d7d12fc8c83174cf15fd8e3` (`build/dist/SHA256.txt`) |
| Copy for the user | `~/Desktop/HongMix/HongMix 2.1.5 배포/`, `~/Desktop/HongMix 2.1.5.app` |

## 2. How to publish
1. Use `build/dist/HongMix-2.1.5.dmg` / `.pkg` as is (rebuild → build 114, `SIGN_ID="-"`). `scripts/test-core.sh` PASS, `check-i18n.py` PASS (no new strings).
2. Commit as `Seunghoon Hong <176268839+HongMix@users.noreply.github.com>` (`Resources/Info.plist`, `Sources/App/Engine/SwitcherEngine.swift`, `Sources/App/Engine/VirtualInput.swift`, this file). Never add `HongMIX-signing/` or `build/`.
3. `docs/RELEASE-NOTES-2.1.5.md` / `.ko.md` / `-GITHUB.md` from §4, `gh release create v2.1.5 --repo HongMix/HongMix --latest`, same asset set as v2.1.4 (screenshots: none new — link to v2.1.4's).

## 3. Fix
**Virtual input on air had no sound when the original's audio was on Auto (follow video).** A virtual input has no audio of its own; the mixer only gave sound to inputs that are themselves on air, so the original stayed silent. Now a virtual input on Program / in a transition / in an overlay brings its original's audio in with the same weight (`SwitcherEngine` audio weights; `VirtualInput.originalID` is fixed at creation so the render thread can read it safely). Originals set to "ON" were not affected.

Verified on the real app: original audio Auto, virtual on Program → original meter and Master carry sound (≈ −38 dBFS peaks as the clip); cut away → original silent.

## 4. Release-note bullet (KO / EN)
- 가상 입력을 송출할 때 원본 오디오가 AUTO(영상 따라가기)면 소리가 안 나던 문제 수정 — 이제 가상 입력이 송출 중이면 원본 소리도 함께 나갑니다 / Fixed: a virtual input on air was silent when its original's audio was on Auto (follow video); the original's sound now goes out with it.
