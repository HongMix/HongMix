# HongMix 2.3.6 — handoff (Claude → GPT)

Date: 2026-11-25 · Repo: local `main`, last commit `07302e5` = v2.3.5 (published). Everything below is **uncommitted** on top of it.

**Publish 2.3.6** — translated live captions: the original and its translation now appear together, and the line settings work.

## 1. State
| What | Value |
|---|---|
| Version | `Resources/Info.plist` **2.3.6**, build **168** (166–167 = test builds) |
| Installers | `build/dist/HongMix-2.3.6.dmg` / `.pkg`, ad-hoc signed |
| SHA-256 | DMG `dfbc3dc59dbbba08eb6bed98d37ec41d2f38555b675be560f1b154467c9e259b` · PKG `37582a5904c769938906cf1c6a3503cb26d25e1be33eb9ae48086bb2cbbb34f5` |
| Changed | `Sources/App/Engine/Captions.swift`, `Sources/App/Engine/CaptionStyle.swift`, `Sources/App/UI/CaptionsSheet.swift`, `Resources/en.json`, `Resources/Info.plist`, this file, `docs/screenshots/2.3.6/*`, `docs/test-results/2.3.6/*` |
| Don't commit | `Blackmagic-settings-backup-2026-11-16/`, `docs/screenshots/2.0.9/*`, `build/`, `HongMIX-signing/` |

## 2. Operator report (testing 2.3.5)
"English and Korean don't come out together — the Korean comes first. And setting the number of lines does nothing."

**Causes**
1. The English lines were paced (a new line at most every "minimum time per line", 3 s here) while the translation was made right away from the newest recognised text — so the Korean often translated English that was not on screen yet.
2. Rows that did not fit the caption area were silently dropped from the top, so more lines than the area could hold never showed. And while translating, the original only got (caption lines − 1) rows.

**Fix**
- **Paired captions** (`Captions.swift` `pairedRows`): while translating, the English lines on screen and their translation change together. The newest English text is translated first; when its translation is ready, both are shown. The caption changes at most once per "minimum time per line" (at least 1.5 s). If translation is unavailable or takes over 4 s, the English is shown alone. "Translation only" mode is unchanged.
- **Line counts**: "Caption lines" = English lines, "Translation lines" = Korean lines (help text updated).
- **Caption area grows upward** when the lines don't fit, instead of dropping rows (box / band backgrounds grow with it) — `CaptionStyle.swift`.

## 3. Verification (real app, dev builds 166–167, the operator's own caption settings: EN → KO, Custom area 21 %, lines 2, translation lines 2, minimum time 3 s)
- English and Korean appear together 0.9–1.9 s after a sentence (2.9 s for the first one while macOS loads the translator); before, the English could lag the Korean by several seconds.
- Each Korean block matches the English above it (OCR of the program output).
- Caption lines 2 → 2 English lines + translation; Caption lines 3 → 3 English + 2 Korean lines, area grown upward.
- `check-i18n.py` PASS, `test-core.sh` PASS, build 168 ad-hoc, `hdiutil verify` VALID. The operator's project, settings and incidents restored byte-identically.

## 4. Screenshots (`docs/screenshots/2.3.6/`)
`ko-captions.png` / `en-captions.png` — 3 English lines + 2 Korean lines on Program (synthetic test sentences).

## 5. How to publish
1. Use the DMG/PKG as is (if you rebuild: build **169**).
2. Commit as `Seunghoon Hong <176268839+HongMix@users.noreply.github.com>` (files in §1).
3. Release notes `docs/RELEASE-NOTES-2.3.6.md` / `.ko.md` / `-GITHUB.md` from §6 (EN notes `en-*`, KO notes `ko-*`). US spelling.
4. Manuals: version 2.3.6; captions → "Caption lines = original, Translation lines = translation; they change together; the area grows upward".
5. `gh release create v2.3.6 --repo HongMix/HongMix --latest`.

## 6. Release-note bullets (KO / EN)
- **번역 자막이 원문과 함께 나옴** — 한국어가 영어보다 먼저 나오던 문제 수정, 원문과 번역이 같이 바뀜 / **Translated captions now appear together with the original** — the translation no longer shows before its original; both change together.
- **자막 줄 수 설정 수정** — 자막 줄 수 = 원문, 번역 줄 수 = 번역, 자막 영역보다 많으면 위로 늘어남 / **Caption line settings fixed** — Caption lines sets the original, Translation lines the translation; the caption area grows upward when needed.
