#!/bin/bash
# Recording safety: backup mirror recording (same encoded packets to a second disk, both split together,
# either file failing keeps the other one recording) and "continue on another disk when full" (on a real
# ENOSPC and proactively below a free-space reserve) with no lost frames. Uses two RAM disks (a tiny one
# that fills up, a larger one as a second volume); they are always detached at the end.
set -u
cd "$(dirname "$0")/.."
export HOMEBREW_PREFIX="$(brew --prefix 2>/dev/null || echo /opt/homebrew)"
PKG="libavformat libavcodec libavutil libswscale libswresample"
FFP="$HOMEBREW_PREFIX/opt/ffmpeg-full"; [ -d "$FFP/lib/pkgconfig" ] || FFP="$HOMEBREW_PREFIX/opt/ffmpeg"
export PKG_CONFIG_PATH="$FFP/lib/pkgconfig:${PKG_CONFIG_PATH:-}"
FFMPEG="$FFP/bin/ffmpeg"; [ -x "$FFMPEG" ] || FFMPEG=ffmpeg
FFPROBE="$FFP/bin/ffprobe"; [ -x "$FFPROBE" ] || FFPROBE=ffprobe
SRTD="$HOMEBREW_PREFIX/opt/srt"
W="${TMPDIR:-/tmp}/hm-recsafety-test"; rm -rf "$W"; mkdir -p "$W"
BIN="$W/rec_safety_test"
cc -std=gnu11 -O2 -ISources/Core -I"$SRTD/include" tests/rec_safety_test.c Sources/Core/mc_output.c \
  Sources/Core/mc_pixel.c Sources/Core/mc_srt.c -L"$SRTD/lib" -lsrt -Wl,-rpath,"$SRTD/lib" -o "$BIN" \
  $(pkg-config --cflags --libs $PKG) -Wl,-rpath,$FFP/lib -lpthread -lm \
  -framework VideoToolbox -framework CoreVideo -framework CoreMedia -framework CoreFoundation || exit 1

SMALL_NAME="HMRecSmall$$"; BIG_NAME="HMRecBig$$"
SMALL_DEV=""; BIG_DEV=""
cleanup() {
  [ -n "$SMALL_DEV" ] && hdiutil detach "$SMALL_DEV" -force >/dev/null 2>&1
  [ -n "$BIG_DEV" ] && hdiutil detach "$BIG_DEV" -force >/dev/null 2>&1
}
trap cleanup EXIT INT TERM
mkdisk() {   # sectors name → device
  local dev
  dev=$(hdiutil attach -nomount "ram://$1" 2>/dev/null | awk '{print $1}')
  [ -n "$dev" ] || return 1
  diskutil erasevolume HFS+ "$2" "$dev" >/dev/null 2>&1 || { hdiutil detach "$dev" -force >/dev/null 2>&1; return 1; }
  echo "$dev"
}
SMALL_DEV=$(mkdisk 6144 "$SMALL_NAME") || { echo "FAIL: cannot create RAM disk"; exit 1; }     # 3 MB
BIG_DEV=$(mkdisk 131072 "$BIG_NAME") || { echo "FAIL: cannot create RAM disk"; exit 1; }       # 64 MB
SMALL="/Volumes/$SMALL_NAME"; BIG="/Volumes/$BIG_NAME"
L="$W/local"; mkdir -p "$L"
echo "RAM disks: $SMALL ($SMALL_DEV), $BIG ($BIG_DEV)"

cat > "$W/chk.py" <<'PY'
import sys, subprocess, os
ffprobe, ffmpeg, runfile = sys.argv[1], sys.argv[2], sys.argv[3]
run = dict(l.rstrip('\n').split('=', 1) for l in open(runfile) if '=' in l)
ok = True
def check(cond, msg):
    global ok
    print(("  ok    " if cond else "  FAIL  ") + msg)
    ok = ok and cond
