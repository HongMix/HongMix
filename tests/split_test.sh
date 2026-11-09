#!/bin/bash
# Seamless "New file every N min" split (mc_output_split): no frame lost, file 2 starts with a keyframe
# at pts ≈ 0, audio as long as video in both files, both decode cleanly. mp4/mov/ts, H.264 (VideoToolbox
# and libx264), HEVC, ProRes.
set -u
cd "$(dirname "$0")/.."
export HOMEBREW_PREFIX="$(brew --prefix 2>/dev/null || echo /opt/homebrew)"
PKG="libavformat libavcodec libavutil libswscale libswresample"
FFP="$HOMEBREW_PREFIX/opt/ffmpeg-full"; [ -d "$FFP/lib/pkgconfig" ] || FFP="$HOMEBREW_PREFIX/opt/ffmpeg"
export PKG_CONFIG_PATH="$FFP/lib/pkgconfig:${PKG_CONFIG_PATH:-}"
FFMPEG="$FFP/bin/ffmpeg"; [ -x "$FFMPEG" ] || FFMPEG=ffmpeg
FFPROBE="$FFP/bin/ffprobe"; [ -x "$FFPROBE" ] || FFPROBE=ffprobe
SRTD="$HOMEBREW_PREFIX/opt/srt"
W="${TMPDIR:-/tmp}/hm-split-test"; rm -rf "$W"; mkdir -p "$W"
BIN="$W/split_test"
cc -std=gnu11 -O2 -ISources/Core -I"$SRTD/include" tests/split_test.c Sources/Core/mc_output.c \
  Sources/Core/mc_pixel.c Sources/Core/mc_srt.c -L"$SRTD/lib" -lsrt -Wl,-rpath,"$SRTD/lib" -o "$BIN" \
  $(pkg-config --cflags --libs $PKG) -Wl,-rpath,$FFP/lib -lpthread -lm \
  -framework VideoToolbox -framework CoreVideo -framework CoreMedia -framework CoreFoundation || exit 1
fail=0
for case in "mp4 h264" "mov h264" "ts h264" "mov prores" "mp4 h264 sw" "mov hevc"; do
  set -- $case
  ext=$1; codec=$2; sw=${3:-}
  f1="$W/a_$codec$sw.$ext"; f2="$W/b_$codec$sw.$ext"
  echo "== $codec .$ext $sw"
  "$BIN" "$f1" "$f2" "$codec" $sw > "$W/run.txt" 2> "$W/run.log" || { cat "$W/run.log"; fail=1; continue; }
  for f in "$f1" "$f2"; do
    "$FFPROBE" -v error -select_streams v -show_entries frame=pts_time,key_frame -of csv=p=0 "$f" > "$f.v"
    "$FFPROBE" -v error -select_streams a -show_entries frame=pts_time,nb_samples -of csv=p=0 "$f" > "$f.a"
    "$FFMPEG" -hide_banner -v error -i "$f" -f null - > "$f.dec" 2>&1
  done
  python3 - "$W/run.txt" "$f1" "$f2" <<'PY' || fail=1
import sys
run = dict(l.strip().split('=', 1) for l in open(sys.argv[1]) if '=' in l)
ok = True
def check(cond, msg):
    global ok
    print(("  ok    " if cond else "  FAIL  ") + msg)
    ok = ok and cond
def rows(p):
    out = []
    for l in open(p):
        parts = [x for x in l.strip().split(',') if x != '']
        if len(parts) >= 2: out.append(parts)
    return out
pushed = int(run['frames_pushed'])
print(f"  encoder {run['encoder']}, split_rc {run['split_rc']}, encoded {run['frames_encoded']}, dropped {run['frames_dropped']}")
check(run['split_rc'] == '0', "mc_output_split accepted")
check(run['current_file_ok'] == '1', "mc_output_current_file reports the new file")
n = []
for f in sys.argv[2:]:
    v = rows(f + '.v'); a = rows(f + '.a')
    # csv order follows -show_entries order inside [FRAME]: key_frame,pts_time / pts_time,nb_samples
    vk = [(float(r[1]) if r[1] != 'N/A' else None, int(r[0])) for r in v]
    vdur = len(vk) / 30.0
    asamp = sum(int(r[1]) for r in a)
    adur = asamp / 48000.0
    a0 = float(a[0][0]) if a else float('nan')
    dec = open(f + '.dec').read().strip()
    name = f.rsplit('/', 1)[1]
    print(f"  {name}: {len(vk)} frames ({vdur:.3f} s), first pts {vk[0][0]:.3f} key={vk[0][1]}; audio {adur:.3f} s from {a0:.3f}")
    check(vk[0][1] == 1, f"{name} starts with a keyframe")
    check(abs(vk[0][0]) < 0.05 or name.endswith('.ts'), f"{name} video starts at ~0")
    check(abs(adur - vdur) < 0.05, f"{name} audio length ≈ video length (diff {1000*(adur-vdur):.0f} ms)")
    check(dec == '', f"{name} decodes without errors" + ('' if dec == '' else ': ' + dec[:200]))
    n.append(len(vk))
check(n[0] + n[1] == pushed, f"frames file1 + file2 = {n[0]} + {n[1]} = {n[0]+n[1]} (pushed {pushed})")
check(int(run['frames_dropped']) == 0, "encoder dropped no frames")
check(abs(n[0] - 90) <= 3, "cut at ~3 s")
sys.exit(0 if ok else 1)
PY
done
[ $fail -eq 0 ] && echo PASS || echo FAIL
exit $fail
