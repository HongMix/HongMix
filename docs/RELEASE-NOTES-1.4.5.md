# HongMix 1.4.5

## Desktop Capture permission
- Problem: Desktop Capture kept saying "Screen Recording permission needed" even with HongMix switched on in System Settings.
  The real cause (old permission recorded for an earlier signature) was hidden behind a fixed message, and the input never retried.
- Shows the real reason macOS gives (e.g. "user declined TCC for application, window, display capture").
- Checks permission silently (`CGPreflightScreenCaptureAccess`) and asks macOS at most once per launch
  (`CGRequestScreenCaptureAccess`). Before this, each retry made macOS show its "would like to record" alert again.
- Retries every 3 s and starts by itself once permission is effective; no need to delete and re-add the input.
- Fixed a race where a fast capture-start failure left the input stuck.

## After updating (once)
If Desktop Capture says permission is needed although HongMix is on:
1. Quit HongMix. 2. `tccutil reset ScreenCapture com.hongseunghoon.HongMix`
3. Open HongMix, add Desktop Capture, Open System Settings, switch HongMix on. 4. Reopen HongMix.

## Signing
- Releases stay ad-hoc signed (not notarised). The fixed self-signed certificate tried in 1.4.3 is only for local builds on a Mac that
  trusts it for code signing; Macs that don't trust it would never apply Screen Recording permission. 1.4.3/1.4.4 were not released.

## Verified (M1 Max)
- Desktop Capture running (Display 1728×1117) and capturing the live screen; display-output regression test 16/16 PASS earlier on this code line.
