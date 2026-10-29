#!/bin/bash
# BraceletMix 개발 환경 준비 + Xcode 프로젝트 생성 (Apple Silicon macOS 14+)
set -e
cd "$(dirname "$0")/.."
if ! command -v brew >/dev/null 2>&1; then
  for p in "$HOME/.homebrew/bin/brew" /opt/homebrew/bin/brew /usr/local/bin/brew; do
    [ -x "$p" ] && eval "$("$p" shellenv)" && break
  done
fi
export HOMEBREW_PREFIX="$(brew --prefix 2>/dev/null || echo /opt/homebrew)"

if ! command -v brew >/dev/null 2>&1; then
  echo "Homebrew가 필요합니다: https://brew.sh"; exit 1
fi
if ! xcode-select -p >/dev/null 2>&1; then
  echo "Xcode(또는 Command Line Tools)가 필요합니다. App Store에서 Xcode를 설치하세요."; exit 1
fi

echo "==> Homebrew 패키지 설치 (ffmpeg, xcodegen)"
brew install ffmpeg xcodegen pkg-config

echo "==> FFmpeg 기능 확인"
ffmpeg -hide_banner -protocols 2>/dev/null | grep -qw srt  && echo "  SRT          OK" || echo "  SRT          없음 (brew reinstall ffmpeg)"
ffmpeg -hide_banner -protocols 2>/dev/null | grep -qw rtmp && echo "  RTMP         OK" || echo "  RTMP         없음"
ffmpeg -hide_banner -encoders 2>/dev/null | grep -q h264_videotoolbox && echo "  VideoToolbox OK" || echo "  VideoToolbox 없음"

echo "==> 선택 SDK 확인"
if [ -f "/Library/NDI SDK for Apple/include/Processing.NDI.Lib.h" ]; then
  echo "  NDI SDK      OK"
else
  echo "  NDI SDK      없음 — https://ndi.video/for-developers/ndi-sdk/ 에서 'NDI SDK for Apple' 설치 (NDI 기능에 필요)"
fi
if [ -f "ThirdParty/DeckLinkSDK/include/DeckLinkAPI.h" ]; then
  echo "  DeckLink SDK OK"
else
  echo "  DeckLink SDK 없음 — ThirdParty/DeckLinkSDK/README.md 참고 (DeckLink 기능에 필요)"
fi

echo "==> Xcode 프로젝트 생성"
xcodegen generate

if [ "$1" == "--build" ]; then
  echo "==> 빌드 (Release)"
  xcodebuild -project BraceletMix.xcodeproj -scheme BraceletMix -configuration Release \
    -derivedDataPath build HOMEBREW_PREFIX="$HOMEBREW_PREFIX" CODE_SIGN_IDENTITY=- build | tail -20
  echo "앱: build/Build/Products/Release/BraceletMix.app"
else
  open BraceletMix.xcodeproj
  echo "Xcode에서 ⌘R 로 실행하세요. (명령줄 빌드: scripts/bootstrap.sh --build)"
fi
