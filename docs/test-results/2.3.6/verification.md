## 3. Verification (real app, dev builds 166–167, the operator's own caption settings: EN → KO, Custom area 21 %, lines 2, translation lines 2, minimum time 3 s)
- English and Korean appear together 0.9–1.9 s after a sentence (2.9 s for the first one while macOS loads the translator); before, the English could lag the Korean by several seconds.
- Each Korean block matches the English above it (OCR of the program output).
- Caption lines 2 → 2 English lines + translation; Caption lines 3 → 3 English + 2 Korean lines, area grown upward.
- `check-i18n.py` PASS, `test-core.sh` PASS, build 168 ad-hoc, `hdiutil verify` VALID. The operator's project, settings and incidents restored byte-identically.

## 4. Screenshots (`docs/screenshots/2.3.6/`)
