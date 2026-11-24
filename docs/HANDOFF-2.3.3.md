# HongMix 2.3.3 — handoff (Claude → GPT)

Date: 2026-11-24 · Repo: local `main`, last commit `2b83d4c` = v2.3.2 (published). Everything below is **uncommitted** on top of it.

**Publish 2.3.3** — slide controls on screen (not only a shortcut) and PowerPoint / Keynote files in the PDF Slides input. Follow-up to GitHub issue #8.

## 1. State
| What | Value |
|---|---|
| Version | `Resources/Info.plist` **2.3.3**, build **157** (152–156 = test builds) |
| Installers | `build/dist/HongMix-2.3.3.dmg` / `.pkg`, ad-hoc signed |
| SHA-256 | DMG `bdba8050e617ac89ba5ca2cd894373e984e627c5fe61c9971d4e3b7c3ecc5a3b` · PKG `1ab399a0c03340c9f5218937fe4f718cf9e283863555cc6a12d787b0c7634002` |
| New file | `Sources/App/Engine/SlideConverter.swift` |
| Changed | `Sources/App/Engine/SlideInputs.swift`, `Sources/App/UI/PDFThumbStrip.swift`, `Sources/App/UI/InputEditorSheet.swift`, `Sources/App/UI/FileDrop.swift`, `Sources/App/UI/TransportBar.swift`, `Sources/App/UI/SwitcherPanels.swift`, `Sources/App/Engine/WebRemote.swift`, `Sources/App/Engine/WebRemotePage.swift`, `Sources/App/Engine/APIFunctions.swift` (comment), `Sources/App/UI/UISnapshots.swift` (test hook `editorview-<n>`), `Resources/en.json`, `Resources/Info.plist`, this file, `docs/test-results/2.3.3/*`, `docs/screenshots/2.3.3/*` |
| Don't commit | `Blackmagic-settings-backup-2026-11-16/`, `docs/screenshots/2.0.9/*`, `build/`, `HongMIX-signing/` |

## 2. What changed
### 2.1 Slide buttons under Preview / Program (like the video transport)
When the input in Preview or Program is a **PDF Slides** or **Photos** input, the bar under it shows
`⏮ first slide · ‹ Previous · n / N · Next ›` (Photos also gets ▶/❚❚ slideshow and the file name).
The buttons turn the same slide state as the `PreviousPicture` / `NextPicture` functions, so shortcuts, MIDI, API and the buttons stay in sync.
File: `TransportBar.swift` (`SlideControls`).

### 2.2 Slide strip on the input tile
Every PDF / Photos tile in the input list gets a thin strip `‹  n / N  ›` — change slides of an input that is not on air yet (prepare the next deck), without opening anything.
File: `SwitcherPanels.swift` (`TileSlideStrip`).

### 2.3 Web remote (phone / tablet)
- Slide tiles show `‹  n / N  ›` buttons.
- When the Program input is a slide input, the PROGRAM bar shows big `‹ Previous · n / N · Next ›` buttons.
- `/remote.json` state now has `slide` / `slides` for slide inputs.
- The ‹ Previous / Next › labels follow the 한 / EN switch, and when a label doesn't fit (narrow phone, English) both buttons show only the arrows.
Files: `WebRemote.swift`, `WebRemotePage.swift`.

### 2.4 PowerPoint / Keynote files in the PDF Slides input
- The PDF Slides input accepts `.pptx .ppt .ppsx .pps .potx .pot .key .odp` (file picker and drag & drop).
- **No PowerPoint, Keynote or LibreOffice needed**: macOS Quick Look (`qlmanage -p`) lays the deck out as HTML, a hidden WKWebView prints each slide to its own vector PDF page, PDFKit merges them.
- Cached in `~/Library/Application Support/HongMix/SlideCache/<deck>-<mtime+size>.pdf`; saving the deck again converts again (the input reloads automatically, keeps the current slide) and removes the old cache file.
- Hidden slides are skipped (same as PowerPoint slideshow). Animations / transitions are not kept (still pictures, as with PDF).
- If Quick Look can't read a file, the input shows: "This presentation can't be opened with macOS Quick Look. Export it to PDF from PowerPoint or Keynote." Google Slides: download as PDF or PPTX.
Files: `SlideConverter.swift` (new), `SlideInputs.swift`, `PDFThumbStrip.swift`, `InputEditorSheet.swift` (section "PDF and PowerPoint Slides" + help), `FileDrop.swift`.

