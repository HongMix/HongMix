#!/bin/bash
# Display output on a second monitor, incl. unplugging it — uses a virtual 1920×1080 display
# (private CGVirtualDisplay, test only) so no second physical monitor is needed.
# Needs a running HongMix (API :8088). Keeps the built-in screen awake while running: when the
# built-in display sleeps, macOS keeps the last active (virtual) display alive after it is removed.
# Leaves Display set to: window mode, automatic monitor, off.
set -u
cd "$(dirname "$0")"
OUT=${TMPDIR:-/tmp}/hongmix-window-test; mkdir -p "$OUT"
[ -x "$OUT/vdisplay" ] || swiftc -O -suppress-warnings -import-objc-header vdisplay/CGVirtualDisplay.h vdisplay/vdisplay.swift -o "$OUT/vdisplay" || exit 1
[ -x "$OUT/windows" ] || swiftc -O windows.swift -o "$OUT/windows" || exit 1
cat > "$OUT/dbounds.swift" <<'S'
import CoreGraphics
let id = UInt32(CommandLine.arguments[1]) ?? 0
let b = CGDisplayBounds(id); print(Int(b.origin.x), Int(b.origin.y), Int(b.width), Int(b.height), CGDisplayIsOnline(id))
S
[ -x "$OUT/dbounds" ] || swiftc -O "$OUT/dbounds.swift" -o "$OUT/dbounds" || exit 1
API=${API:-http://127.0.0.1:8088/api/}
curl -s -m 2 "$API" | grep -q "<version>" || { echo "HongMix API not reachable"; exit 1; }
f(){ curl -s -o /dev/null -m 3 "$API?Function=$1&Value=${2:-}"; sleep ${3:-2}; }
outwin(){ "$OUT/windows" | grep HongMix | grep "Output Window" | grep "onscreen: 1" | head -1; }
# CG window bounds of the output window → "x y w h"
outframe(){ "$OUT/windows" | grep HongMix | grep "Output Window" | grep "onscreen: 1" | head -1 | awk -F'|' '{print $3}' | awk '{print $1, $3}'; }
caffeinate -d -u -t 600 & CAF=$!
VPID=""
plug(){ "$OUT/vdisplay" 600 > "$OUT/vd.out" 2>&1 & VPID=$!; sleep 3; VID=$(grep -o 'display [0-9]*' "$OUT/vd.out" | awk '{print $2}'); }
unplug(){ kill -TERM $VPID 2>/dev/null; wait $VPID 2>/dev/null; sleep 3; }
FAIL=0
check(){ if eval "$2"; then echo "  OK    $1"; else echo "  FAIL  $1  ($3)"; FAIL=1; fi; }
trap 'kill $CAF 2>/dev/null; [ -n "$VPID" ] && kill -TERM $VPID 2>/dev/null' EXIT

echo "### 1) Display on the second monitor (chosen explicitly), full screen"
plug; read vx vy vw vh online < <("$OUT/dbounds" $VID)
check "virtual display online ($VID: ${vw}x${vh} at $vx,$vy)" '[ "$online" = 1 ] && [ "$vw" = 1920 ]' "vdisplay failed"
f FullscreenOff "" 1; f DisplayOutputMode fullscreen 1; f DisplayOutputDisplay $VID 1; f FullscreenOn "" 3
fr=$(outframe); check "output fills the second monitor" '[ "$fr" = "$vw $vh" ]' "frame=$fr"
echo "### 2) unplug the second monitor while Display is on"
unplug
check "output closed, no crash" '[ -z "$(outwin)" ] && curl -s -m 2 "$API" | grep -q "<version>"' "$(outwin)"
gone(){ for i in 1 2 3 4 5 6 7 8 9 10; do [ "$("$OUT/dbounds" $1 | awk '{print $3}')" = 0 ] && return 0; sleep 0.5; done; return 1; }
check "virtual display gone" 'gone $VID' "still online after 5 s"
echo "### 3) automatic monitor, window mode, green button fills the second monitor, then unplug"
plug; read vx vy vw vh online < <("$OUT/dbounds" $VID)
f DisplayOutputDisplay 0 1; f DisplayOutputMode window 1; f FullscreenOn "" 3
check "output window opened" '[ -n "$(outwin)" ]' "no window"
f OutputWindowZoomButton "" 3
fr=$(outframe); check "green button fills its monitor" '[ "$fr" = "$vw $vh" ] || [ "$fr" = "1728 1117" ]' "frame=$fr"
filled_on_virtual=0; [ "$fr" = "$vw $vh" ] && filled_on_virtual=1
unplug
fr=$(outframe)
if [ $filled_on_virtual = 1 ]; then
  check "unplugged while filled → back to a normal output window" '[ -n "$fr" ] && [ "$fr" != "$vw $vh" ]' "frame=$fr"
else
  check "output window still present" '[ -n "$fr" ]' "frame=$fr"
fi
check "app responsive" 'curl -s -m 2 "$API" | grep -q "<version>"' "API down"
f OutputWindowExit "" 1; f FullscreenOff "" 1; f DisplayOutputMode window 1; f DisplayOutputDisplay 0 1
[ $FAIL = 0 ] && echo "RESULT: PASS" || echo "RESULT: FAIL"
exit $FAIL
