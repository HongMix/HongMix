#!/bin/bash
# Broadcast delay survives a network drop (HongMix 1.4.7).
# 4 s delay, SRT receiver killed at 10 s and restarted at 13 s. PASS when the second recording starts
# with the packets that were held at the drop (first video pts ≈ where the first recording ended),
# not with fresh content from after the reconnect (which was the old behaviour: delay thrown away).
set -u
cd "$(dirname "$0")/.."
export HOMEBREW_PREFIX="$(brew --prefix 2>/dev/null || echo /opt/homebrew)"
PKG="libavformat libavcodec libavutil libswscale libswresample"
FFP="$HOMEBREW_PREFIX/opt/ffmpeg-full"; [ -d "$FFP/lib/pkgconfig" ] || FFP="$HOMEBREW_PREFIX/opt/ffmpeg"
export PKG_CONFIG_PATH="$FFP/lib/pkgconfig:${PKG_CONFIG_PATH:-}"
FFMPEG="$FFP/bin/ffmpeg"; [ -x "$FFMPEG" ] || FFMPEG=ffmpeg
FFPROBE="$FFP/bin/ffprobe"; [ -x "$FFPROBE" ] || FFPROBE=ffprobe
SRTD="$HOMEBREW_PREFIX/opt/srt"
W="${TMPDIR:-/tmp}/hm-delay-test"; rm -rf "$W"; mkdir -p "$W"
BIN="$W/delay_reconnect_test"
cc -std=gnu11 -O2 -ISources/Core -I"$SRTD/include" tests/delay_reconnect_test.c Sources/Core/mc_output.c \
  Sources/Core/mc_pixel.c Sources/Core/mc_srt.c -L"$SRTD/lib" -lsrt -Wl,-rpath,"$SRTD/lib" -o "$BIN" \
  $(pkg-config --cflags --libs $PKG) -Wl,-rpath,$FFP/lib -lpthread -lm \
  -framework VideoToolbox -framework CoreVideo -framework CoreMedia -framework CoreFoundation || exit 1
RX="srt://127.0.0.1:9720?mode=listener&latency=120000"
"$FFMPEG" -hide_banner -loglevel error -y -copyts -i "$RX" -c copy -f mpegts "$W/part1.ts" & R1=$!
sleep 0.5
"$BIN" "srt://127.0.0.1:9720?mode=caller&latency=120000&pkt_size=1316" 26 2> "$W/out.log" & TX=$!
sleep 10; kill -INT $R1; wait $R1 2>/dev/null
sleep 3
"$FFMPEG" -hide_banner -loglevel error -y -copyts -i "$RX" -c copy -f mpegts "$W/part2.ts" & R2=$!
wait $TX
sleep 2; kill -INT $R2 2>/dev/null; wait $R2 2>/dev/null
cat "$W/out.log"
p() { "$FFPROBE" -v error -select_streams v -show_entries packet=pts_time -of csv=p=0 "$1" | tr -d ',' | grep -v '^$'; }
END1=$(p "$W/part1.ts" | sort -n | tail -1)
START2=$(p "$W/part2.ts" | sort -n | head -1)
N1=$(p "$W/part1.ts" | wc -l | tr -d ' '); N2=$(p "$W/part2.ts" | wc -l | tr -d ' ')
echo "part1: $N1 frames, last pts $END1 s"
echo "part2: $N2 frames, first pts $START2 s"
python3 - "$END1" "$START2" <<'EOF'
import sys
e, s = float(sys.argv[1]), float(sys.argv[2])
gap = s - e
print(f"content gap between the two connections: {gap:.2f} s (held packets kept → < ~2.2 s, one GOP at most)")
sys.exit(0 if -0.1 < gap < 2.3 else 1)
EOF
r=$?; [ $r -eq 0 ] && echo PASS || echo FAIL; exit $r
