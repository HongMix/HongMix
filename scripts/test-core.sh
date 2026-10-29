#!/bin/bash
# C 미디어 코어 단독 테스트 (GUI 없이): 파일 디코드→녹화, SRT 루프백
set -e
cd "$(dirname "$0")/.."
if ! command -v brew >/dev/null 2>&1; then
  for p in "$HOME/.homebrew/bin/brew" /opt/homebrew/bin/brew /usr/local/bin/brew; do
    [ -x "$p" ] && eval "$("$p" shellenv)" && break
  done
fi
export HOMEBREW_PREFIX="$(brew --prefix 2>/dev/null || echo /opt/homebrew)"
PKG="libavformat libavcodec libavutil libswscale libswresample"
FFP="$HOMEBREW_PREFIX/opt/ffmpeg-full"
[ -d "$FFP/lib/pkgconfig" ] || FFP="$HOMEBREW_PREFIX/opt/ffmpeg"
export PKG_CONFIG_PATH="$FFP/lib/pkgconfig:${PKG_CONFIG_PATH:-}"
FFMPEG="$FFP/bin/ffmpeg"; [ -x "$FFMPEG" ] || FFMPEG=ffmpeg
FFPROBE="$FFP/bin/ffprobe"; [ -x "$FFPROBE" ] || FFPROBE=ffprobe
OUT=build/core_test
mkdir -p build
"$FFMPEG" -hide_banner -loglevel error -y -f lavfi -i testsrc2=size=640x360:rate=30 \
  -f lavfi -i sine=frequency=440:sample_rate=44100 -t 4 -c:v libx264 -pix_fmt yuv420p -c:a aac /tmp/mc_src.mp4
SRTD="$HOMEBREW_PREFIX/opt/srt"
cc -std=gnu11 -O2 -ISources/Core -I"$SRTD/include" tests/core_test.c Sources/Core/mc_input.c Sources/Core/mc_output.c \
  Sources/Core/mc_pixel.c Sources/Core/mc_srt.c -L"$SRTD/lib" -lsrt -Wl,-rpath,"$SRTD/lib" -o $OUT $(pkg-config --cflags --libs $PKG) -Wl,-rpath,$FFP/lib -lpthread -lm \
  $( [ "$(uname)" = Darwin ] && echo "-framework VideoToolbox -framework CoreVideo -framework CoreMedia -framework CoreFoundation" )
./$OUT /tmp/mc_src.mp4
"$FFPROBE" -v error -show_entries stream=codec_name,width,height -of compact /tmp/mc_rec.mp4
