#!/bin/zsh
SP=$SCRATCH
# Functional check on a synthetic project (no real footage): ko | en. Screens to $O.
P=$SP/prs; APP=$1; LANGX=$2; O=$SP/f242/${OUTDIR:-}$LANGX; rm -rf $O; mkdir -p $O
AS="$HOME/Library/Application Support/HongMix"
pgrep -x HongMix >/dev/null && { echo "HongMix running"; exit 1; }
rm -f "$AS/last-session.bmix"     # restored from bk242 afterwards
api() { curl -s -m5 "http://127.0.0.1:8088/api/?$1"; }
q() { api "$1" >/dev/null; }
enc() { python3 -I -c 'import urllib.parse,sys;print(urllib.parse.quote(sys.argv[1],safe=""))' "$1"; }
w() { perl -e "select(undef,undef,undef,$1)"; }
xml() { curl -s -m3 http://127.0.0.1:8088/api/; }
open -n "$APP"; for i in $(seq 1 80); do curl -s -m1 http://127.0.0.1:8088/api/ | grep -q '<inputs' && break; w 0.5; done; w 5
q "Function=SnapshotView&Value=lang-$LANGX,/dev/null"; w 4; q "Function=DismissSheet"
q "Function=AddInput&Value=$(enc "Video|$P/media/bars.mp4")"; w 1
q "Function=AddInput&Value=$(enc "Video|$P/media/pattern.mp4")"; w 1
q "Function=AddInput&Value=$(enc "Colour|#2E5C8A")"; w 1
q "Function=SetInputName&Input=1&Value=$(enc "Camera 1")"; q "Function=SetInputName&Input=2&Value=$(enc "Camera 2")"; q "Function=SetInputName&Input=3&Value=$(enc "Graphics")"
q "Function=CutDirect&Input=1"; q "Function=PreviewInput&Input=2"; q "Function=Play&Input=1"; q "Function=Play&Input=2"
open -a "$APP"; w 2; q "Function=ResizeWindow&Value=1600,1000"; w 3
q "Function=SnapshotWindow&Value=$O/01-main.png"; w 1
# 1) rename while running: tiles / monitor labels must follow (child change through the engine)
q "Function=SetInputName&Input=1&Value=$(enc "Renamed Cam")"; w 1.5
q "Function=MasterAudioOff"; w 1
q "Function=OverlayInput1In&Input=3"; w 1.5
q "Function=SnapshotWindow&Value=$O/02-renamed-muted-overlay.png"; w 1
q "Function=OverlayInput1Out"; q "Function=MasterAudioOn"
# 2) cut / fade: tally follows
q "Function=Cut"; w 1; q "Function=SnapshotWindow&Value=$O/03-after-cut.png"; w 1
q "Function=Transition1"; w 2; q "Function=SnapshotWindow&Value=$O/04-after-fade.png"; w 1
# 3) PR #17: input settings Color tab with the live preview
for t in 1 2 5; do q "Function=SnapshotView&Value=props-1-$t,/dev/null"; w 3; q "Function=SnapshotAllWindows&Value=$O/05-props-tab$t"; w 2; q "Function=CloseWindow&Value=Snapshot%20props"; w 1; done
# 4) PR #15: Video Cue input + two cues, GO
q "Function=AddInput&Value=VideoCue"; w 2
q "Function=VideoCueAdd&Value=$(enc "$P/media/bars.mp4")"; q "Function=VideoCueAdd&Value=$(enc "$P/media/pattern.mp4")"; w 1
q "Function=VideoCueGo"; w 2
N=$(xml | grep -o '<input [^>]*' | wc -l | tr -d ' ')
q "Function=PreviewInput&Input=$N"; w 1
q "Function=SnapshotView&Value=videocue,$O/07-videocue.png"; w 3
q "Function=SnapshotWindow&Value=$O/08-main-videocue-preview.png"; w 1
q "Function=VideoCueStop"
# 5) PR #16: MultiLayout input, boxes 1/2 = Camera inputs, Quad scene, on Program, then CUT back must be instant
q "Function=AddInput&Value=MultiLayout"; w 2
M=$(xml | grep -o '<input [^>]*' | wc -l | tr -d ' ')
q "Function=MultiLayoutBoxInput&Input=$M&Value=1,1"; q "Function=MultiLayoutBoxInput&Input=$M&Value=2,2"; q "Function=MultiLayoutScene&Input=$M&Value=4"; w 1
q "Function=CutDirect&Input=$M"; w 2
q "Function=SnapshotWindow&Value=$O/09-main-multilayout.png"; w 1
q "Function=SnapshotView&Value=multilayouts,$O/10-multilayouts.png"; w 3
q "Function=PreviewInput&Input=2"; t0=$(perl -MTime::HiRes=time -e 'printf "%.3f", time')
q "Function=Cut"; for i in $(seq 1 40); do xml | grep -q "<active>2</active>" && break; w 0.025; done; t1=$(perl -MTime::HiRes=time -e 'printf "%.3f", time')
echo "$LANGX CUT away from MultiLayout took $(perl -e "printf '%.0f', ($t1-$t0)*1000") ms (active=$(xml | grep -o '<active>[0-9]*</active>'))"
echo "$LANGX inputs: $(xml | grep -o '<input [^>]*title="[^"]*"' | sed -E 's/.*title="([^"]*)"/\1/' | tr '\n' '|')"
echo "$LANGX master muted after On: $(xml | grep -o '<master [^>]*' | grep -o 'muted="[^"]*"')"
osascript -e "tell application \"$APP\" to quit"; for i in $(seq 1 40); do pgrep -x HongMix >/dev/null || break; w 0.5; done
ls $O
