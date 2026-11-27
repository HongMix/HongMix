#!/bin/zsh
# UI responsiveness: window open/close twice, mixer toggle, master mute, activation. Operator project (AI on).
SP=$SCRATCH
APP=$1; L=$2; AS="$HOME/Library/Application Support/HongMix"
pgrep -x HongMix >/dev/null && { echo running; exit 1; }
cp -p $SP/bk2310/last-session.bmix "$AS/last-session.bmix"
api() { curl -s -m5 "http://127.0.0.1:8088/api/?$1" >/dev/null; }
w() { perl -e "select(undef,undef,undef,$1)"; }
enc() { python3 -I -c 'import urllib.parse,sys;print(urllib.parse.quote(sys.argv[1]))' "$1"; }
ui() { local mx=0 u; for k in $(seq 1 10); do u=$(curl -s -m2 http://127.0.0.1:8088/api/ | grep -o 'uiStallMs="[0-9]*"' | grep -o '[0-9]*'); u=${u:-0}; (( u > mx )) && mx=$u; w 0.25; done; echo $mx; }
open -n "$APP"; for i in $(seq 1 80); do curl -s -m1 http://127.0.0.1:8088/api/ | grep -q '<inputs' && break; w 0.5; done; w 25; open -a "$APP"; w 3
PID=$(pgrep -x HongMix)
line="$L |"
for pair in "replay:Replay" "scopes:Scopes" "talentcue:Talent Cue" "multiview:MultiView" "audiomixer:Audio Mixer"; do id=${pair%%:*}; t=${pair#*:}
  api "Function=OpenWindow&Value=$id"; a=$(ui); api "Function=CloseWindow&Value=$(enc "$t")"; w 1
  api "Function=OpenWindow&Value=$id"; b=$(ui); api "Function=CloseWindow&Value=$(enc "$t")"; w 1
  line="$line $t ${a}/${b}ms |"; done
api "Function=DisplayOutputMode&Value=window"; api "Function=FullscreenOn"; a=$(ui); api "Function=FullscreenOff"; w 1; api "Function=FullscreenOn"; b=$(ui); api "Function=FullscreenOff"; w 1
line="$line Display ${a}/${b}ms |"
api "Function=AudioMixerShowHide"; a=$(ui); api "Function=AudioMixerShowHide"; b=$(ui); line="$line mixer dock hide/show ${a}/${b}ms |"
api "Function=MasterAudioOff"; a=$(ui); api "Function=MasterAudioOn"; b=$(ui); line="$line master mute ${a}/${b}ms |"
osascript -e "tell application \"System Events\" to set visible of (first process whose unix id is $PID) to false"; w 3; open -a "$APP"; a=$(ui); line="$line unhide ${a}ms"
echo $line
osascript -e "tell application \"$APP\" to quit"; for i in $(seq 1 60); do pgrep -x HongMix >/dev/null || break; w 0.5; done
