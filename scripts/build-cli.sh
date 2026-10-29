#!/bin/bash
# Xcode 없이 Command Line Tools만으로 BraceletMix.app 빌드 (Apple Silicon)
#   bash scripts/build-cli.sh [release|debug]   (default: release)
# 결과: build/cli/BraceletMix.app, 로그: build/logs/cli-build.log, 오류 요약: build/logs/errors.txt
cd "$(dirname "$0")/.."
if ! command -v brew >/dev/null 2>&1; then
  for p in "$HOME/.homebrew/bin/brew" /opt/homebrew/bin/brew /usr/local/bin/brew; do
    [ -x "$p" ] && eval "$("$p" shellenv)" && break
  done
fi
BREW="$(brew --prefix 2>/dev/null || echo /opt/homebrew)"
# FFmpeg with SRT: Homebrew's "ffmpeg-full" (keg-only) if installed, else "ffmpeg"
# Prefer the LGPL build (scripts/build-ffmpeg-lgpl.sh) — no GPL parts, so the app can be distributed with NDI.
FF="$PWD/build/ffmpeg-lgpl"
[ -d "$FF/include/libavformat" ] || FF="$BREW/opt/ffmpeg-full"
[ -d "$FF/include/libavformat" ] || FF="$BREW/opt/ffmpeg"
[ -d "$FF/include/libavformat" ] || FF="$BREW"
# @State is avoided in the sources (see UI/ViewState.swift), so the default SDK works without Xcode.
SDK="$(xcrun --show-sdk-path 2>/dev/null)"
echo "SDK: $SDK"
echo "FFmpeg: $FF"
[ "$FF" = "$PWD/build/ffmpeg-lgpl" ] || echo "  ⚠︎ 개발용 FFmpeg($FF) 사용 중 — 배포용은 scripts/build-ffmpeg-lgpl.sh 로 LGPL 빌드를 쓰세요 (make-dmg.sh는 GPL이면 중단)"
# Swift macro plugins (SwiftUI's @State etc. are macros in recent SDKs)
PLUGIN_ARGS=()
for d in "$SDK/usr/lib/swift/host/plugins" \
         "$(dirname "$(xcrun -f swiftc 2>/dev/null)")/../lib/swift/host/plugins" \
         "$(dirname "$(xcrun -f swiftc 2>/dev/null)")/../local/lib/swift/host/plugins"; do
  [ -d "$d" ] && PLUGIN_ARGS+=(-plugin-path "$d")
done
MODE="${1:-release}"   # optimized by default (debug builds are 3-10x slower in the audio/render loops)
# the auto-build loop passes "debug"; only a real debugging session (BM_DEBUG=1) gets an unoptimized build
[ "$MODE" = "debug" ] && [ "${BM_DEBUG:-0}" != "1" ] && MODE=release
OUT=build/cli
OBJ=$OUT/obj
APP=$OUT/BraceletMix.app
LOG=build/logs/cli-build.log
mkdir -p "$OBJ" build/logs
: > "$LOG"
rm -f build/logs/errors.txt

NDI_INC="/Library/NDI SDK for Apple/include"
DL_INC="ThirdParty/DeckLinkSDK/include"
SRT_DIR="$BREW/opt/srt"
CFLAGS=(-O2 -arch arm64 -isysroot "$SDK" -mmacosx-version-min=14.0 -ISources/Core -I"$FF/include" -I"$DL_INC" -ffile-prefix-map="$PWD"=.)
[ -f "$SRT_DIR/include/srt/srt.h" ] && CFLAGS+=(-I"$SRT_DIR/include")
[ -d "$NDI_INC" ] && CFLAGS+=(-I"$NDI_INC")

fail() { grep -E "^[^ ].*error:" "$LOG" | sort -u > build/logs/errors.txt; echo "BUILD FAILED — $(wc -l < build/logs/errors.txt | tr -d ' ')개 오류 (build/logs/errors.txt)"; exit 1; }

