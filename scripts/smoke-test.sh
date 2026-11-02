#!/bin/bash
# 실행 중인 HongMix를 vMix 호환 API(8088/8099)로 자동 점검합니다. 결과: build/logs/test.txt, build/logs/snap*.png
cd "$(dirname "$0")/.."
# build/control/task 에 "ui" 가 있으면 UI 캡처만 수행
if [ -f build/control/task ]; then TASK="$(cat build/control/task)"; rm -f build/control/task; [ "$TASK" = ui ] && exec bash scripts/ui-shot.sh
  if [ "$TASK" = webav ]; then
    API=http://127.0.0.1:8088/api/
    T="$PWD/build/test"; mkdir -p "$T"
    for p in /opt/homebrew/bin/brew; do [ -x "$p" ] && eval "$("$p" shellenv)"; done
    FF="$(brew --prefix)/opt/ffmpeg-full/bin/ffmpeg"
    [ -f "$T/av.mp4" ] || "$FF" -v error -y -f lavfi -i testsrc2=size=1280x720:rate=60 -f lavfi -i sine=frequency=880 -t 30 -c:v h264_videotoolbox -b:v 6M -c:a aac "$T/av.mp4"
    [ -f "$T/av.webm" ] || "$FF" -v error -y -f lavfi -i testsrc2=size=1280x720:rate=30 -f lavfi -i sine=frequency=880 -t 30 -c:v libvpx-vp9 -deadline realtime -cpu-used 8 -b:v 3M -c:a libopus "$T/av.webm"
    cat > "$T/av.html" <<'HTML'
