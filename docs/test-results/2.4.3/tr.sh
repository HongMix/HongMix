#!/bin/zsh
# Auto transitions on the operator's project: idle GPU, then 5 × each transition slot 1–4 between inputs 5 and 6.
SP=$SCRATCH
APP=$1; L=$2; AS="$HOME/Library/Application Support/HongMix"
pgrep -x HongMix >/dev/null && { echo running; exit 1; }
cp -p $SCRATCH/bk243/last-session.bmix "$AS/last-session.bmix"
api() { curl -s -m5 "http://127.0.0.1:8088/api/?$1" >/dev/null; }
w() { perl -e "select(undef,undef,undef,$1)"; }
st() { curl -s -m2 http://127.0.0.1:8088/api/ | grep -o '<renderStats[^>]*' | sed -E 's/.*maxMs="([^"]*)" dropped="([^"]*)" uiStallMs="([^"]*)" outputMonitorFps="([^"]*)".*/\1 \2 \3 \4/'; }
open -n "$APP"; for i in $(seq 1 80); do curl -s -m1 http://127.0.0.1:8088/api/ | grep -q '<inputs' && break; w 0.5; done; w 25; open -a "$APP"; w 2
api "Function=CutDirect&Input=6"; api "Function=PreviewInput&Input=5"; api "Function=Play&Input=5"; api "Function=Play&Input=6"; w 3
echo "$L idle GPU: $(python3 -I $SP/gpuproc.py 8 | grep -E 'HongMix$|WindowServer' | tr -s ' ' | tr '\n' ' ')"
for n in 1 2 3 4; do
  r=($(st)); d0=${r[2]}; mx=0; ui=0; mon=999
  for k in 1 2 3 4 5; do api "Function=Transition$n"; for t in $(seq 1 8); do r=($(st)); (( ${r[1]%.*} > mx )) && mx=${r[1]%.*}; (( ${r[3]%.*} > ui )) && ui=${r[3]%.*}; (( ${r[4]} < mon )) && mon=${r[4]}; w 0.2; done; done
  r=($(st)); echo "$L transition$n x5: drops+$(( ${r[2]} - d0 )) | render max ${mx}ms | UI stall max ${ui}ms | monitor fps min $mon"
done
osascript -e "tell application \"$APP\" to quit"; for i in $(seq 1 60); do pgrep -x HongMix >/dev/null || break; w 0.5; done