echo "FFmpeg: $FF"
[ "$FF" = "$PWD/build/ffmpeg-lgpl" ] || echo "  ⚠︎ 개발용 FFmpeg($FF) 사용 중 — 배포용은 scripts/build-ffmpeg-lgpl.sh 로 LGPL 빌드를 쓰세요 (make-dmg.sh는 GPL이면 중단)"
echo "Swift plugins: ${PLUGIN_ARGS[*]:-없음}" | tee -a "$LOG"
echo "== C/C++ 코어 컴파일"
OBJS=()
for f in Sources/Core/*.c; do
  o="$OBJ/$(basename "$f" .c).o"
  clang -std=gnu11 "${CFLAGS[@]}" -c "$f" -o "$o" >>"$LOG" 2>&1 || fail
  OBJS+=("$o")
done
clang++ -std=c++17 "${CFLAGS[@]}" -c Sources/Core/mc_decklink.cpp -o "$OBJ/mc_decklink.o" >>"$LOG" 2>&1 || fail
OBJS+=("$OBJ/mc_decklink.o")
if [ -f "$DL_INC/DeckLinkAPIDispatch.cpp" ]; then
  clang++ -std=c++17 "${CFLAGS[@]}" -w -c "$DL_INC/DeckLinkAPIDispatch.cpp" -o "$OBJ/dl_dispatch.o" >>"$LOG" 2>&1 || fail
  OBJS+=("$OBJ/dl_dispatch.o")
fi

# ---- Embedded browser engine (Chromium Embedded Framework), like vMix's Web Browser input
CEF=ThirdParty/cef
CEF_WRAPPER="$CEF/build/libcef_dll_wrapper/libcef_dll_wrapper.a"
CEF_FW="$CEF/Release/Chromium Embedded Framework.framework"
CEFFLAGS=(-std=c++20 -fno-rtti -fno-exceptions -arch arm64 -isysroot "$SDK" -mmacosx-version-min=14.0 -O2 -ISources/Core -ffile-prefix-map="$PWD"=.)
if [ -f "$CEF_WRAPPER" ] && [ -d "$CEF_FW" ]; then
  echo "== 내장 브라우저 엔진 (CEF $(cat $CEF/CEF_DIST.txt 2>/dev/null | sed -E 's/cef_binary_([^+]+).*/\1/'))"
  clang++ "${CEFFLAGS[@]}" -I"$CEF" -DMC_HAVE_CEF=1 -fobjc-arc -c Sources/Core/mc_web.mm -o "$OBJ/mc_web.o" >>"$LOG" 2>&1 || fail
  OBJS+=("$OBJ/mc_web.o" "$CEF_WRAPPER")
  clang++ "${CEFFLAGS[@]}" -I"$CEF" Sources/Core/mc_web_helper.cpp "$CEF_WRAPPER" -o "$OBJ/BraceletMix Helper" >>"$LOG" 2>&1 || fail
  HAVE_CEF=1
else
  echo "== 내장 브라우저 엔진 없음 (scripts/fetch-cef.sh 로 받으면 포함됩니다)"
  clang++ "${CEFFLAGS[@]}" -c Sources/Core/mc_web.mm -o "$OBJ/mc_web.o" >>"$LOG" 2>&1 || fail
  OBJS+=("$OBJ/mc_web.o")
  HAVE_CEF=0
fi

