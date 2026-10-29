#!/bin/bash
# LGPL FFmpeg (GPL 부품 없음: x264/x265/xvid 등 제외) → build/ffmpeg-lgpl
# HongMix는 인코딩에 맥 하드웨어 인코더(VideoToolbox)를 쓰므로 기능 차이는 없습니다.
#   bash scripts/build-ffmpeg-lgpl.sh     (한 번만, Apple Silicon 기준 5~10분)
set -euo pipefail
cd "$(dirname "$0")/.."
for p in "$HOME/.homebrew/bin/brew" /opt/homebrew/bin/brew /usr/local/bin/brew; do
  [ -x "$p" ] && eval "$("$p" shellenv)" && break
done
BREW="$(brew --prefix)"
PREFIX="$PWD/build/ffmpeg-lgpl"
SRC="$PWD/build/ffmpeg-src"
VER="${FFMPEG_VERSION:-$(brew list --versions ffmpeg-full 2>/dev/null | awk '{print $2}' | cut -d_ -f1)}"
VER="${VER:-8.0}"
for f in pkgconf srt dav1d opus libvpx openssl@3; do brew list "$f" >/dev/null 2>&1 || brew install "$f"; done
mkdir -p "$SRC" build/logs
if [ ! -f "$SRC/ffmpeg-$VER/configure" ]; then
  echo "==> FFmpeg $VER 소스 받기"
  curl -fL --retry 3 -o "$SRC/ffmpeg-$VER.tar.xz" "https://ffmpeg.org/releases/ffmpeg-$VER.tar.xz"
  tar -xJf "$SRC/ffmpeg-$VER.tar.xz" -C "$SRC"
fi
cd "$SRC/ffmpeg-$VER"
export PKG_CONFIG_PATH="$BREW/opt/srt/lib/pkgconfig:$BREW/opt/openssl@3/lib/pkgconfig:$BREW/lib/pkgconfig"
echo "==> configure (LGPL v3, shared)"
./configure --prefix="$PREFIX" --enable-shared --disable-static \
  --disable-programs --disable-doc --disable-debug --disable-avdevice --disable-avfilter \
  --disable-indevs --disable-outdevs --disable-sdl2 --disable-xlib --disable-libxcb \
  --enable-version3 --enable-videotoolbox --enable-audiotoolbox \
  --enable-libsrt --enable-libdav1d --enable-libopus --enable-libvpx --enable-openssl \
  --arch=arm64 --cc=clang --extra-cflags="-mmacosx-version-min=14.0" --extra-ldflags="-mmacosx-version-min=14.0" \
  > "$OLDPWD/build/logs/ffmpeg-configure.log" 2>&1 || { tail -20 "$OLDPWD/build/logs/ffmpeg-configure.log"; exit 1; }
grep -E "^License:" "$OLDPWD/build/logs/ffmpeg-configure.log" || true
echo "==> make"
make -j"$(sysctl -n hw.ncpu)" > "$OLDPWD/build/logs/ffmpeg-make.log" 2>&1 || { tail -30 "$OLDPWD/build/logs/ffmpeg-make.log"; exit 1; }
make install > /dev/null
cp COPYING.LGPLv3 COPYING.GPLv3 "$PREFIX/" 2>/dev/null || true
echo "$VER" > "$PREFIX/VERSION"
echo "완료: $PREFIX (FFmpeg $VER, $(grep -E '^License:' "$OLDPWD/build/logs/ffmpeg-configure.log" | head -1))"
