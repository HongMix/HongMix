#!/bin/bash
# 맥에서 실행: 의존성 확인 → Xcode 프로젝트 생성 → 빌드. 결과는 build/logs/ 에 저장됩니다.
# (Claude가 이 로그를 읽고 오류를 고칩니다)
cd "$(dirname "$0")/.."
mkdir -p build/logs
LOG=build/logs/build.log
SUMMARY=build/logs/summary.txt
: > "$SUMMARY"
say() { echo "$@" | tee -a "$SUMMARY"; }

say "=== 환경 $(date)"
say "macOS: $(sw_vers -productVersion)  arch: $(uname -m)"
if ! command -v brew >/dev/null 2>&1; then
  for p in "$HOME/.homebrew/bin/brew" /opt/homebrew/bin/brew /usr/local/bin/brew; do
    [ -x "$p" ] && eval "$("$p" shellenv)" && break
  done
fi
command -v brew >/dev/null 2>&1 || { say "ERROR: Homebrew 없음 (https://brew.sh)"; exit 1; }
export HOMEBREW_PREFIX="$(brew --prefix)"
say "Homebrew: $HOMEBREW_PREFIX"
XC="$(xcode-select -p 2>/dev/null)"
say "Developer tools: ${XC:-없음}"
USE_XCODE=0
if xcodebuild -version >/dev/null 2>&1; then
  USE_XCODE=1
  say "$(xcodebuild -version | tr '\n' ' ')"
else
  command -v swiftc >/dev/null 2>&1 || { say "ERROR: Command Line Tools 필요: xcode-select --install"; exit 1; }
  say "Xcode 없음 → Command Line Tools로 빌드 ($(swiftc --version 2>&1 | head -1))"
fi

PKGS="ffmpeg-full pkg-config dylibbundler"
[ $USE_XCODE = 1 ] && PKGS="$PKGS xcodegen"
for pkg in $PKGS; do
  brew list "$pkg" >/dev/null 2>&1 || { say "설치: $pkg"; brew install "$pkg" >>"$LOG" 2>&1; }
done
FFB="$HOMEBREW_PREFIX/opt/ffmpeg-full/bin/ffmpeg"
[ -x "$FFB" ] || FFB="$(command -v ffmpeg)"
say "ffmpeg: $FFB — $("$FFB" -hide_banner -version | head -1)"
"$FFB" -hide_banner -protocols 2>/dev/null | grep -qw srt && say "  SRT OK" || say "  SRT 없음"
"$FFB" -hide_banner -encoders 2>/dev/null | grep -q h264_videotoolbox && say "  VideoToolbox OK"
[ -f "/Library/NDI SDK for Apple/include/Processing.NDI.Lib.h" ] && say "NDI SDK: OK" || say "NDI SDK: 없음 (NDI 기능 없이 빌드)"
[ -f ThirdParty/DeckLinkSDK/include/DeckLinkAPI.h ] && say "DeckLink SDK: OK" || say "DeckLink SDK: 없음 (DeckLink 기능 없이 빌드)"

say "=== C 코어 테스트"
if ./scripts/test-core.sh > build/logs/core-test.log 2>&1; then
  say "C 코어 테스트 OK"; grep -E "record:|file input:|srt (in|out):" build/logs/core-test.log | tee -a "$SUMMARY"
else
  say "C 코어 테스트 실패 (build/logs/core-test.log)"
fi

if [ $USE_XCODE = 0 ]; then
  say "=== 빌드 (Command Line Tools)"
  bash scripts/build-cli.sh release 2>&1 | tee -a "$SUMMARY"
else
  say "=== Xcode 빌드"
  xcodegen generate >>"$LOG" 2>&1 || { say "ERROR: xcodegen 실패"; exit 1; }
  xcodebuild -project BraceletMix.xcodeproj -scheme BraceletMix -configuration Debug \
    -derivedDataPath build/DerivedData ARCHS=arm64 ONLY_ACTIVE_ARCH=YES CODE_SIGN_IDENTITY=- \
    HOMEBREW_PREFIX="$HOMEBREW_PREFIX" build >"$LOG" 2>&1
  RC=$?
  grep -E "error:|BUILD (SUCCEEDED|FAILED)" "$LOG" | sort -u > build/logs/errors.txt
  if [ $RC -eq 0 ]; then
    say "BUILD SUCCEEDED → build/DerivedData/Build/Products/Debug/BraceletMix.app"
  else
    say "BUILD FAILED — 오류 $(grep -c 'error:' build/logs/errors.txt)개 (build/logs/errors.txt)"
  fi
fi
echo ""
echo "끝났습니다. Claude에게 '빌드 끝났어'라고 알려주세요."
