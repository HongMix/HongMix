#!/bin/bash
# Mac에서 실행: Release 빌드 → FFmpeg 라이브러리 앱 내부 포함 → 서명(ad-hoc) → BraceletMix.dmg 생성
# 사용법: ./scripts/make-dmg.sh
set -euo pipefail
cd "$(dirname "$0")/.."
if ! command -v brew >/dev/null 2>&1; then
  for p in "$HOME/.homebrew/bin/brew" /opt/homebrew/bin/brew /usr/local/bin/brew; do
    [ -x "$p" ] && eval "$("$p" shellenv)" && break
  done
fi
export HOMEBREW_PREFIX="$(brew --prefix 2>/dev/null || echo /opt/homebrew)"

APP_NAME="BraceletMix"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' Resources/Info.plist 2>/dev/null || echo 1.0)"
BUILD_DIR="build"
APP="$BUILD_DIR/Build/Products/Release/$APP_NAME.app"
DMG="$BUILD_DIR/${APP_NAME}-${VERSION}.dmg"
SIGN_ID="${SIGN_ID:--}"   # 기본 ad-hoc. Developer ID가 있으면: SIGN_ID="Developer ID Application: ..." ./scripts/make-dmg.sh

command -v brew >/dev/null || { echo "Homebrew가 필요합니다: https://brew.sh"; exit 1; }
# LGPL FFmpeg (GPL 부품 없음) — 없으면 먼저 빌드
[ -d build/ffmpeg-lgpl/include/libavformat ] || bash scripts/build-ffmpeg-lgpl.sh
command -v dylibbundler >/dev/null || brew install dylibbundler

if [ "${USE_XCODE:-0}" = 1 ] && xcodebuild -version >/dev/null 2>&1; then   # 기본은 CLT 빌드(LGPL FFmpeg 사용)
  command -v xcodegen >/dev/null || brew install xcodegen
  echo "==> Xcode 프로젝트 생성"
  xcodegen generate
  echo "==> Release 빌드 (Xcode)"
  xcodebuild -project "$APP_NAME.xcodeproj" -scheme "$APP_NAME" -configuration Release \
    -derivedDataPath "$BUILD_DIR" HOMEBREW_PREFIX="$HOMEBREW_PREFIX" ARCHS=arm64 ONLY_ACTIVE_ARCH=NO CODE_SIGN_IDENTITY=- build | \
    grep -E "error:|BUILD (SUCCEEDED|FAILED)" || true
else
  echo "==> Release 빌드 (Command Line Tools)"
  bash scripts/build-cli.sh release
  APP="$BUILD_DIR/cli/$APP_NAME.app"
fi
[ -d "$APP" ] || { echo "빌드 실패: $APP 없음"; exit 1; }

echo "==> FFmpeg 등 Homebrew 라이브러리를 앱 안에 포함 (다른 Mac에서도 실행되도록)"
mkdir -p "$APP/Contents/Frameworks"
dylibbundler -of -b -cd \
  -x "$APP/Contents/MacOS/$APP_NAME" \
  -d "$APP/Contents/Frameworks/" \
  -p "@executable_path/../Frameworks/" >/dev/null
# dylibbundler can add the same LC_RPATH more than once → dyld refuses to launch. Keep exactly one.
BIN="$APP/Contents/MacOS/$APP_NAME"
RP="@executable_path/../Frameworks/"
while [ "$(otool -l "$BIN" | grep -c "path $RP ")" -gt 0 ]; do
  install_name_tool -delete_rpath "$RP" "$BIN" 2>/dev/null || break
done
install_name_tool -add_rpath "$RP" "$BIN"
# build-machine paths (e.g. /Users/…/build/ffmpeg-lgpl/lib) must not ship in the binary
for r in $(otool -l "$BIN" | awk '/LC_RPATH/{getline; getline; print $2}' | grep -v '^@'); do
  install_name_tool -delete_rpath "$r" "$BIN" 2>/dev/null || true
done
echo "  rpath: $(otool -l "$BIN" | grep -c "path $RP ")개"
# 라이선스 안전장치: 배포 앱에 GPL/nonfree FFmpeg나 GPL 코덱이 들어가면 중단
if strings "$APP/Contents/Frameworks/"libavcodec*.dylib 2>/dev/null | grep -qE -- "--enable-(gpl|nonfree)"; then
  echo "배포 중단: GPL/nonfree로 빌드된 FFmpeg입니다. scripts/build-ffmpeg-lgpl.sh 로 LGPL FFmpeg를 먼저 빌드하세요."; exit 1
fi
if ls "$APP/Contents/Frameworks/" | grep -qiE "x264|x265|xvid|fdk"; then
  echo "배포 중단: GPL/nonfree 코덱 라이브러리가 포함되어 있습니다."; exit 1
fi
echo "  FFmpeg 라이선스 확인: LGPL (GPL/nonfree 부품 없음)"

