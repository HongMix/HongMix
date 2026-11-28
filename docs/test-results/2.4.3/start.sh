#!/bin/zsh
SP=$SCRATCH
# test app on a synthetic project: bars (1), pattern (2)
P=$SP/prs; AS="$HOME/Library/Application Support/HongMix"; rm -f "$AS/last-session.bmix"
api() { curl -s -m5 "http://127.0.0.1:8088/api/?$1" >/dev/null; }; enc() { python3 -I -c 'import urllib.parse,sys;print(urllib.parse.quote(sys.argv[1],safe=""))' "$1"; }; w() { perl -e "select(undef,undef,undef,$1)"; }
open -n ${1:-$SP/t243/HongMix.app}; for i in $(seq 1 80); do curl -s -m1 http://127.0.0.1:8088/api/ | grep -q '<inputs' && break; w 0.5; done; w 5
api "Function=SnapshotView&Value=lang-${2:-ko},/dev/null"; w 4; api "Function=DismissSheet"
api "Function=AddInput&Value=$(enc "Video|$P/media/bars.mp4")"; w 1; api "Function=AddInput&Value=$(enc "Video|$P/media/pattern.mp4")"; w 1
api "Function=CutDirect&Input=1"; api "Function=PreviewInput&Input=2"
open -a ${1:-$SP/t243/HongMix.app}; w 2; api "Function=ResizeWindow&Value=1600,1000"; w 2
