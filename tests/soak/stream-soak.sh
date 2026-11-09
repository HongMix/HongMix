#!/bin/bash
# Long-run streaming soak of the output core: SRT caller → local SRT receiver for <minutes>.
# Checks A/V drift (audio end vs video end in the received stream), decode errors and the sender's memory.
# Usage: tests/soak/stream-soak.sh <minutes> [delay_ms]
set -u
cd "$(dirname "$0")/../.."
MIN=${1:-60}; DELAY=${2:-0}
export HOMEBREW_PREFIX="$(brew --prefix 2>/dev/null || echo /opt/homebrew)"
PKG="libavformat libavcodec libavutil libswscale libswresample"
FFP="$HOMEBREW_PREFIX/opt/ffmpeg-full"; [ -d "$FFP/lib/pkgconfig" ] || FFP="$HOMEBREW_PREFIX/opt/ffmpeg"
export PKG_CONFIG_PATH="$FFP/lib/pkgconfig:${PKG_CONFIG_PATH:-}"
FFMPEG="$FFP/bin/ffmpeg"; [ -x "$FFMPEG" ] || FFMPEG=ffmpeg
FFPROBE="$FFP/bin/ffprobe"; [ -x "$FFPROBE" ] || FFPROBE=ffprobe
SRTD="$HOMEBREW_PREFIX/opt/srt"
W="${TMPDIR:-/tmp}/hm-stream-soak"; rm -rf "$W"; mkdir -p "$W"
cc -std=gnu11 -O2 -ISources/Core -I"$SRTD/include" tests/delay_reconnect_test.c Sources/Core/mc_output.c \
  Sources/Core/mc_pixel.c Sources/Core/mc_srt.c -L"$SRTD/lib" -lsrt -Wl,-rpath,"$SRTD/lib" -o "$W/tx" \
  $(pkg-config --cflags --libs $PKG) -Wl,-rpath,$FFP/lib -lpthread -lm \
  -framework VideoToolbox -framework CoreVideo -framework CoreMedia -framework CoreFoundation || exit 1
"$FFMPEG" -hide_banner -loglevel error -y -copyts -i "srt://127.0.0.1:9730?mode=listener&latency=120000" -c copy -f mpegts "$W/rx.ts" & RX=$!
sleep 0.5
"$W/tx" "srt://127.0.0.1:9730?mode=caller&latency=120000&pkt_size=1316" $((MIN*60)) $DELAY 2> "$W/tx.log" & TX=$!
echo "streaming $MIN min (delay ${DELAY} ms) → $W/rx.ts"
while kill -0 $TX 2>/dev/null; do
  echo "$(date +%H:%M:%S) txRSS=$(( $(ps -o rss= -p $TX | tr -d ' ' || echo 0) / 1024 ))MB rx=$(( $(stat -f%z "$W/rx.ts" 2>/dev/null || echo 0) / 1048576 ))MB" >> "$W/mem.log"
  sleep 30
done
sleep 3; kill -INT $RX 2>/dev/null; wait $RX 2>/dev/null
ve=$("$FFPROBE" -v error -select_streams v -show_entries packet=pts_time -of csv=p=0 "$W/rx.ts" | tr -d ',' | sort -n | tail -1)
ae=$("$FFPROBE" -v error -select_streams a -show_entries packet=pts_time -of csv=p=0 "$W/rx.ts" | tr -d ',' | sort -n | tail -1)
vs=$("$FFPROBE" -v error -select_streams v -show_entries packet=pts_time -of csv=p=0 "$W/rx.ts" | tr -d ',' | sort -n | head -1)
as=$("$FFPROBE" -v error -select_streams a -show_entries packet=pts_time -of csv=p=0 "$W/rx.ts" | tr -d ',' | sort -n | head -1)
nv=$("$FFPROBE" -v error -select_streams v -count_packets -show_entries stream=nb_read_packets -of csv=p=0 "$W/rx.ts")
errs=$("$FFMPEG" -v error -i "$W/rx.ts" -f null - 2>&1 | wc -l | tr -d ' ')
grep -c "state=3" "$W/tx.log" | xargs echo "sender errors:"
echo "video $vs → $ve s ($nv frames, expected $((MIN*60*30))) · audio $as → $ae s · decode errors $errs"
python3 - "$vs" "$ve" "$as" "$ae" <<'P'
import sys
vs, ve, a_s, ae = map(float, sys.argv[1:])
d = ((ae - a_s) - (ve - vs)) * 1000
print(f"A/V drift over the run: {d:.1f} ms (audio span − video span; |d| < 50 ms = PASS)")
sys.exit(0 if abs(d) < 50 else 1)
P
r=$?; head -1 "$W/mem.log"; tail -1 "$W/mem.log"; [ $r = 0 ] && echo PASS || echo FAIL; exit $r
