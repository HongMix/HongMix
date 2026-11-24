# HongMix 2.3.3 — verification (Claude, 2026-11-24)

Real app, dev builds 152–156 (dev-signed copy in a scratch folder, user project backed up and restored byte-identically).

## PowerPoint → PDF (SlideConverter)
| Case | Result |
|---|---|
| Synthetic 5-slide `.pptx` (text + colored backgrounds), API `AddInput Value=PowerPoint|…pptx` | PASS — converted in ~2 s, 5 slides, thumbnails in the editor |
| 8-slide `.pptx` with 1 hidden slide | PASS — 7 slides (hidden slide skipped, like PowerPoint) |
| Re-save the deck while it is loaded (slide 3/7) | PASS — reconverted, stays on 3/7, old cache file removed |
| Unchanged deck opened again | PASS — cache hit, instant |
| Corrupt `.pptx` (random bytes) | PASS — input shows "This presentation can't be opened with macOS Quick Look. Export it to PDF from PowerPoint or Keynote.", tile shows `– / –`, nothing crashes |
| Plain PDF | PASS — unchanged behavior |

## Slide controls
| Case | Result |
|---|---|
| Preview bar `⏮ ‹ Previous n / N Next ›` on a PDF / PPTX input | PASS (count shown once; file name only for Photos) |
| Program bar the same when the deck is on Program | PASS |
| Tile strip `‹ n / N ›` | PASS |
| `NextPicture` / `PreviousPicture` without Input (2.3.2) | PASS — still turns Program, else Preview |
| Web remote PROGRAM `‹ Previous` / `Next ›` (real app, headless Chrome) | PASS — 2→3→2 |
| Web remote tile `‹` / `›` (real app) | PASS — 1→2→3 |
| Web remote suite on the mock server (after the label fixes) | PASS — desk 71/71, tablet 71/71, phone 72/72 |
| Web remote slide bar at 430 / 390 / 320 pt, EN and KO | PASS — labels fit or both buttons go arrow-only; labels follow the 한 / EN switch |

## Build checks
- `check-i18n.py`: PASS
- `test-core.sh`: PASS (`core-test.log`)
- Release build 157: ad-hoc signed, `hdiutil verify` VALID, version 2.3.3 (157)
- DMG `bdba8050e617ac89ba5ca2cd894373e984e627c5fe61c9971d4e3b7c3ecc5a3b`
- PKG `1ab399a0c03340c9f5218937fe4f718cf9e283863555cc6a12d787b0c7634002`
