#!/bin/zsh
SP=$SCRATCH
APP=$1; L=$2; O=$SP/rp/mix-$L; rm -rf $O; mkdir -p $O; AS="$HOME/Library/Application Support/HongMix"
cp -p $SP/bk240u/last-session.bmix "$AS/last-session.bmix"
api() { curl -s -m5 "http://127.0.0.1:8088/api/?$1"; }; w() { perl -e "select(undef,undef,undef,$1)"; }
open -n "$APP"; for i in $(seq 1 80); do curl -s -m1 http://127.0.0.1:8088/api/ | grep -q '<inputs' && break; w 0.5; done; w 12; open -a "$APP"; w 2
api "Function=SnapshotWindow&Value=$O/0-start.png" >/dev/null
api "Function=OpenWindow&Value=audiomixer" >/dev/null; w 2; api "Function=SnapshotAllWindows&Value=$O/1-open" >/dev/null; w 1
echo "$L close: $(api "Function=CloseWindow&Value=Audio%20Mixer")"; w 2; api "Function=SnapshotWindow&Value=$O/2-afterclose.png" >/dev/null
api "Function=OpenWindow&Value=audiomixer" >/dev/null; w 2; api "Function=SnapshotAllWindows&Value=$O/3-reopen" >/dev/null; w 1
echo "$L windows after reopen: $(ls $O/3-reopen | tr '\n' ' ')"
osascript -e "tell application \"$APP\" to quit"; for i in $(seq 1 60); do pgrep -x HongMix >/dev/null || break; w 0.5; done
