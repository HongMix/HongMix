# HongMix 2.3.4 — verification (Claude, 2026-11-25)

Real app, dev builds 158–160; the user's project, settings and incidents backed up and restored byte-identically.

| Area | Case | Result |
|---|---|---|
| Display output | Saved monitor unplugged (ID 15), output on the built-in screen, 5 × screen-change events — window mode | PASS — stays open |
| Display output | Same — fullscreen mode | PASS — stays open |
| Center column | KO and EN screenshots: tabs, length, CUT / AUTO / Quick Play, T-bar, Overlay 1–8, Stinger row, FTB | PASS |
| Captions | EN → KO, test sentence every 0.5 s: translation changes at 1.0 s and 6.5 s (held ≥ 3 s), 2 Korean lines under the English | PASS |
| English UI | Core status "재생 완료" → "Playback finished"; new titles created in English | PASS |
| English UI | OCR of main window, General, Display, Remote, Startup, Cleanup, Encoding, top bar, 5 input editors | PASS — only the language picker and user-made input names contain Korean |
| Build | check-i18n PASS · test-core PASS · build 161 ad-hoc · hdiutil VALID | PASS |

DMG `f836887e1706646dd1b9a35a360146cd29820121f4c9b8186491f41f487d6ef8`
PKG `b225b11be803db457b24e2dcb9436eb1a3e5dc5de4f3c547bc3576f8f5bdf790`
