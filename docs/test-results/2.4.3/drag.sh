#!/bin/zsh
SP=$SCRATCH
# Simulated slider drag: input 6 (on Program) pan X changed 30×/s for 4 s; UI stall / monitor fps during it.
APP=$1; L=$2; AS="$HOME/Library/Application Support/HongMix"
pgrep -x HongMix >/dev/null && { echo running; exit 1; }
cp -p $SP/bk243/last-session.bmix "$AS/last-session.bmix"
api() { curl -s -m5 "http://127.0.0.1:8088/api/?$1" >/dev/null; }; w() { perl -e "select(undef,undef,undef,$1)"; }
st() { curl -s -m2 http://127.0.0.1:8088/api/ | grep -o '<renderStats[^>]*' | sed -E 's/.*dropped="([^"]*)" uiStallMs="([^"]*)" outputMonitorFps="([^"]*)".*/\1 \2 \3/'; }
open -n "$APP"; for i in $(seq 1 80); do curl -s -m1 http://127.0.0.1:8088/api/ | grep -q '<inputs' && break; w 0.5; done; w 25; open -a "$APP"; w 3
api "Function=CutDirect&Input=6"; api "Function=PreviewInput&Input=5"; w 2
for round in 1 2; do
  ( for k in $(seq 0 119); do v=$(( (k % 40) - 20 )); api "Function=SetPanX&Input=6&Value=0.0$(( v < 0 ? -v : v ))"; w 0.033; done ) &
  ui=0; mon=999; for t in $(seq 1 20); do r=($(st)); (( ${r[2]%.*} > ui )) && ui=${r[2]%.*}; (( ${r[3]} < mon )) && mon=${r[3]}; w 0.2; done; wait
  echo "$L drag round $round: UI stall max ${ui}ms, monitor fps min $mon"
done
api "Function=SetPanX&Input=6&Value=0"
osascript -e "tell application \"$APP\" to quit"; for i in $(seq 1 60); do pgrep -x HongMix >/dev/null || break; w 0.5; done
