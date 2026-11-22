# HongMix 2.3.0 (build 143)

HongMix 2.3.0 fixes frame-rate detection for H.264 outputs. The same fix was first built as the unpublished 2.2.9; version 2.2.9 was never released.

## H.264 frame-rate metadata

- H.264 streams, SRT outputs and recordings now carry their frame rate in the stream header.
- This fixes receivers such as AJA BRIDGE LIVE detecting a 59.94 fps HongMix output as 58.94.
- Picture data and timestamps are unchanged. The update adds timing information to the H.264 sequence header for receivers that rely on it.

## Verification

- The user confirmed that an AJA BRIDGE LIVE now detects the same 1080p59.94 output as 59.94.
- The core test exercised the VideoToolbox recording path and confirmed timing information in the H.264 header.
- Translation, checksum, DMG integrity and ad-hoc app-signing checks passed for build 143.

## Known limitations

- This release changes output metadata only; there is no interface change and no new screenshot set.
- The public app is ad-hoc signed and is not Apple-notarized yet.
