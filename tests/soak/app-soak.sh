#!/bin/bash
# Long-run soak of the running HongMix app (local recording only — never starts the configured
# stream destinations). Usage: tests/soak/app-soak.sh <minutes> [log]
# Every 10 s logs render drops, per-input stats, outputs and the app's memory; at the end stops the
# recording and checks the files: decodable, audio duration vs video duration (A/V drift).
set -u
MIN=${1:-60}
LOG=${2:-"${TMPDIR:-/tmp}/hongmix-soak-$(date +%Y%m%d_%H%M%S).log"}
API=http://127.0.0.1:8088/api/
x() { curl -s --max-time 3 "$API${1:-}"; }
pid=$(pgrep -f "MacOS/HongMix" | head -1)
[ -n "$pid" ] || { echo "HongMix is not running"; exit 1; }
if x | grep -q "<streaming>True"; then echo "Streaming is on — stop it first (soak never touches live streams)"; exit 1; fi
mark=$(mktemp); sleep 1
x "?Function=StartRecording" >/dev/null
echo "soak start $(date) for $MIN min, pid $pid" | tee "$LOG"
end=$(( $(date +%s) + MIN * 60 ))
while [ "$(date +%s)" -lt "$end" ]; do
  xml=$(x)
  rss=$(ps -o rss= -p "$pid" | tr -d ' ')
  rec=$(echo "$xml" | grep -o '<recording>[^<]*' | cut -d'>' -f2)
  drops=$(echo "$xml" | grep -oE '<renderStats [^>]*>' | grep -oE 'avgMs="[^"]*"|maxMs="[^"]*"|dropped="[^"]*"' | tr '\n' ' ')
  ins=$(echo "$xml" | grep -oE '<inputStats [^>]*>' | sed -E 's/.*number="([0-9]+)".*measuredFps="([^"]*)".*maxGapMs="([^"]*)".*signalLost="([^"]*)".*mixUnderflows="([^"]*)".*/\1:fps=\2,gap=\3,lost=\4,uf=\5/' | tr '\n' ' ')
  outs=$(echo "$xml" | grep -oE '<outputStats [^>]*kind="record"[^>]*>' | grep -oE 'state="[^"]*"' | tr '\n' ' ')
  echo "$(date +%H:%M:%S) rssMB=$((rss/1024)) rec=$rec $drops $outs | $ins" >> "$LOG"
  sleep 10
done
x "?Function=StopRecording" >/dev/null; sleep 5
echo "== files" | tee -a "$LOG"
for f in $(find ~/Movies/HongMix -maxdepth 1 -type f -newer "$mark" \( -name '*.mov' -o -name '*.mp4' -o -name '*.ts' \)); do
  v=$(ffprobe -v error -select_streams v -show_entries stream=duration -of csv=p=0 "$f" | head -1)
  a=$(ffprobe -v error -select_streams a:0 -show_entries stream=duration -of csv=p=0 "$f" | head -1)
  [ -z "$v" ] || [ "$v" = "N/A" ] && v=$(ffprobe -v error -select_streams v -count_packets -show_entries stream=nb_read_packets,r_frame_rate -of csv=p=0 "$f" | awk -F, '{split($1,r,"/"); print $2/(r[1]/r[2])}')
  [ -z "$a" ] || [ "$a" = "N/A" ] && a=$(ffprobe -v error -select_streams a:0 -show_entries packet=pts_time,duration_time -of csv=p=0 "$f" | tail -1 | awk -F, '{print $1+$2}')
  errs=$(ffmpeg -v error -i "$f" -f null - 2>&1 | wc -l | tr -d ' ')
  echo "$(basename "$f") video=${v}s audio=${a}s drift=$(python3 -c "print(round(($a-$v)*1000,1))")ms decodeErrors=$errs" | tee -a "$LOG"
done
first=$(sed -n 2p "$LOG" | grep -o 'rssMB=[0-9]*'); last=$(tail -n +2 "$LOG" | grep rssMB | tail -1 | grep -o 'rssMB=[0-9]*')
echo "memory $first → $last" | tee -a "$LOG"
echo "log: $LOG"
rm -f "$mark"
