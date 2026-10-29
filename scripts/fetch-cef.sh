#!/bin/bash
# Downloads the Chromium Embedded Framework (CEF) "minimal" binary distribution for Apple Silicon
# and builds libcef_dll_wrapper. Result: ThirdParty/cef/{include,Release/Chromium Embedded Framework.framework,
# build/libcef_dll_wrapper/libcef_dll_wrapper.a}
set -e
cd "$(dirname "$0")/.."
for p in /opt/homebrew/bin/brew /usr/local/bin/brew; do [ -x "$p" ] && eval "$("$p" shellenv)" && break; done
DEST=ThirdParty/cef
if [ -f "$DEST/build/libcef_dll_wrapper/libcef_dll_wrapper.a" ] && [ -d "$DEST/Release/Chromium Embedded Framework.framework" ]; then
  echo "CEF already present: $(cat $DEST/CEF_DIST.txt 2>/dev/null)"; exit 0
fi
if [ -d "$DEST/Release/Chromium Embedded Framework.framework" ]; then
  # downloaded already: only (re)build the wrapper
  [ -f "$DEST/VERSION" ] && mv "$DEST/VERSION" "$DEST/CEF_DIST.txt"   # "VERSION" shadows <version> on case-insensitive disks
  rm -f "$DEST"/*.tar.bz2
  ROOT="$PWD"; cd "$DEST"; LOG="$ROOT/build/logs/cef-build.log"
  rm -rf build
  cmake -S . -B build -DPROJECT_ARCH=arm64 -DCMAKE_BUILD_TYPE=Release -DCMAKE_CXX_FLAGS="-ffile-prefix-map=$PWD=." ${CEF_CMAKE_ARGS:-} >"$LOG" 2>&1
  cmake --build build --target libcef_dll_wrapper -j 8 >>"$LOG" 2>&1 || { grep -m 12 -E "error|Error" "$LOG"; exit 1; }
  ls -la build/libcef_dll_wrapper/libcef_dll_wrapper.a; echo "CEF READY"; exit 0
fi
command -v cmake >/dev/null || brew install cmake
mkdir -p build/cef_dl
cd build/cef_dl
curl -fsSL -o index.json https://cef-builds.spotifycdn.com/index.json
FILE=$(python3 - <<'PY'
import json
d=json.load(open('index.json'))
for v in d['macosarm64']['versions']:
    if v.get('channel')!='stable': continue
    for f in v['files']:
        if f['type']=='minimal':
            print(f['name']); raise SystemExit
PY
)
echo "CEF: $FILE"
[ -f "$FILE" ] || curl -fL -o "$FILE" "https://cef-builds.spotifycdn.com/$FILE"
rm -rf extract && mkdir extract && tar -xjf "$FILE" -C extract
SRC="$(ls -d extract/cef_binary_* | head -1)"
cd ../..
rm -rf "$DEST" && mkdir -p ThirdParty && mv "build/cef_dl/$SRC" "$DEST"
echo "$FILE" > "$DEST/CEF_DIST.txt"
cd "$DEST"
LOG="$OLDPWD/build/logs/cef-build.log"
cmake -S . -B build -DPROJECT_ARCH=arm64 -DCMAKE_BUILD_TYPE=Release -DCMAKE_CXX_FLAGS="-ffile-prefix-map=$PWD=." ${CEF_CMAKE_ARGS:-} >"$LOG" 2>&1
cmake --build build --target libcef_dll_wrapper -j 8 >>"$LOG" 2>&1 || { grep -m 12 -E "error|Error" "$LOG"; exit 1; }
ls -la build/libcef_dll_wrapper/libcef_dll_wrapper.a
echo "CEF READY"
