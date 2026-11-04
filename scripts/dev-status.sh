#!/bin/bash
set -u
cd "$(dirname "$0")/.."

present() {
  if [ -e "$2" ]; then
    printf "%-24s OK  %s\n" "$1" "$2"
  else
    printf "%-24s MISSING  %s\n" "$1" "$2"
  fi
}

echo "HongMix development environment"
echo "Workspace: $PWD"
echo "Git: $(git rev-parse --short HEAD 2>/dev/null || echo unavailable) / $(git branch --show-current 2>/dev/null || echo unavailable)"
echo

printf "%-24s %s\n" "macOS" "$(sw_vers -productVersion 2>/dev/null || echo unavailable)"
printf "%-24s %s\n" "Architecture" "$(uname -m)"
printf "%-24s %s\n" "Swift" "$(swiftc --version 2>/dev/null | head -1 || echo missing)"
printf "%-24s %s\n" "Clang" "$(clang --version 2>/dev/null | head -1 || echo missing)"
printf "%-24s %s\n" "macOS SDK" "$(xcrun --show-sdk-path 2>/dev/null || echo missing)"
printf "%-24s %s\n" "Homebrew" "$(brew --prefix 2>/dev/null || echo missing)"
echo

present "LGPL FFmpeg headers" "build/ffmpeg-lgpl/include/libavformat"
present "LGPL FFmpeg library" "build/ffmpeg-lgpl/lib/libavformat.dylib"
present "FFmpeg source" "build/ffmpeg-src"
present "CEF framework" "ThirdParty/cef/Release/Chromium Embedded Framework.framework"
present "CEF wrapper" "ThirdParty/cef/build/libcef_dll_wrapper/libcef_dll_wrapper.a"
present "NDI SDK" "/Library/NDI SDK for Apple/include/Processing.NDI.Lib.h"
present "DeckLink SDK" "ThirdParty/DeckLinkSDK/include/DeckLinkAPI.h"
present "Built HongMix app" "build/cli/HongMix.app"
present "Release DMG" "installers/HongMix-1.3.39.dmg"
present "Release PKG" "installers/HongMix-1.3.39.pkg"
present "NDI SDK installer" "installers/vendor/Install_NDI_SDK_v6_Apple.pkg"
echo

for package in srt dav1d opus libvpx openssl@3 pkgconf dylibbundler cmake xcodegen; do
  version="$(brew list --versions "$package" 2>/dev/null || true)"
  if [ -n "$version" ]; then
    printf "%-24s OK  %s\n" "Homebrew: $package" "$version"
  else
    printf "%-24s MISSING\n" "Homebrew: $package"
  fi
done

echo
du -sh Sources build/ffmpeg-src build/ffmpeg-lgpl ThirdParty/cef build/cli/HongMix.app installers 2>/dev/null || true