<html><body style="margin:0;background:#000"><video id="v" autoplay loop playsinline style="width:100vw;height:100vh"><source src="av.webm" type="video/webm"><source src="av.mp4" type="video/mp4"></video></body></html>
HTML
    for k in $(curl -s -m 5 "$API" | grep -oE '<input key="[^"]+"[^>]*title="http://127.0.0.1:8765/av.html"' | sed -E 's/<input key="([^"]+)".*/\1/'); do
      curl -s -m 5 -G "$API" --data-urlencode "Function=RemoveInput" --data-urlencode "Input=$k" >/dev/null
    done
    (cd "$T" && python3 -m http.server 8765 >/dev/null 2>&1 &) ; sleep 1
    curl -s -m 5 -G "$API" --data-urlencode "Function=AddInput" --data-urlencode "Value=Browser|http://127.0.0.1:8765/av.html"; echo
    sleep 8
    N=$(curl -s -m 5 "$API" | grep -o '<input [^>]*title="http://127.0.0.1:8765/av.html"[^>]*' | tail -1)
    echo "$N" | grep -oE 'number="[0-9]+"|meterF1="[^"]+"|meterF2="[^"]+"'
    NUM=$(echo "$N" | sed -E 's/.*number="([0-9]+)".*/\1/')
    curl -s -m 5 -G "$API" --data-urlencode "Function=BrowserEvalJS" --data-urlencode "Input=$NUM" --data-urlencode "Value=JSON.stringify(window.__bmStats)+' t='+document.getElementById('v').currentTime.toFixed(1)+' src='+document.getElementById('v').currentSrc.split('/').pop()+' h264='+document.createElement('video').canPlayType('video/mp4; codecs=avc1.42E01E')"; echo; sleep 1
    curl -s -m 5 "$API" | grep -o '<message>[^<]*'
    curl -s -m 5 -G "$API" --data-urlencode "Function=SnapshotInput" --data-urlencode "Input=$NUM" --data-urlencode "Value=$PWD/build/logs/webav.png"; echo
    OLD=$(curl -s -m 5 "$API" | grep -oE '<active>[0-9]+' | grep -oE '[0-9]+')
    curl -s -m 5 -G "$API" --data-urlencode "Function=CutDirect" --data-urlencode "Input=$NUM" >/dev/null; sleep 2
    curl -s -m 5 "$API" | grep -o "<input [^>]*number=\"$NUM\"[^>]*" | grep -oE 'meterF1="[^"]+"|meterF2="[^"]+"'
    [ -n "$OLD" ] && curl -s -m 5 -G "$API" --data-urlencode "Function=CutDirect" --data-urlencode "Input=$OLD" >/dev/null
    curl -s -m 5 -G "$API" --data-urlencode "Function=RemoveInput" --data-urlencode "Input=$NUM"; echo
    echo "WEBAV DONE"; exit 0
  fi
  if [ "$TASK" = rec ]; then
    for p in /opt/homebrew/bin/brew; do [ -x "$p" ] && eval "$("$p" shellenv)"; done
    FFD="$(brew --prefix)/opt/ffmpeg-full/bin"; API=http://127.0.0.1:8088/api/
    curl -s -m 5 -G "$API" --data-urlencode "Function=Snapshot" --data-urlencode "Value=$PWD/build/logs/rec_program.png"; echo
    curl -s -m 5 -G "$API" --data-urlencode "Function=StartRecording"; echo; sleep 6
    curl -s -m 5 -G "$API" --data-urlencode "Function=StopRecording"; echo; sleep 3
    REC=$(ls -t ~/Movies/HongMix/*.* | head -1); echo "file: $REC"
    "$FFD/ffprobe" -v error -show_entries stream=codec_name,pix_fmt,width,height,r_frame_rate,nb_frames:format=duration -of compact "$REC"
    "$FFD/ffmpeg" -v error -y -ss 2 -i "$REC" -frames:v 1 "$PWD/build/logs/rec_frame.png"
    echo "REC DONE"; exit 0
  fi
  if [ "$TASK" = stress ]; then
    # 40 x 1080p59.94 H.264 file inputs (hardware decode) — measures render time, drops and CPU
    API=http://127.0.0.1:8088/api/
    for p in /opt/homebrew/bin/brew; do [ -x "$p" ] && eval "$("$p" shellenv)"; done
    FF="$(brew --prefix)/opt/ffmpeg-full/bin/ffmpeg"; T="$PWD/build/test"; mkdir -p "$T"
    [ -f "$T/s1080.mp4" ] || "$FF" -v error -y -f lavfi -i testsrc2=size=1920x1080:rate=60000/1001 -f lavfi -i sine=frequency=500 -t 20 -c:v h264_videotoolbox -b:v 12M -c:a aac "$T/s1080.mp4"
    COUNT=${COUNT:-40}
    stat() { curl -s -m 5 "$API" | grep -oE '<renderStats[^>]*'; }
    pcpu() { ps -o %cpu= -p $(pgrep -x HongMix | head -1) 2>/dev/null; }
    echo "before: $(stat) cpu=$(pcpu)"
    for i in $(seq 1 $COUNT); do
      cp -n "$T/s1080.mp4" "$T/stress_$i.mp4"
      curl -s -m 5 -G "$API" --data-urlencode "Function=AddInput" --data-urlencode "Value=Video|$T/stress_$i.mp4" >/dev/null
    done
    sleep 3
    for i in $(seq 1 $COUNT); do curl -s -m 5 -G "$API" --data-urlencode "Function=Play" --data-urlencode "Input=stress_$i.mp4" >/dev/null; done
    sleep 2
    # put 2 of them on air with an overlay so the mixer composites
    curl -s -m 5 -G "$API" --data-urlencode "Function=PreviewInput" --data-urlencode "Input=stress_1.mp4" >/dev/null
    for k in 1 2 3 4 5 6 7 8; do sleep 2; echo "t=$((k*2))s $(stat) cpu=$(pcpu)"; done
    curl -s -m 5 -G "$API" --data-urlencode "Function=Fade" --data-urlencode "Input=stress_2.mp4" --data-urlencode "Duration=1000" >/dev/null
    sleep 2; echo "after fade $(stat) cpu=$(pcpu)"
    curl -s -m 5 -G "$API" --data-urlencode "Function=SnapshotWindow" --data-urlencode "Value=$PWD/build/logs/ui_stress.png"; echo
    curl -s -m 5 -G "$API" --data-urlencode "Function=Snapshot" --data-urlencode "Value=$PWD/build/logs/stress_program.png"; echo
    "$FF" -v error -y -ss 5 -i "$T/s1080.mp4" -frames:v 1 "$PWD/build/logs/stress_ref.png"
    echo "STRESS DONE"; exit 0
  fi
  if [ "$TASK" = unstress ]; then
    API=http://127.0.0.1:8088/api/
    for k in $(curl -s -m 5 "$API" | grep -oE '<input key="[^"]+"[^>]*title="stress_[0-9]+.mp4"' | sed -E 's/<input key="([^"]+)".*/\1/'); do
      curl -s -m 5 -G "$API" --data-urlencode "Function=RemoveInput" --data-urlencode "Input=$k" >/dev/null
    done
    echo "UNSTRESS DONE"; exit 0
  fi
  if [ "$TASK" = cef ]; then
    bash scripts/fetch-cef.sh 2>&1 | tail -15; echo "CEF TASK DONE"; exit 0
  fi
  if [ "$TASK" = soak ]; then
    # 30 s: record + NDI out + fullscreen toggles; reports render/encoder/input drops and checks the file
    API=http://127.0.0.1:8088/api/
    for p in /opt/homebrew/bin/brew; do [ -x "$p" ] && eval "$("$p" shellenv)"; done
    FP="$(brew --prefix)/opt/ffmpeg-full/bin/ffprobe"
    q() { curl -s -m 5 -G "$API" --data-urlencode "Function=$1" ${2:+--data-urlencode "$2"} >/dev/null; }
    x() { curl -s -m 5 "$API"; }
    echo "start: $(x | grep -oE '<renderStats[^>]*')"
    q StartRecording; q StartExternal
    for k in 1 2 3 4 5 6; do
      sleep 2; q FullscreenOn; sleep 2; q FullscreenOff
      echo "t=$((k*4))s $(x | grep -oE '<renderStats[^>]*')"
    done
    sleep 4
    x | grep -oE '<inputStats[^>]*|<outputStats[^>]*'
    q StopRecording; q StopExternal; sleep 3
    REC=$(ls -t ~/Movies/HongMix/*.* | head -1); echo "file: $REC"
    "$FP" -v error -count_frames -select_streams v:0 -show_entries stream=nb_read_frames,r_frame_rate:format=duration -of compact "$REC"
    echo "end: $(x | grep -oE '<renderStats[^>]*') fullscreen=$(x | grep -oE '<fullscreen>[A-Za-z]+')"
    echo "SOAK DONE"; exit 0
  fi
  if [ "$TASK" = verifydmg ]; then
    A=build/cli/HongMix.app
    echo "== external library references (must be empty):"
    for f in "$A/Contents/MacOS/HongMix" "$A"/Contents/Frameworks/*.dylib; do
      otool -L "$f" 2>/dev/null | grep -E "/opt/homebrew|/usr/local|/Library/NDI" | sed "s#^#$(basename "$f"): #"
    done | head -20
    echo "== rpaths:"; otool -l "$A/Contents/MacOS/HongMix" | grep -A2 LC_RPATH | grep path
    echo "== bundle:"; du -sh "$A" "$A/Contents/Frameworks/Chromium Embedded Framework.framework"; ls "$A/Contents/Frameworks" | grep -cE "dylib$"
    ls "$A/Contents/Frameworks" | grep -E "Helper|ndi|Chromium"
    codesign --verify --deep --strict "$A" && echo "codesign OK"
    ls -la build/*.dmg
    echo "VERIFY DONE"; exit 0
  fi
  if [ "$TASK" = sh ]; then
    bash build/control/cmd.sh 2>&1 | tail -60; echo "SH DONE"; exit 0
  fi
  if [ "$TASK" = srttest ]; then
    API=http://127.0.0.1:8088/api/
    for p in /opt/homebrew/bin/brew; do [ -x "$p" ] && eval "$("$p" shellenv)"; done
    FF="$(brew --prefix)/opt/ffmpeg-full/bin/ffmpeg"
    echo "== C core SRT loopback"; bash scripts/test-core.sh 2>&1 | grep -E "srt|OK|FAIL|error" | head -8
    echo "== app SRT input (listener :9100) ← ffmpeg caller, 1080p30, latency 200ms"
    curl -s -m 5 -G "$API" --data-urlencode "Function=AddInput" --data-urlencode "Value=Stream|srt://:9100?mode=listener&latency=200000"; echo
    sleep 2
    "$FF" -v error -re -f lavfi -i testsrc2=size=1920x1080:rate=30 -f lavfi -i sine=frequency=700 -t 25 \
      -c:v h264_videotoolbox -b:v 8M -g 30 -c:a aac -f mpegts "srt://127.0.0.1:9100?mode=caller&latency=200000&pkt_size=1316" &
    FPID=$!
    sleep 2
    N=$(curl -s -m 5 "$API" | grep -oE '<srtStats input="[0-9]+"' | grep -oE '[0-9]+' | head -1)
    for k in $(seq 1 18); do sleep 1; X=$(curl -s -m 5 "$API")
      echo "t+$((k+4))s $(echo "$X" | grep -oE "<inputStats number=\"$N\"[^>]*" | grep -oE '(fps|measuredFps|jitterMs|late)="[^"]+"' | tr '\n' ' ') $(echo "$X" | grep -oE '<srtStats[^>]*' | grep -oE 'bufferMs="[^"]+"')"; done
    echo "$X" | grep -oE '<srtStats[^>]*'

    wait $FPID 2>/dev/null
    K=$(curl -s -m 5 "$API" | grep -oE '<input key="[^"]+"[^>]*title="srt://:9100[^"]*"' | sed -E 's/<input key="([^"]+)".*/\1/')
    for k in $K; do curl -s -m 5 -G "$API" --data-urlencode "Function=RemoveInput" --data-urlencode "Input=$k" >/dev/null; done
    echo "SRTTEST DONE"; exit 0
  fi
  if [ "$TASK" = datatest ]; then
    API=http://127.0.0.1:8088/api/
    q() { curl -s -m 5 -G "$API" --data-urlencode "Function=$1" ${2:+--data-urlencode "$2"} ${3:+--data-urlencode "$3"} ${4:+--data-urlencode "$4"}; echo; }
    C="$PWD/build/test/chips.csv"; mkdir -p build/test
    printf 'Player,Country,Chips\n"Kim, Minsu",KOR,1250000\nAlex Lee,USA,980000\n' > "$C"
    q AddInput "Value=Title|LowerThird"; sleep 1
    N=$(curl -s -m 5 "$API" | grep -oE '<input [^>]*type="GT"[^>]*' | tail -1 | sed -E 's/.*number="([0-9]+)".*/\1/')
    F=$(curl -s -m 5 "$API" | tr '>' '\n' | grep -A0 "<text index=\"0\"" | head -1 | sed -E 's/.*name="([^"]+)".*/\1/')
    echo "title #$N field '$F'"
    q DataSourceAdd "Value=Chips,$C"; sleep 2
    q DataSourceBind "Input=$N" "SelectedName=$F" "Value=Chips,0"; sleep 1
    curl -s -m 5 "$API" | grep -oE '<dataSource [^>]*'
    curl -s -m 5 "$API" | grep -oE "<input [^>]*number=\"$N\".*?</input>" | grep -oE '<text index="0"[^<]*' | head -1
    q DataSourceNextRow "Value=Chips"; sleep 1
    curl -s -m 5 "$API" | grep -oE "<input [^>]*number=\"$N\".*?</input>" | grep -oE '<text index="0"[^<]*' | head -1
    printf 'Player,Country,Chips\nPark Jisoo,KOR,2000000\nAlex Lee,USA,750000\n' > "$C"; sleep 7
    curl -s -m 5 "$API" | grep -oE "<input [^>]*number=\"$N\".*?</input>" | grep -oE '<text index="0"[^<]*' | head -1
    q RemoveInput "Input=$N"
    echo "DATATEST DONE"; exit 0
  fi
  if [ "$TASK" = webtest ]; then
    curl -s -m 5 -o /tmp/bm_tally.html -w "tally: %{http_code} %{size_download} bytes\n" http://127.0.0.1:8088/tally
    curl -s -m 5 -o build/logs/thumb1.jpg -w "thumb: %{http_code} %{content_type} %{size_download} bytes %{time_total}s\n" "http://127.0.0.1:8088/thumb?input=1&width=320"
    curl -s -m 5 -o /dev/null -w "remote: %{http_code} %{size_download} bytes\n" http://127.0.0.1:8088/
    curl -s -m 5 -w "\n" http://127.0.0.1:8088/tally.txt
    echo "WEBTEST DONE"; exit 0
  fi
  if [ "$TASK" = lufs ]; then
    API=http://127.0.0.1:8088/api/
    for p in /opt/homebrew/bin/brew; do [ -x "$p" ] && eval "$("$p" shellenv)"; done
    FF="$(brew --prefix)/opt/ffmpeg-full/bin/ffmpeg"; T="$PWD/build/test"; mkdir -p "$T"
    # 997 Hz sine at -20 dBFS on both channels: BS.1770 says this reads -20.0 LUFS
    [ -f "$T/tone20.wav" ] || "$FF" -v error -y -f lavfi -i "aevalsrc=0.1*sin(2*PI*997*t)|0.1*sin(2*PI*997*t):s=48000:d=30" -c:a pcm_s16le "$T/tone20.wav"
    q() { curl -s -m 5 -G "$API" --data-urlencode "Function=$1" ${2:+--data-urlencode "$2"} ${3:+--data-urlencode "$3"}; echo; }
    OLD=$(curl -s -m 5 "$API" | grep -oE '<active>[0-9]+' | grep -oE '[0-9]+')
    q AddInput "Value=Video|$T/tone20.wav"; sleep 1
    N=$(curl -s -m 5 "$API" | grep -oE '<input [^>]*title="tone20.wav"' | grep -oE 'number="[0-9]+"' | grep -oE '[0-9]+' | tail -1)
    echo "tone input #$N"
    q CutDirect "Input=$N"; q AudioOn "Input=$N"; q Play "Input=$N"; sleep 1; q LoudnessReset
    for k in 2 4 6 8; do sleep 2; echo "t+${k}s $(curl -s -m 5 "$API" | grep -oE '<loudness[^>]*')"; done
    [ -n "$OLD" ] && q CutDirect "Input=$OLD"
    q RemoveInput "Input=$N"; q LoudnessReset
    echo "LUFS DONE"; exit 0
  fi
  if [ "$TASK" = sched ]; then
    API=http://127.0.0.1:8088/api/
    q() { curl -s -m 5 -G "$API" --data-urlencode "Function=$1" ${2:+--data-urlencode "$2"} ${3:+--data-urlencode "$3"}; echo; }
    PV=$(curl -s -m 5 "$API" | grep -oE '<preview>[0-9]+' | grep -oE '[0-9]+')
    TT=$(date -v+4S +%H:%M:%S)
    echo "preview before=$PV, scheduling PreviewInput 2 at $TT"
    q ScheduleAdd "Value=$TT,PreviewInput,2" "SelectedName=smoke"
    curl -s -m 5 "$API" | grep -oE '<action [^>]*'
    sleep 6
    X=$(curl -s -m 5 "$API"); echo "preview after=$(echo "$X" | grep -oE '<preview>[0-9]+' | grep -oE '[0-9]+')"
    echo "$X" | grep -oE '<action [^>]*' | grep -oE 'lastFired="[^"]*"|next="[^"]*"'
    echo "$X" | grep -oE '<message>[^<]*'
    q ScheduleRemove "Value=smoke"; [ -n "$PV" ] && q PreviewInput "Input=$PV"
    echo "loudness: $(echo "$X" | grep -oE '<loudness[^>]*')"
    echo "SCHED DONE"; exit 0
  fi
  if [ "$TASK" = delay ]; then
    API=http://127.0.0.1:8088/api/
    q() { curl -s -m 5 -G "$API" --data-urlencode "Function=$1" ${2:+--data-urlencode "$2"}; echo; }
    q StartRecording; sleep 1; q StopRecording; sleep 1      # make sure a record output exists
    q SetDelay "Value=6"; q StartRecording
    for k in 2 4 6 8; do sleep 2; echo "t+${k}s $(curl -s -m 5 "$API" | grep -oE '<outputStats [^>]*kind="record"[^>]*' | grep -oE 'stats="[^"]*"|delayMs="[^"]*"|dumped="[^"]*"' | tr '\n' ' ')"; done
    q DelayDump; sleep 2
    echo "after dump: $(curl -s -m 5 "$API" | grep -oE '<outputStats [^>]*kind="record"[^>]*' | grep -oE 'stats="[^"]*"|delayMs="[^"]*"|dumped="[^"]*"' | tr '\n' ' ')"
    q StopRecording; sleep 2; q SetDelay "Value=0"
    F=$(curl -s -m 5 "$API" | grep -oE '<outputStats [^>]*kind="record"[^>]*' | grep -oE 'file="[^"]*"' | sed 's/file="//;s/"$//')
    echo "file: $F"; ls -la "$F" 2>/dev/null
    for p in /opt/homebrew/bin/brew; do [ -x "$p" ] && eval "$("$p" shellenv)"; done
    "$(brew --prefix)/opt/ffmpeg-full/bin/ffprobe" -v error -show_entries format=duration -of csv=p=0 "$F" 2>&1 | head -2
    echo "DELAY DONE"; exit 0
  fi
  if [ "$TASK" = failover ]; then
    API=http://127.0.0.1:8088/api/
    for p in /opt/homebrew/bin/brew; do [ -x "$p" ] && eval "$("$p" shellenv)"; done
    FF="$(brew --prefix)/opt/ffmpeg-full/bin/ffmpeg"
    q() { curl -s -m 5 -G "$API" --data-urlencode "Function=$1" ${2:+--data-urlencode "$2"} ${3:+--data-urlencode "$3"}; echo; }
    st() { X=$(curl -s -m 5 "$API"); echo "$1: active=$(echo "$X" | grep -oE '<active>[0-9]+' | grep -oE '[0-9]+') $(echo "$X" | grep -oE "<inputStats number=\"$S\"[^>]*" | grep -oE 'fps="[^"]+"|measuredFps="[^"]+"|jitterMs="[^"]+"|signalLost="[^"]+"' | tr '\n' ' ') msg=$(echo "$X" | grep -oE '<message>[^<]*' | sed 's/<message>//')"; }
    send() { "$FF" -v error -re -f lavfi -i testsrc2=size=1280x720:rate=30 -f lavfi -i sine=frequency=500 -t $1 -c:v h264_videotoolbox -b:v 4M -g 30 -c:a aac -f mpegts "srt://127.0.0.1:9200?mode=caller&latency=120000&pkt_size=1316" & }
    OLD=$(curl -s -m 5 "$API" | grep -oE '<active>[0-9]+' | grep -oE '[0-9]+')
    q AddInput "Value=Stream|srt://:9200?mode=listener&latency=120000"
    q AddInput "Value=Colour|#2050A0"; sleep 1
    X=$(curl -s -m 5 "$API"); S=$(echo "$X" | grep -oE '<input [^>]*title="srt://:9200[^"]*"' | grep -oE 'number="[0-9]+"' | grep -oE '[0-9]+')
    B=$(echo "$X" | grep -oE '<input [^>]*type="Colour"[^>]*' | tail -1 | grep -oE 'number="[0-9]+"' | grep -oE '[0-9]+')
    echo "srt=#$S backup=#$B"; q SetBackupInput "Input=$S" "Value=$B"
    send 8; sleep 5; q CutDirect "Input=$S"; sleep 1; st "on air"
    sleep 4; st "sender stopped +1s"; sleep 2; st "+3s"
    send 10; sleep 5; st "sender back +5s"
    [ -n "$OLD" ] && q CutDirect "Input=$OLD"
    for k in $(curl -s -m 5 "$API" | grep -oE '<input key="[^"]+"[^>]*title="(srt://:9200[^"]*|Colour)"' | sed -E 's/<input key="([^"]+)".*/\1/'); do q RemoveInput "Input=$k" >/dev/null; done
    wait; echo "FAILOVER DONE"; exit 0
  fi
  if [ "$TASK" = crash ]; then
    ls -t ~/Library/Logs/DiagnosticReports/ 2>/dev/null | grep -i hongmix | head -5
    F=$(ls -t ~/Library/Logs/DiagnosticReports/*racelet* 2>/dev/null | head -1)
    [ -n "$F" ] && cp "$F" build/logs/last-crash.ips && echo "copied $F"
    echo "CRASH DONE"; exit 0
  fi
  if [ "$TASK" = perf ]; then
    for k in $(seq 1 ${SECS:-15}); do sleep 1; echo "$(date +%S) $(curl -s -m 3 http://127.0.0.1:8088/api/ | grep -oE '<renderStats[^>]*') cpu=$(P=$(pgrep -x HongMix | head -1); [ -n "$P" ] && ps -o %cpu= -p $P || echo "앱 꺼짐")"; done
    curl -s -m 3 http://127.0.0.1:8088/api/ | grep -oE '<browserCapture[^>]*|<inputStats[^>]*'
    curl -s -m 3 http://127.0.0.1:8088/api/ | grep -oE '<active>[0-9]+|<preview>[0-9]+'
    echo "PERF DONE"; exit 0
  fi
  if [ "$TASK" = list ]; then
    curl -s -m 5 http://127.0.0.1:8088/api/ | grep -oE '<input key="[^"]+" number="[0-9]+" type="[A-Za-z]+" title="[^"]*"'; echo "LIST DONE"; exit 0
  fi
  if [ "$TASK" = cleanup ]; then
    # remove the inputs the automated tests added (Colour / clip.mp4 / Lower Third / example.com / click.html)
    API=http://127.0.0.1:8088/api/
    for k in $(curl -s -m 3 "$API" | grep -oE '<input key="[^"]+" number="[0-9]+" type="[A-Za-z]+" title="[^"]*"' \
               | grep -E 'title="(Colour|clip.mp4|하단 자막 \(Lower Third\)|https://example.com|file://[^"]*click.html|[^"]*click.html|http://127.0.0.1:8765/av.html)"' \
               | sed -E 's/<input key="([^"]+)".*/\1/'); do
      curl -s -m 3 -G "$API" --data-urlencode "Function=RemoveInput" --data-urlencode "Input=$k"; echo " removed $k"
    done
    echo "CLEANUP DONE"; exit 0
  fi
  if [ "$TASK" = browser ]; then
    API=http://127.0.0.1:8088/api/
    H="$PWD/build/test/click.html"; mkdir -p build/test
    cat > "$H" <<'HTML'
<html><body style="margin:0;background:#223;color:#fff;font:40px sans-serif">
<button id="b" style="position:absolute;left:0;top:0;width:50%;height:50%;font-size:60px" onclick="window.n=(window.n||0)+1;document.title+=' click'+window.n">CLICK</button>
<input id="t" style="position:absolute;left:0;top:60%;width:90%;height:20%;font-size:60px" onfocus="document.title+=' focus'" onkeydown="document.title+=' key:'+event.key">
</body></html>
HTML
    q() { curl -s -m 5 -G "$API" --data-urlencode "Function=$1" ${2:+--data-urlencode "$2"} ${3:+--data-urlencode "$3"}; echo; }
    q AddInput "Value=Browser|file://$H"
    sleep 4
    N=$(curl -s -m 3 "$API" | grep -o '<input [^>]*type="Browser"[^>]*' | tail -1 | sed -E 's/.*number="([0-9]+)".*/\1/')
    echo "browser input #$N"
    q PreviewInput "Input=$N"
    q BrowserEvalJS "Input=$N" "Value=document.title"; sleep 1; curl -s -m 5 "$API" | grep -o '<message>[^<]*'
    q BrowserClick "Input=$N" "Value=0.25,0.25"; sleep 1
    q BrowserEvalJS "Input=$N" "Value=document.title"; sleep 1; curl -s -m 5 "$API" | grep -o '<message>[^<]*'
    q BrowserClick "Input=$N" "Value=0.25,0.25"; sleep 1
    q BrowserEvalJS "Input=$N" "Value=document.title"; sleep 1; curl -s -m 5 "$API" | grep -o '<message>[^<]*'
    q BrowserClick "Input=$N" "Value=0.4,0.7"; sleep 1
    q BrowserEvalJS "Input=$N" "Value=document.title + ' active=' + document.activeElement.id"; sleep 1; curl -s -m 5 "$API" | grep -o '<message>[^<]*'
    curl -s -m 5 -G "$API" --data-urlencode "Function=SnapshotWindow" --data-urlencode "Value=$PWD/build/logs/ui_browser.png"; echo
    echo "BROWSER TEST DONE"
    exit 0
  fi
  if [ "$TASK" = ndi ]; then
    PKG="$HOME/Downloads/Install_NDI_SDK_v6_Apple.pkg"
    curl -fL -o "$PKG" https://downloads.ndi.tv/SDK/NDI_SDK_Mac/Install_NDI_SDK_v6_Apple.pkg && open "$PKG" && echo "NDI PKG OPENED" || echo "NDI DOWNLOAD FAILED"
    exit 0
  fi
fi
for p in /opt/homebrew/bin/brew /usr/local/bin/brew; do [ -x "$p" ] && eval "$("$p" shellenv)" && break; done
FFD="$(brew --prefix 2>/dev/null)/opt/ffmpeg-full/bin"
FF="$FFD/ffmpeg"; FP="$FFD/ffprobe"
T="$PWD/build/test"; L="$PWD/build/logs"
mkdir -p "$T"; rm -f "$L"/snap*.png "$T"/srt_rx.ts
API=http://127.0.0.1:8088/api/
call() { local r; r=$(curl -s -m 5 -G "$API" --data-urlencode "Function=$1" ${2:+--data-urlencode "$2"} ${3:+--data-urlencode "$3"} ${4:+--data-urlencode "$4"}); echo "$1 $2 $3 $4 → ${r:0:120}"; }
step() { echo; echo "## $*"; }

step "API 연결"
for i in 1 2 3 4 5; do curl -s -m 2 "$API" >/dev/null && break; sleep 1; done
curl -s -m 3 "$API" | head -c 600; echo

step "테스트 클립 생성"
[ -f "$T/clip.mp4" ] || "$FF" -hide_banner -loglevel error -f lavfi -i testsrc2=size=1280x720:rate=30 -f lavfi -i sine=frequency=440 -t 20 -c:v h264_videotoolbox -b:v 4M -c:a aac -shortest "$T/clip.mp4"
ls -la "$T/clip.mp4"

step "입력 추가"
call AddInput "Value=Colour|#C03030"
call AddInput "Value=Video|$T/clip.mp4"
call AddInput "Value=Title|LowerThird"
call AddInput "Value=Browser|https://example.com"
sleep 3
curl -s -m 3 "$API" | grep -o '<input [^>]*>' | head -10

step "전환"
call PreviewInput "Input=2"
call Cut
call Play "Input=2"
sleep 2
call Snapshot "Value=$L/snap1_cut_video.png"
call SetText "Input=3" "Value=HongMix 테스트" "SelectedIndex=0"
call OverlayInput1In "Input=3"
sleep 2
call Snapshot "Value=$L/snap2_overlay_title.png"
call Fade "Input=1" "Duration=500"
sleep 2
call Snapshot "Value=$L/snap3_fade_colour.png"
call OverlayInput1Out
call Cut "Input=4"
sleep 3
call Snapshot "Value=$L/snap4_browser.png"
call Cut "Input=2"

step "TCP 8099"
{ printf 'FUNCTION PreviewInput Input=1\r\n'; sleep 0.5; printf 'TALLY\r\n'; sleep 0.5; printf 'XMLTEXT vmix/inputs/input[2]/@title\r\n'; sleep 1; } | nc -w 2 127.0.0.1 8099 | head -c 400; echo

step "녹화 5초"
BEFORE=$(ls -t ~/Movies/HongMix/*.* 2>/dev/null | head -1)
call StartRecording
sleep 5
call StopRecording
sleep 2
REC=$(ls -t ~/Movies/HongMix/*.* 2>/dev/null | head -1)
echo "file: $REC"
[ -n "$REC" ] && [ "$REC" != "$BEFORE" ] && "$FP" -v error -show_entries stream=codec_name,width,height,r_frame_rate:format=duration -of compact "$REC"

step "SRT 출력 → 로컬 수신"
"$FF" -hide_banner -loglevel error -y -i "srt://127.0.0.1:9998?mode=listener" -t 6 -c copy "$T/srt_rx.ts" &
RX=$!
sleep 1
call StreamingSetURL "Value=srt://127.0.0.1:9998?mode=caller"
call StartStreaming
sleep 8
call StopStreaming
wait $RX 2>/dev/null
"$FP" -v error -show_entries stream=codec_name,width,height:format=duration -of compact "$T/srt_rx.ts" 2>&1 | head -4

step "최종 상태"
curl -s -m 3 "$API" | head -c 1500; echo
ls -la "$L"/snap*.png 2>/dev/null
echo; echo "SMOKE TEST DONE"
