# HongMix 2.2.8 (build 141)

HongMix 2.2.8 makes the browser switcher smoother and more resilient on real Wi-Fi networks. It includes the unpublished 2.2.6 and 2.2.7 work; v2.2.5 remains the previous public release.

## Live browser monitoring

- Preview and Program now use live MJPEG pictures instead of occasional still-image refreshes.
- Choose **Smooth (15 fps)**, **Medium (8 fps)** or **Data saver (2 fps)** from the web remote.
- A maximum of 16 live pictures limits load on the Mac. Frame rate and width are normalized to supported values.
- Thumbnail encoding runs separately from command handling so CUT, overlays and transport commands do not wait behind image work.

## Wi-Fi reliability and tally

- Web requests time out quickly after a Wi-Fi loss, show **Connection lost — reconnecting…**, and keep retrying.
- A phone that disappears without closing its page is released within about eight seconds instead of remaining attached for minutes.
- Tally requests no longer overlap, preventing an older response from briefly restoring the wrong light on a slow link.
- Silent or incomplete HTTP connections are bounded and closed cleanly.

## Clearer access mode and stronger request checks

- **This Mac only** now reports `localhost` and displays a clear warning that phones cannot connect in that mode.
- Same-network access continues to show the LAN address for phones and tablets.
- Browser command requests accept the HongMix page itself and directly entered/API requests, while rejecting commands from unrelated same-site web pages.

## Manual

- The [English manual](manual/HongMix-Manual.en.md) and [한국어 설명서](manual/HongMix-Manual.ko.md) now include a step-by-step checklist for a phone that cannot open the remote: same Wi-Fi, access mode, `http` rather than `https`, guest-network isolation and VPN checks.
- The existing manual screenshots show the 2.2.5 browser layout. They remain representative, but do not show the new 2.2.8 quality selector.

## Verification

- Virtual switcher UI suite: desktop 65/65, iPad 65/65, phone 66/66.
- Real-app integration suite: 47/47 with 0 dropped frames.
- Web hardening suite: 10/10.
- Ten-minute load run: 10,495 requests, 797 commands with 0 failures, 0 dropped frames, 522–558 MB memory and no live connections left after the test.
- Core, translation, checksum, DMG and ad-hoc app-signing checks passed for the release candidate.

## Known limitations

- Physical iPhone and iPad testing is still pending. The LAN address, phone-sized browser layout and CUT action were verified from a browser on the Mac.
- The public app is ad-hoc signed and is not Apple-notarized yet.
