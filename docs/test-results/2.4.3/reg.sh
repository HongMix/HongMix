#!/bin/zsh
SP=$SCRATCH
# Regression on the operator's project: launch click, 30 s steady (drops, GPU), 20 fades, 10 cuts.
APP=$1; L=$2; AS="$HOME/Library/Application Support/HongMix"
pgrep -x HongMix >/dev/null && { echo running; exit 1; }
cp -p $SP/bk243/last-session.bmix "$AS/last-session.bmix"
api() { curl -s -m5 "http://127.0.0.1:8088/api/?$1" >/dev/null; }; w() { perl -e "select(undef,undef,undef,$1)"; }
drops() { curl -s -m3 http://127.0.0.1:8088/api/ | grep -o 'dropped="[0-9]*"' | grep -o '[0-9]*'; }
$SP/audwatch/audwatch 25 > $SP/f242/aud-$L.txt 2>&1 &
open -n "$APP"; for i in $(seq 1 80); do curl -s -m1 http://127.0.0.1:8088/api/ | grep -q '<inputs' && break; w 0.5; done; wait
open -a "$APP"; w 3
d0=$(drops); g=$(python3 -I $SP/gpuproc.py 15 | grep -E 'HongMix$' | awk '{print $1}'); w 15; d1=$(drops)
api "Function=CutDirect&Input=6"; api "Function=PreviewInput&Input=5"; w 1
for k in $(seq 1 20); do api "Function=Transition1"; w 1.2; done; d2=$(drops)
for k in $(seq 1 10); do api "Function=Cut"; w 0.6; done; d3=$(drops)
echo "$L: launch speaker opens $(grep -c 'HongMix.*output=ON' $SP/f242/aud-$L.txt) | steady 30s drops $((d1-d0)) HongMix GPU $g | 20 fades drops $((d2-d1)) | 10 cuts drops $((d3-d2))"
osascript -e "tell application \"$APP\" to quit"; for i in $(seq 1 60); do pgrep -x HongMix >/dev/null || break; w 0.5; done
