# HongMix development environment

This workspace is prepared for source analysis, local development, and release builds on Apple Silicon.

## Current baseline

- Source release: HongMix 1.3.39
- Git baseline: `3691de5d7b0c1dea7a3b8373ff867337520f9500`
- Development branch: `codex/development`
- Target: Apple Silicon (`arm64`), macOS 14 or later
- Local toolchain: Apple Command Line Tools, Clang, Swift, Metal, VideoToolbox, CoreAudio

## Stored inside this workspace

| Component | Location | Purpose |
|---|---|---|
| Application source | `Sources/` | Swift UI/engine, C/C++ media core, Metal shader |
| Resources | `Resources/` | Info.plist, icons, English localization |
| Tests | `tests/` | Core, audio-ring, and NDI C tests |
| Build scripts | `scripts/` | Dependency, app, test, and installer builds |
| LGPL FFmpeg source | `build/ffmpeg-src/` | Reproducible FFmpeg source used by HongMix |
| LGPL FFmpeg build | `build/ffmpeg-lgpl/` | Shared FFmpeg libraries and headers |
| Chromium Embedded Framework | `ThirdParty/cef/` | Browser input engine and compiled CEF wrapper |
| Built application | `build/cli/HongMix.app` | Local release build produced from this source |
| Official installers | `installers/` | GitHub release DMG and PKG for version 1.3.39 |
| NDI SDK installer backup | `installers/vendor/Install_NDI_SDK_v6_Apple.pkg` | Official download retained locally; do not install without reviewing and accepting the NDI license |

Generated and third-party binary folders are excluded from Git by `.gitignore`. They remain locally available but are not intended to be committed to the public repository.

## System-provided dependencies

These are not copied into the repository because they are Apple toolchain components or package-manager installations:

- Apple Command Line Tools and macOS SDK
- Swift and Clang
- Apple frameworks: Metal, VideoToolbox, CoreVideo, CoreMedia, CoreAudio, AVFoundation, ScreenCaptureKit, Network, Speech, SwiftUI, WebKit
- Homebrew libraries: SRT, dav1d, Opus, libvpx, OpenSSL, pkgconf, dylibbundler

Run `scripts/dev-status.sh` to inspect the exact state on the current Mac.

## Licensed optional SDKs

### NDI SDK for Apple

NDI is installed system-wide at:

`/Library/NDI SDK for Apple`

HongMix detects the headers while compiling and dynamically loads the NDI runtime. The installed SDK is not copied into this repository because it is governed by Vizrt's NDI SDK license. A new machine must install the official NDI SDK for Apple and accept its license.

The official v6 installer download is retained under `installers/vendor/`. Its local SHA-256 is:

`5aa101a01b00494724c60b7e1e15b5d1743bf9c68b61739c22ac54932dde95fb`

macOS `pkgutil --check-signature` reports `invalid signature` for this downloaded package. It has therefore only been archived and was **not** installed by this preparation process. Re-download from the official NDI site and verify current vendor guidance before installing it on another Mac.

### Blackmagic DeckLink SDK

The Blackmagic DeckLink SDK 16.0 is present locally. The original archive is stored at `installers/vendor/Blackmagic_DeckLink_SDK_16.0.zip`, and its Mac headers are extracted to `ThirdParty/DeckLinkSDK/include/`. Both locations are excluded from Git because Blackmagic does not allow the SDK to be redistributed in this repository.

Local archive SHA-256:

`8ca1a5f4ed56a59f1a9731860c901690488705879a3d865204fb7f132bf00cf9`

1. Download the Desktop Video SDK from Blackmagic Design.
2. Copy every file from its `Mac/include/` directory into `ThirdParty/DeckLinkSDK/include/`.
3. Confirm that `DeckLinkAPI.h` and `DeckLinkAPIDispatch.cpp` exist.
4. Install Blackmagic Desktop Video drivers on the Mac used with the hardware.

The DeckLink-enabled HongMix release build now succeeds. Binary inspection confirms that `mc_decklink_available()` calls `CreateDeckLinkIteratorInstance()` rather than returning the no-SDK stub value. A standalone runtime probe also succeeded and reported `devices=0`, which is expected while no DeckLink or UltraStudio hardware is connected.

## How HongMix runs

1. SwiftUI provides the operator UI and coordinates switching, inputs, audio, replay, automation, and output state.
2. The C/C++ core opens and decodes media/network sources through FFmpeg and SRT.
3. NDI and DeckLink adapters connect broadcast I/O when their SDK/runtime is available.
4. CEF renders browser inputs in a separate Chromium helper process.
5. Metal composites program and preview frames on the GPU.
6. VideoToolbox performs hardware video encode/decode; CoreAudio handles monitoring and mixing output.
7. Output modules record or transmit RTMP/SRT/NDI/DeckLink feeds.
8. The HTTP/TCP control layer exposes vMix-compatible control for Companion and Stream Deck.

## Rebuild commands

```bash
# Inspect the development environment
bash scripts/dev-status.sh

# Rebuild LGPL FFmpeg if needed
bash scripts/build-ffmpeg-lgpl.sh

# Download/build CEF if needed
bash scripts/fetch-cef.sh

# Build HongMix.app without requiring full Xcode
bash scripts/build-cli.sh release

# Run core tests
bash scripts/test-core.sh

# Build distributable DMG/PKG
bash scripts/make-dmg.sh
```

The local build is ad-hoc signed. Public distribution still requires an Apple Developer ID, hardened runtime, notarization, and release validation.

## Verification performed during setup

- `bash scripts/build-cli.sh release`: passed; produced `build/cli/HongMix.app` with LGPL FFmpeg and CEF.
- XcodeGen project generation: passed; produced `HongMix.xcodeproj` (generated/ignored).
- Core file recording/playback path: passed with software H.264 fallback, 89 recorded frames, 0 reported drops, H.264/AAC output detected.
- VideoToolbox test session: unavailable in the command test environment (`-12903`), so hardware encoding still requires an interactive app test.
- SRT loopback initially failed in the restricted command sandbox because the listener socket could not open. The same HongMix core test passed with normal local-network permissions: VideoToolbox H.264 output, 149 transmitted frames, 133 received video frames at 640×360, 231,424 received audio frames, and H.264/AAC stream detection.
- DeckLink SDK 16.0 compile and runtime loading: passed. Device enumeration currently reports zero connected devices; physical capture/output remains untested until DeckLink or UltraStudio hardware is connected.

