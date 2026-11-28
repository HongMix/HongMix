#!/bin/zsh
# UI stall after single engine changes (max uiStallMs in the 2.5 s after each action), operator's project.
SP=$SCRATCH
APP=$1; L=$2; AS="$HOME/Library/Application Support/HongMix"
pgrep -x HongMix >/dev/null && { echo running; exit 1; }
cp -p $SP/bk243/last-session.bmix "$AS/last-session.bmix"
api() { curl -s -m5 "http://127.0.0.1:8088/api/?$1" >/dev/null; }
w() { perl -e "select(undef,undef,undef,$1)"; }
st() { curl -s -m2 http://127.0.0.1:8088/api/ | grep -o '<renderStats[^>]*' | sed -E 's/.*uiStallMs="([^"]*)" outputMonitorFps="([^"]*)".*/\1 \2/'; }
meas() { local ui=0 mon=999; api "$1"; for t in $(seq 1 12); do r=($(st)); (( ${r[1]%.*} > ui )) && ui=${r[1]%.*}; (( ${r[2]} < mon )) && mon=${r[2]}; w 0.2; done; echo -n "$ui/$mon "; }
open -n "$APP"; for i in $(seq 1 80); do curl -s -m1 http://127.0.0.1:8088/api/ | grep -q '<inputs' && break; w 0.5; done; w 25; open -a "$APP"; w 3
api "Function=CutDirect&Input=6"; api "Function=PreviewInput&Input=5"; w 3
echo -n "$L master mute (ms/fps): "; for k in 1 2 3; do meas "Function=MasterAudioOff"; meas "Function=MasterAudioOn"; done; echo
echo -n "$L cut: "; for k in 1 2 3 4; do meas "Function=Cut"; done; echo
echo -n "$L preview change: "; for k in 1 2 3; do meas "Function=PreviewInput&Input=4"; meas "Function=PreviewInput&Input=5"; done; echo
echo -n "$L fade (Transition1): "; for k in 1 2 3; do meas "Function=Transition1"; done; echo
echo -n "$L overlay1 in/out: "; for k in 1 2; do meas "Function=OverlayInput1In&Input=3"; meas "Function=OverlayInput1Out"; done; echo
for win in audiomixer scopes replay talentcue multiview; do echo -n "$L open $win: "; meas "Function=OpenWindow&Value=$win"; echo; done
osascript -e "tell application \"$APP\" to quit"; for i in $(seq 1 60); do pgrep -x HongMix >/dev/null || break; w 0.5; done