echo "== Swift 컴파일 + 링크"
SWIFT_OPT=-Onone
[ "$MODE" = "release" ] && SWIFT_OPT=-O
echo "빌드 모드: $MODE ($SWIFT_OPT)"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
SWIFT_FILES=()
while IFS= read -r f; do SWIFT_FILES+=("$f"); done < <(find Sources/App -name "*.swift" | sort)
swiftc -parse-as-library -swift-version 5 $SWIFT_OPT -g -file-prefix-map "$PWD"=. -sdk "$SDK" -continue-building-after-errors \
  -target arm64-apple-macos14.0 \
  -module-name BraceletMix \
  -import-objc-header Sources/Core/BraceletMix-Bridging-Header.h \
  "${PLUGIN_ARGS[@]}" \
  -ISources/Core -Xcc -I"$FF/include" \
  "${SWIFT_FILES[@]}" "${OBJS[@]}" \
  -L"$FF/lib" -lavformat -lavcodec -lavutil -lswscale -lswresample -lc++ \
  -L"$SRT_DIR/lib" -lsrt -Xlinker -rpath -Xlinker "$SRT_DIR/lib" \
  -framework VideoToolbox -framework CoreVideo -framework CoreMedia -framework CoreFoundation \
  -framework AppKit -framework IOSurface \
  -Xlinker -rpath -Xlinker "$FF/lib" \
  -o "$APP/Contents/MacOS/BraceletMix" >>"$LOG" 2>&1 || fail

echo "== 앱 번들 구성"
sed -e 's/$(EXECUTABLE_NAME)/BraceletMix/' -e 's/$(PRODUCT_BUNDLE_IDENTIFIER)/com.hongseunghoon.HongMix/' \
    -e 's/$(PRODUCT_NAME)/BraceletMix/' -e 's/$(MACOSX_DEPLOYMENT_TARGET)/14.0/' \
    Resources/Info.plist > "$APP/Contents/Info.plist"
cp Sources/Shaders/Mixer.metal "$APP/Contents/Resources/"
[ -f Resources/en.json ] && cp Resources/en.json "$APP/Contents/Resources/"
[ -f Resources/AppIcon.icns ] && cp Resources/AppIcon.icns "$APP/Contents/Resources/"
if [ "$HAVE_CEF" = 1 ]; then
  mkdir -p "$APP/Contents/Frameworks"
  ditto "$CEF_FW" "$APP/Contents/Frameworks/Chromium Embedded Framework.framework"
  cp "$CEF/CREDITS.html" "$APP/Contents/Resources/CREDITS.html" 2>/dev/null
  cp "$CEF/LICENSE.txt" "$APP/Contents/Resources/CEF-LICENSE.txt" 2>/dev/null
  # Chromium looks for these helper bundles next to the framework (one binary, five roles)
  for SUFFIX in "" " (GPU)" " (Renderer)" " (Plugin)" " (Alerts)"; do
    H="$APP/Contents/Frameworks/BraceletMix Helper$SUFFIX.app"
    mkdir -p "$H/Contents/MacOS"
    cp "$OBJ/BraceletMix Helper" "$H/Contents/MacOS/BraceletMix Helper$SUFFIX"
    ID=$(echo "$SUFFIX" | tr -d ' ()' | tr 'A-Z' 'a-z'); [ -n "$ID" ] && ID=".$ID"
    cat > "$H/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>BraceletMix Helper$SUFFIX</string>
<key>CFBundleIdentifier</key><string>com.hongseunghoon.HongMix.helper$ID</string>
<key>CFBundleName</key><string>BraceletMix Helper$SUFFIX</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>1.0</string>
<key>CFBundleVersion</key><string>1</string>
<key>LSUIElement</key><string>1</string>
<key>LSMinimumSystemVersion</key><string>14.0</string>
<key>NSSupportsAutomaticGraphicsSwitching</key><true/>
</dict></plist>
PLIST
  done
fi
printf 'APPL????' > "$APP/Contents/PkgInfo"
if [ "$HAVE_CEF" = 1 ]; then
  codesign --force --sign - "$APP/Contents/Frameworks/Chromium Embedded Framework.framework" >>"$LOG" 2>&1
  for H in "$APP/Contents/Frameworks/"BraceletMix\ Helper*.app; do codesign --force --sign - "$H" >>"$LOG" 2>&1; done
fi
codesign --force --sign - "$APP" >>"$LOG" 2>&1 || echo "  (codesign 경고 — 로그 참고)"

echo "BUILD SUCCEEDED → $APP"
echo "실행: open $APP"