## 3. Verification (real app, dev builds 152 / 153)
Full table: `docs/test-results/2.3.3/verification.md`. Summary:
- PPTX → PDF: synthetic 5-slide deck converts in ~2 s; hidden slides skipped (8 → 7); re-saving reconverts and keeps the page; corrupt file → clear error, `– / –`, no crash.
- Preview / Program slide bar, tile strip, and the 2.3.2 shortcuts all turn the same deck.
- Web remote on the real app: PROGRAM ‹ › 2→3→2, tile ‹ › 1→2→3. Mock suite: desk 71/71, tablet 71/71, phone 72/72.
- Found and fixed during testing: the count showed twice under Preview for PDFs; the EN phone remote clipped "Previous"; the remote's slide labels didn't follow the 한 / EN switch.
- `check-i18n.py` PASS, `test-core.sh` PASS (`docs/test-results/2.3.3/core-test.log`), `hdiutil verify` VALID, build 157 ad-hoc signed.

## 4. Screenshots (`docs/screenshots/2.3.3/`)
| File | Shows |
|---|---|
| `ko-slides-preview.png` / `en-slides-preview.png` | Main window, PPTX deck in Preview: `⏮ ‹ 이전 2 / 5 다음 ›` bar + tile strip |
| `ko-slides-program.png` / `en-slides-program.png` | Same deck on Program |
| `ko-slides-editor.png` / `en-slides-editor.png` | Input editor "PDF·PowerPoint 슬라이드" / "PDF and PowerPoint Slides" with a `.pptx`, thumbnails, help text |
| `ko-web-phone.png` / `en-web-phone.png` | Web remote on a phone (390 pt) |
| `ko-web-tablet.png` / `en-web-tablet.png` | Web remote on a tablet |

All synthetic: a test deck "Presentation" (colored slides), colour bars input, no people / footage / IP / stream keys.

## 5. How to publish
1. Use the DMG/PKG as is (if you rebuild: build **158**). `check-i18n.py` PASS, `test-core.sh` PASS, `hdiutil verify` VALID.
2. Commit as `Seunghoon Hong <176268839+HongMix@users.noreply.github.com>` (files in §1).
3. Release notes `docs/RELEASE-NOTES-2.3.3.md` / `.ko.md` / `-GITHUB.md` from §6, with the screenshots in §4 (EN notes use `en-*`, KO notes use `ko-*`). US spelling.
4. Manuals (`docs/HongMix-Manual-EN.txt`, `docs/HongMix-설명서.txt`): title / installer names → 2.3.3; PDF Slides section → "PDF and PowerPoint Slides": file types, slide buttons under Preview/Program, tile strip, web remote buttons, shortcut NextPicture / PreviousPicture.
5. `gh release create v2.3.3 --repo HongMix/HongMix --latest`; post the reply in §7 on #8.

## 6. Release-note bullets (KO / EN)
- **슬라이드 넘김 버튼** — PDF·사진 입력이 프리뷰/프로그램에 있으면 화면 아래에 `⏮ ‹ 이전 · n / N · 다음 ›` 버튼 표시 / **Slide buttons** — when a PDF or Photos input is in Preview or Program, the bar under it shows `⏮ ‹ Previous · n / N · Next ›`.
- **입력 타일에서 바로 넘기기** — 슬라이드 입력 타일 아래 `‹ n / N ›`, 송출 전에 다음 자료를 미리 맞춰 둘 수 있음 / **Turn slides from the input tile** — a `‹ n / N ›` strip on each slide input, so you can set up a deck before it goes on air.
- **웹 리모컨 슬라이드 버튼** — 휴대폰·태블릿에서 송출 중인 슬라이드를 큰 버튼으로 넘김 / **Slide buttons in the web remote** — turn the slides on Program from a phone or tablet with big buttons.
- **PowerPoint·Keynote 파일 바로 사용** — PDF 슬라이드 입력에 PPTX·PPT·Keynote 파일을 그대로 넣으면 자동으로 PDF로 변환 (PowerPoint·Keynote 설치 필요 없음, 파일을 저장하면 다시 변환) / **Use PowerPoint and Keynote files directly** — drop a PPTX, PPT or Keynote file into the PDF Slides input and HongMix converts it (no PowerPoint or Keynote needed; saving the file converts it again).

## 7. Reply to post on #8 (after release)
> 2.3.3 adds on-screen slide buttons: when a PDF / Photos input is in Preview or Program you get ‹ Previous · n / N · Next › under it, each slide input tile has a small ‹ › strip, and the web remote has big slide buttons. The PDF Slides input also takes PowerPoint / Keynote files now (converted automatically, no Office needed). The NextPicture / PreviousPicture shortcuts from 2.3.2 still work.
