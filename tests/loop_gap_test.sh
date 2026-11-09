#!/bin/bash
# Looping a media file is gapless: no audio hole and no video stall at the loop point (HongMix 1.4.8).
set -u
cd "$(dirname "$0")/.."
export HOMEBREW_PREFIX="$(brew --prefix 2>/dev/null || echo /opt/homebrew)"
PKG="libavformat libavcodec libavutil libswscale libswresample"
FFP="$HOMEBREW_PREFIX/opt/ffmpeg-full"; [ -d "$FFP/lib/pkgconfig" ] || FFP="$HOMEBREW_PREFIX/opt/ffmpeg"
export PKG_CONFIG_PATH="$FFP/lib/pkgconfig:${PKG_CONFIG_PATH:-}"
FFMPEG="$FFP/bin/ffmpeg"; [ -x "$FFMPEG" ] || FFMPEG=ffmpeg
SRTD="$HOMEBREW_PREFIX/opt/srt"
W="${TMPDIR:-/tmp}/hm-loop-test"; rm -rf "$W"; mkdir -p "$W"
BIN="$W/loop_gap_test"
cc -std=gnu11 -O2 -ISources/Core -I"$SRTD/include" tests/loop_gap_test.c Sources/Core/mc_input.c \
  Sources/Core/mc_pixel.c Sources/Core/mc_srt.c -L"$SRTD/lib" -lsrt -Wl,-rpath,"$SRTD/lib" -o "$BIN" \
  $(pkg-config --cflags --libs $PKG) -Wl,-rpath,$FFP/lib -lpthread -lm \
  -framework VideoToolbox -framework CoreVideo -framework CoreMedia -framework CoreFoundation || exit 1
"$FFMPEG" -hide_banner -loglevel error -y -f lavfi -i testsrc2=size=1280x720:rate=30 \
  -f lavfi -i sine=frequency=440:sample_rate=48000 -t 2 -c:v libx264 -pix_fmt yuv420p -g 30 -c:a aac "$W/src.mp4" || exit 1
"$BIN" "$W/src.mp4" 7