cache = {}
def frames(p):
    if p not in cache:
        if not os.path.exists(p):
            cache[p] = -1
        else:
            out = subprocess.run([ffprobe, '-v', 'error', '-select_streams', 'v', '-count_frames', '-show_entries',
                                  'stream=nb_read_frames', '-of', 'csv=p=0', p], capture_output=True, text=True).stdout
            try: cache[p] = int(out.strip().split('\n')[0].strip(','))
            except: cache[p] = -1
    return cache[p]
def decodes(p):
    r = subprocess.run([ffmpeg, '-hide_banner', '-v', 'error', '-i', p, '-f', 'null', '-'], capture_output=True, text=True)
    return (r.stdout + r.stderr).strip()
def md5(p):
    r = subprocess.run([ffmpeg, '-hide_banner', '-v', 'error', '-i', p, '-map', '0:v', '-c', 'copy', '-f', 'framemd5', '-'],
                       capture_output=True, text=True).stdout
    return [l.split(',')[-1].strip() for l in r.split('\n') if l and not l.startswith('#')]
name = lambda p: p.rsplit('/', 1)[-1]
print(f"  encoder {run.get('encoder')}, encoded {run.get('frames_encoded')}, dropped {run.get('frames_dropped')}, "
      f"mirror_state {run.get('mirror_state')}, main_failed {run.get('main_failed')}, spills {run.get('spills')}, "
      f"warnings {run.get('warnings')} (last: {run.get('last_warning')})")
print(f"  current_file {run.get('current_file')}\n  backup_file  {run.get('backup_file') or '-'} (at 1 s: {run.get('backup_file_mid') or '-'})")
check(run.get('saw_error') == '0', "never went to ERROR")
check(run.get('frames_dropped') == '0', "encoder dropped no frames")
pushed = int(run['frames_pushed'])
for spec in sys.argv[4:]:
    kind, arg = spec.split(':', 1)
    if kind == 'kv':
        k, v = arg.split('=', 1)
        check(run.get(k) == v, f"{k} = {v} (got {run.get(k)})")
    elif kind == 'count':
        p, n = arg.rsplit('=', 1)
        check(frames(p) == int(n), f"{name(p)}: {frames(p)} frames (want {n})")
    elif kind == 'partial':
        p = arg
        check(0 < frames(p) < pushed, f"{name(p)}: partial, {frames(p)} frames")
    elif kind == 'sum':
        ps = arg.split(',')
        n = [frames(p) for p in ps]
        check(all(x > 0 for x in n) and sum(n) == pushed,
              " + ".join(f"{name(p)} {x}" for p, x in zip(ps, n)) + f" = {sum(n)} (pushed {pushed})")
    elif kind == 'same':
        a, b = arg.split(',')
        ma, mb = md5(a), md5(b)
        check(len(ma) > 0 and ma == mb, f"{name(a)} and backup {name(b)}: identical video packets ({len(ma)} / {len(mb)})")
    elif kind == 'decodes':
        for p in arg.split(','):
            d = decodes(p)
            check(d == '', f"{name(p)} decodes without errors" + ('' if d == '' else ': ' + d[:200]))
    elif kind == 'absent':
        check(not os.path.exists(arg), f"{name(arg)} not created")
sys.exit(0 if ok else 1)
PY

