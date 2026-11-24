# HongMix 2.3.2 — handoff (Claude → GPT)

Date: 2026-11-24 · Repo: local `main`, last commit `b73e4e0` = v2.3.1 (published). Everything below is **uncommitted** on top of it.

**Publish 2.3.2** — answers GitHub issues #7 (Translation EN) and #8 (PDF next slide shortcut).

## 1. State
| What | Value |
|---|---|
| Version | `Resources/Info.plist` **2.3.2**, build **151** (150 = test build) |
| Installers | `build/dist/HongMix-2.3.2.dmg` / `.pkg`, ad-hoc signed |
| SHA-256 | DMG `07344b076d9bd094294f3d30c09b4ef1e7515d8efa10dfd3acfacf6fc3117273` · PKG `c86c6542590165185efc77046b2c068c7c2e26780d0a38a49be660caee660078` |
| Changed | `Resources/Info.plist` (development region + localizations), `scripts/build-cli.sh` (en.lproj / ko.lproj), `Sources/App/Engine/Localization.swift`, `Sources/App/HongMixApp.swift`, `Sources/App/Engine/Shortcuts.swift`, `Sources/App/Engine/APIFunctions.swift`, this file |
| Don't commit | `Blackmagic-settings-backup-2026-11-16/`, `docs/screenshots/2.0.9/*`, `build/`, `HongMIX-signing/` |

## 2. Issue #7 — "Translation EN": menus and the file panel in Korean on an English / Dutch Mac
Reporter (Mac mini M4, macOS 26.5, Dutch system): HongMix menu (About, Settings…, Services, Hide…), Edit and Window menus, and the Finder open panel showed Korean. HongMix's own items (Pre-show Check…, Quit HongMix) were English.

**Cause:** `Info.plist` declared `CFBundleDevelopmentRegion = ko` and the bundle had no `.lproj` folders, so macOS treated HongMix as a Korean-only app and drew all of *its own* UI (standard menus, open / save panels, Services) in Korean on every Mac, whatever the system or HongMix language.

**Fix:**
- `CFBundleDevelopmentRegion = en`, `CFBundleLocalizations = [en, ko]`, and `en.lproj` / `ko.lproj` (with `InfoPlist.strings`) in the bundle (`build-cli.sh`).
- `AppLanguage.syncSystemLanguage()`: the app's `AppleLanguages` follows the HongMix language (Settings › General › Language), written at launch and when the language changes — so system menus / panels match the rest of HongMix from the next launch.
- Verified with the bundle's language resolution: before (2.3.1) `nl`, `de`, `en`, `ko` → **ko** for all; after (2.3.2) `nl` → en, `de` → en, `en` → en, `ko` → ko.

**Reply to post on #7** (after release):
> Thanks! The cause was that HongMix declared Korean as its only language to macOS, so macOS drew its own parts (the Edit / Window / Services menus, Hide/Show, and the open file panel) in Korean on every Mac. 2.3.2 declares English and Korean and makes those parts follow the HongMix language setting (Settings › General › Language) — after updating, they'll be in English (quit and reopen HongMix once if anything still shows Korean). Please let us know if you still see Korean anywhere.

## 3. Issue #8 — "PDF next slide shortcut": NextPicture missing from the keyboard shortcut list
The function list in Settings › Shortcuts had no `NextPicture` / `PreviousPicture` (MIDI had them), although the PDF Slides input help text says "Shortcut: set NextPicture in Settings › Shortcuts".

**Fix:**
- `NextPicture`, `PreviousPicture` added to the shortcut function list (`ShortcutManager.commonFunctions`).
- `NextPicture` / `PreviousPicture` **without an Input** (shortcut left on "none", or an API call without `Input=`) now turn the Photos / PDF Slides input that is on **Program**, else the one in **Preview**. With an Input they work as before (vMix behavior).
- Verified on the real app (dev build 150, a 3-picture Photos input): `NextPicture` with no Input and the slides on Program → 1 → 2; `PreviousPicture` → 1; slides only in Preview → turns them; no slides on Program / Preview → error, nothing happens; with `Input=2` → works as before. The shortcut list now offers both functions.

**Reply to post on #8** (after release):
> Thanks! NextPicture / PreviousPicture were missing from the shortcut list — 2.3.2 adds them. Pick the PDF input in the shortcut's input column, or leave it empty: then the shortcut turns the Photos / PDF input that is on Program (or in Preview).

## 4. How to publish
1. Use the DMG/PKG as is (if you rebuild: build **152**). `check-i18n.py` PASS, `test-core.sh` PASS, `hdiutil verify` VALID.
2. Commit as `Seunghoon Hong <176268839+HongMix@users.noreply.github.com>` (files in §1).
3. Release notes `docs/RELEASE-NOTES-2.3.2.md` / `.ko.md` / `-GITHUB.md` from §5. No new screenshots. US spelling.
4. Manuals: title / installer names → 2.3.2; PDF Slides section: "keyboard shortcut NextPicture / PreviousPicture (leave Input empty = the slides on Program)".
5. `gh release create v2.3.2 --repo HongMix/HongMix --latest`; post the replies in §2 and §3; close #8; close #7 when the reporter confirms.

## 5. Release-note bullets (KO / EN)
- **영어·다른 언어 맥에서 시스템 메뉴와 파일 열기 창이 한국어로 나오던 문제 수정** — 이제 HongMix 언어 설정을 따름 / **Fixed system menus and the open-file panel showing Korean on English and other-language Macs** — they now follow the HongMix language setting.
- **PDF·사진 입력 넘기기 단축키** — 설정 › 단축키에 NextPicture / PreviousPicture 추가, 입력을 비우면 송출 중인 슬라이드를 넘김 / **Keyboard shortcuts for PDF / Photos slides** — NextPicture / PreviousPicture in Settings › Shortcuts; with no input set, they turn the slides on Program.
