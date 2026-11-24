# HongMix 2.3.1 (build 149)

HongMix 2.3.1 makes input removal safer, fixes a rare crash when adding a web page that starts playing audio immediately, and helps users find a crash report after an unexpected quit.

## Safer input removal

- Closing an input with the tile **×** or the tile menu now asks for confirmation.
- Choose **Don't ask again** to disable the question. Turn it back on in **Settings › General › Safety**.
- **Undo** at the top still restores the last closed input.
- API, Companion and Stream Deck removal commands remain immediate so automation is not blocked.

## Web input stability

- Fixes a rare crash while adding a web page input that starts playing sound immediately, such as a Suno overlay.
- The web input now stays alive until the embedded Chromium browser has fully shut down, preventing late frame, audio or status callbacks from reaching a released input.
- A browser asked to close before creation finishes is now closed as soon as it is created.

## Crash-report guidance

- After HongMix itself crashes, the next launch offers the saved crash report and can reveal it in Finder.
- Attach that file to a GitHub issue to help diagnose any remaining crash.

## Verification

- A local page that played audio immediately was added and removed in 120 test cycles with no crash.
- Translation and core tests passed, the DMG verified as valid, and the build 149 DMG and PKG checksums matched the release files.

## Known limitations

- The public app is ad-hoc signed and is not Apple-notarized yet.
