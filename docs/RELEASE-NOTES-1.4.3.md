# HongMix 1.4.3

## Permissions survive updates
- Problem: Desktop Capture reported "Screen Recording permission needed" even with HongMix switched on in System Settings.
  macOS stores permissions against the app's signature. Earlier releases were ad-hoc signed, which changes every build,
  so each update counted as a new app.
- Change: releases are signed with a fixed "HongMix Code Signing" certificate. The designated requirement is the app identifier
  plus that certificate, not a cdhash. Screen recording, camera and microphone permissions granted once are kept across updates.
- scripts/make-dmg.sh uses that identity automatically when it is in the keychain. Otherwise it falls back to ad-hoc and warns.
- README (EN/KO): new "macOS permissions" section with a per-feature table and the one-time fix when coming from an older version.

## Updating from an older version (once)
1. Quit HongMix. 2. `tccutil reset ScreenCapture com.hongseunghoon.HongMix`
3. Open HongMix, add Desktop Capture, choose Open System Settings, switch HongMix on. 4. Reopen HongMix.

## Notes
- Not notarized yet: right-click → Open once on first launch.
