# HongMix 2.3.2 (build 151)

HongMix 2.3.2 fixes macOS-provided menus and file panels appearing in Korean on English and other-language Macs, and adds keyboard shortcut functions for advancing PDF and Photos slides.

## System menus follow the HongMix language

- The Edit, Window and Services menus, Hide/Show commands, and open-file panels now follow the language selected in **Settings › General › Language**.
- HongMix now declares both English and Korean to macOS, with English as the fallback on other-language systems.
- After changing the HongMix language, quit and reopen the app so every macOS-provided item uses the new language.

## PDF and Photos slide shortcuts

- **NextPicture** and **PreviousPicture** are now available in **Settings › Shortcuts**.
- Select a PDF or Photos input in the shortcut's input column, or leave it empty to control the slide input on Program, falling back to Preview.
- The same no-input behavior is available to API calls. If no slide input is on Program or Preview, the command returns an error without changing another input.

## Verification

- Bundle language resolution was checked for English, Dutch, German and Korean systems: Korean resolves to Korean; the others resolve to English.
- Next/previous behavior was verified in the real app on Program, Preview and a specifically selected input.
- Translation and core tests passed, the DMG verified as valid, and the build 151 DMG and PKG checksums matched the release files.

## Known limitations

- The public app is ad-hoc signed and is not Apple-notarized yet.
