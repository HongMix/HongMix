#!/bin/bash
# Display output (Fullscreen) regression test — needs a running HongMix with the HTTP API on :8088.
# Checks after every step: macOS full-screen Spaces (none may be added by HongMix), the current Space
# (the switcher must never be yanked to another desktop) and the HongMix windows on screen.
# Usage: bash tests/window/test-display-output.sh   (run from the repo root; builds the two helpers once)
set -u
cd "$(dirname "$0")"
OUT=${TMPDIR:-/tmp}/hongmix-window-test; mkdir -p "$OUT"
[ -x "$OUT/spaces" ] || swiftc -O spaces.swift -o "$OUT/spaces" || exit 1
[ -x "$OUT/windows" ] || swiftc -O windows.swift -o "$OUT/windows" || exit 1
API=${API:-http://127.0.0.1:8088/api/}
curl -s -m 2 "$API" | grep -q "<version>" || { echo "HongMix API not reachable at $API"; exit 1; }
f(){ curl -s -m 3 "$API?Function=$1&Value=${2:-}" >/dev/null; sleep ${3:-2.5}; }
fs(){ "$OUT/spaces" | grep -c FULLSCREEN; }
cur(){ "$OUT/spaces" | grep -o 'current=[0-9]*' | head -1 | cut -d= -f2; }
vis(){ "$OUT/windows" | grep HongMix | grep "onscreen: 1" | grep -v " 0 x 0\| x 33 \| x 32 \| x 2[01] " | awk -F'|' '{gsub(/ onscreen: 1 layer: [0-9]+/,"",$3); printf "[%s%s] ", $2, $3}'; }
FAIL=0
step(){ local name=$1 expect_space=$2 expect_fs=$3 want=$4
  local s=$(cur) n=$(fs) w=$(vis) ok=OK
  [ "$s" != "$expect_space" ] && ok="FAIL(space $s≠$expect_space)"
  [ "$n" != "$expect_fs" ] && ok="FAIL(fullscreen spaces $n≠$expect_fs)"
  [ -n "$want" ] && ! echo "$w" | grep -q "$want" && ok="FAIL(missing $want)"
  [ "$ok" != OK ] && FAIL=1
  printf "  %-34s %-28s %s\n" "$name" "$ok" "$w"; }
run(){ local sp=$1 n=$2
  f DisplayOutputMode window 1.5; f FullscreenOn;            step "window ON" $sp $n "Output Window"
  f OutputWindowZoomButton;                                   step "green button (fill)" $sp $n "Output Window"
  f OutputWindowExit;                                         step "Esc → window" $sp $n "Output Window"
  f OutputWindowZoomButton; f FullscreenOff;                  step "fill, then Display OFF" $sp $n ""
  f FullscreenOn;                                             step "Display ON again (window)" $sp $n "Output Window"
  f FullscreenOff
  f OutputWindowSystemFullScreen "" 1; f FullscreenOn; f OutputWindowSystemFullScreen; step "⌃⌘F on output window" $sp $n ""
  f FullscreenOff
  f DisplayOutputMode fullscreen 1.5; f FullscreenOn;        step "display-fullscreen ON" $sp $n "Output Window"
  f OutputWindowExit;                                         step "Esc" $sp $n ""; }
echo "### A) switcher window normal"
f MainWindowFullscreen off 3; base=$(fs); sp=$(cur); run $sp $base
echo "### B) switcher window in macOS full screen"
f MainWindowFullscreen on 1; for i in $(seq 1 10); do [ "$(fs)" -gt "$base" ] && break; sleep 1; done
run $(cur) $(fs)
f MainWindowFullscreen off 3
[ $FAIL = 0 ] && echo "RESULT: PASS" || echo "RESULT: FAIL"
exit $FAIL