NDI_LIB="/Library/NDI SDK for Apple/lib/macOS/libndi.dylib"
if [ -f "$NDI_LIB" ]; then
  echo "==> NDI 런타임 포함 (NDI® is a registered trademark of Vizrt NDI AB)"
  cp "$NDI_LIB" "$APP/Contents/Frameworks/libndi.dylib"
  [ -f "/Library/NDI SDK for Apple/licenses/libndi_licenses.txt" ] && cp "/Library/NDI SDK for Apple/licenses/libndi_licenses.txt" "$APP/Contents/Resources/"
fi

echo "==> 코드 서명 ($SIGN_ID)"
find "$APP/Contents/Frameworks" -name "*.dylib" -exec codesign --force --sign "$SIGN_ID" {} \;
codesign --force --deep --sign "$SIGN_ID" "$APP"
codesign --verify --deep --strict "$APP" && echo "  서명 확인 OK"

PRODUCT="HongMix"
echo "==> 배포용 앱: $PRODUCT.app (실행 파일 이름도 $PRODUCT)"
STAGE="$(mktemp -d)"
DIST="$BUILD_DIR/dist"; rm -rf "$DIST"; mkdir -p "$DIST"
cp -R "$APP" "$STAGE/$PRODUCT.app"
SA="$STAGE/$PRODUCT.app"
mv "$SA/Contents/MacOS/$APP_NAME" "$SA/Contents/MacOS/$PRODUCT"
# 배포본에는 디버그 정보(dSYM, 심볼) 없이 — 개발 경로·소스 파일 이름이 들어가지 않도록
rm -rf "$SA/Contents/MacOS/"*.dSYM
strip -S -x "$SA/Contents/MacOS/$PRODUCT" 2>/dev/null || true
# 오픈소스 고지 (FFmpeg, SRT, NDI, Chromium …)
[ -f docs/THIRD-PARTY-NOTICES.txt ] && cp docs/THIRD-PARTY-NOTICES.txt "$SA/Contents/Resources/"
mkdir -p "$SA/Contents/Resources/licenses"
cp build/ffmpeg-lgpl/COPYING.LGPLv3 build/ffmpeg-lgpl/COPYING.GPLv3 "$SA/Contents/Resources/licenses/" 2>/dev/null || true
[ -f LICENSE ] && cp LICENSE "$SA/Contents/Resources/licenses/HongMix-LICENSE.txt"
/usr/libexec/PlistBuddy -c "Set :CFBundleExecutable $PRODUCT" "$SA/Contents/Info.plist"
codesign --force --deep --sign "$SIGN_ID" "$SA"
codesign --verify --deep --strict "$SA" && echo "  배포 앱 서명 확인 OK"

# 설명서 (한국어 / English)
[ -f docs/HongMix-설명서.txt ] && cp docs/HongMix-설명서.txt "$STAGE/HongMix 설명서 (한국어).txt"
[ -f docs/HongMix-Manual-EN.txt ] && cp docs/HongMix-Manual-EN.txt "$STAGE/HongMix Manual (English).txt"

echo "==> DMG 생성"
DMG="$DIST/${PRODUCT}-${VERSION}.dmg"
ln -s /Applications "$STAGE/Applications"
hdiutil create -volname "$PRODUCT $VERSION" -srcfolder "$STAGE" -ov -format UDZO "$DMG" >/dev/null

echo "==> PKG 설치 파일 생성 (더블클릭 → /Applications 에 설치)"
# macOS 보안(격리 표시)은 건드리지 않습니다. 경고 없이 열리게 하려면 Developer ID 서명 + 공증(notarytool)이 필요:
#   SIGN_ID="Developer ID Application: …" ./scripts/make-dmg.sh  →  xcrun notarytool submit … --wait  →  xcrun stapler staple
ROOT="$(mktemp -d)"; mkdir -p "$ROOT/Applications"
cp -R "$SA" "$ROOT/Applications/"
COMP="$(mktemp -d)/comp.plist"
pkgbuild --analyze --root "$ROOT" "$COMP" >/dev/null
/usr/libexec/PlistBuddy -c "Set :0:BundleIsRelocatable false" "$COMP" 2>/dev/null || true
pkgbuild --root "$ROOT" --component-plist "$COMP" --install-location / \
  --identifier com.hongseunghoon.HongMix.pkg --version "$VERSION" "$DIST/${PRODUCT}-${VERSION}.pkg" >/dev/null
rm -rf "$ROOT"

# 설명서도 dist 폴더에 같이
[ -f docs/HongMix-설명서.txt ] && cp docs/HongMix-설명서.txt "$DIST/"
[ -f docs/HongMix-Manual-EN.txt ] && cp docs/HongMix-Manual-EN.txt "$DIST/"
[ -f docs/THIRD-PARTY-NOTICES.txt ] && cp docs/THIRD-PARTY-NOTICES.txt "$DIST/"
rm -rf "$STAGE"
cp "$DMG" "$BUILD_DIR/${APP_NAME}-${VERSION}.dmg" 2>/dev/null || true   # (기존 경로 호환)
echo ""
echo "완료: $DIST/${PRODUCT}-${VERSION}.dmg / .pkg"
echo "설치: PKG 더블클릭(권장) 또는 DMG를 열고 HongMix를 Applications로 드래그"