fail=0
run_case() {   # title, then args for the binary, then "--", then checks
  local title="$1"; shift
  local args=()
  while [ "$1" != "--" ]; do args+=("$1"); shift; done; shift
  echo "== $title"
  rm -rf "$SMALL"/* "$BIG"/* 2>/dev/null
  "$BIN" "${args[@]}" > "$W/run.txt" 2> "$W/run.log" || { cat "$W/run.log"; fail=1; return; }
  grep -E "mc_output:" "$W/run.log" | sed 's/^/  log: /'
  python3 "$W/chk.py" "$FFPROBE" "$FFMPEG" "$W/run.txt" "$@" || fail=1
}
free_bytes() { rm -rf "$1"/* 2>/dev/null; df -k "$1" | awk 'NR==2 {print $4 * 1024}'; }

# 10. backup mirror on a second volume: identical packets, no second encode
mkdir -p "$L/A"
run_case "mirror to a second disk (.mov)" "$L/A/rec.mov" "$BIG/A" - 0 -- \
  kv:mirror_state=1 kv:backup_file="$BIG/A/rec.mov" count:"$L/A/rec.mov"=180 count:"$BIG/A/rec.mov"=180 \
  same:"$L/A/rec.mov","$BIG/A/rec.mov" decodes:"$L/A/rec.mov","$BIG/A/rec.mov"

# 10 + split: both files split together
mkdir -p "$L/B"
run_case "mirror + seamless split (.mp4)" "$L/B/a.mp4" "$BIG/B" - 0 "$L/B/b.mp4" -- \
  kv:split_rc=0 kv:mirror_state=1 kv:backup_file="$BIG/B/b.mp4" sum:"$L/B/a.mp4","$L/B/b.mp4" \
  sum:"$BIG/B/a.mp4","$BIG/B/b.mp4" same:"$L/B/a.mp4","$BIG/B/a.mp4" same:"$L/B/b.mp4","$BIG/B/b.mp4" \
  decodes:"$L/B/a.mp4","$L/B/b.mp4","$BIG/B/a.mp4","$BIG/B/b.mp4"

# 11. main disk runs full (real ENOSPC) → continues in the spill folder, nothing lost
run_case "disk full → spill folder (.mov, ENOSPC)" "$SMALL/C.mov" - "$L/C_spill" 0 -- \
  kv:spills=1 kv:current_file="$L/C_spill/C_cont.mov" sum:"$SMALL/C.mov","$L/C_spill/C_cont.mov" \
  decodes:"$SMALL/C.mov","$L/C_spill/C_cont.mov"

run_case "disk full → spill folder (.ts, ENOSPC)" "$SMALL/C.ts" - "$L/C2_spill" 0 -- \
  kv:spills=1 kv:current_file="$L/C2_spill/C_cont.ts" sum:"$SMALL/C.ts","$L/C2_spill/C_cont.ts" \
  decodes:"$SMALL/C.ts","$L/C2_spill/C_cont.ts"

# 11. free space below the reserve → seamless split to the spill folder before anything fails
RES=$(( $(free_bytes "$SMALL") - 1500000 ))
run_case "below reserve → seamless spill (.mov, reserve $RES)" "$SMALL/D.mov" - "$L/D_spill" "$RES" -- \
  kv:spills=1 kv:main_failed=0 kv:current_file="$L/D_spill/D_cont.mov" sum:"$SMALL/D.mov","$L/D_spill/D_cont.mov" \
  decodes:"$SMALL/D.mov","$L/D_spill/D_cont.mov"

# 10. main disk fails, backup works → the backup becomes the recording
run_case "main disk full, backup keeps recording (.mov)" "$SMALL/E.mov" "$L/E_bak" - 0 -- \
  kv:main_failed=1 kv:current_file="$L/E_bak/E.mov" count:"$L/E_bak/E.mov"=180 partial:"$SMALL/E.mov" \
  decodes:"$SMALL/E.mov","$L/E_bak/E.mov"

# 10. backup disk fails → main keeps recording
run_case "backup disk full, main keeps recording (.mov)" "$L/F.mov" "$SMALL/F" - 0 -- \
  kv:mirror_state=2 kv:main_failed=0 count:"$L/F.mov"=180 partial:"$SMALL/F/F.mov" decodes:"$L/F.mov","$SMALL/F/F.mov"

# 10 + 11. spill onto the backup disk: the spill file becomes the main recording, mirroring stops
RES=$(( $(free_bytes "$SMALL") - 1500000 ))
run_case "spill onto the backup disk stops mirroring (.mov)" "$SMALL/G.mov" "$L/G_bak" "$L/G_bak" "$RES" -- \
  kv:spills=1 kv:mirror_state=0 kv:backup_file= kv:backup_file_mid="$L/G_bak/G.mov" \
  sum:"$SMALL/G.mov","$L/G_bak/G_cont.mov" same:"$SMALL/G.mov","$L/G_bak/G.mov" \
  decodes:"$SMALL/G.mov","$L/G_bak/G.mov","$L/G_bak/G_cont.mov"

[ $fail -eq 0 ] && echo PASS || echo FAIL
exit $fail
