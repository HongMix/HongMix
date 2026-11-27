#!/bin/zsh
# Window-open cost: per window, 5 s after opening — drops, max UI stall, max render ms.
SP=$SCRATCH
APP=$1; L=$2; AS="$HOME/Library/Application Support/HongMix"
pgrep -x HongMix >/dev/null && { echo running; exit 1; }
cp -p $SP/bk2310/last-session.bmix "$AS/last-session.bmix"
api() { curl -s -m5 "http://127.0.0.1:8088/api/?$1" >/dev/null; }
st() { curl -s -m2 http://127.0.0.1:8088/api/ | grep -o '<renderStats[^>]*' | sed -E 's/.*avgMs="([^"]*)" maxMs="([^"]*)" dropped="([^"]*)" uiStallMs="([^"]*)".*/\2 \3 \4/'; }
w() { perl -e "select(undef,undef,undef,$1)"; }
open -n "$APP"; for i in $(seq 1 80); do curl -s -m1 http://127.0.0.1:8088/api/ | grep -q '<inputs' && break; w 0.5; done; w 6; open -a "$APP"
api "Function=Play&Input=5"; api "Function=ReplayStartRecording"; w 25
measure() { # name
  local d0=$(st | awk '{print $2}'); local mx=0 ui=0
  for k in $(seq 1 20); do r=($(st)); [ ${r[1]%.*} -gt $mx ] && mx=${r[1]%.*}; [ ${r[3]%.*} -gt $ui ] && ui=${r[3]%.*}; w 0.25; done
  local d1=$(st | awk '{print $2}'); echo "$L $1: drops+$((d1-d0)) | UI stall max ${ui}ms | render max ${mx}ms"
}
for win in replay scopes audiomixer multiview talentcue; do api "Function=OpenWindow&Value=$win"; measure $win; w 2; done
api "Function=DisplayOutputMode&Value=window"; api "Function=FullscreenOn"; measure display; api "Function=FullscreenOff"; w 1
api "Function=ReplayMarkInOutLive&Value=6"; w 1; api "Function=ReplaySetSpeed&Value=50"; api "Function=ReplayPlayLastEventToOutput"; w 1; measure slowmo
api "Function=ReplayStopRecording"; osascript -e "tell application \"$APP\" to quit"; for i in $(seq 1 60); do pgrep -x HongMix >/dev/null || break; w 0.5; done
