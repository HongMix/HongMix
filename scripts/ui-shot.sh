#!/bin/bash
# 창 크기별 UI 캡처: build/logs/ui_<w>x<h>.png
cd "$(dirname "$0")/.."
API=http://127.0.0.1:8088/api/
N=$(curl -s -m 3 "$API" | grep -o '<input ' | wc -l | tr -d ' ')
if [ "${ADD_TEST_INPUTS:-0}" = 1 ] && [ "${N:-0}" -lt 4 ]; then
  for v in "Colour|#C03030" "Video|$PWD/build/test/clip.mp4" "Title|LowerThird" "Browser|https://example.com"; do
    curl -s -m 3 -G "$API" --data-urlencode "Function=AddInput" --data-urlencode "Value=$v" >/dev/null
  done
  sleep 2
fi
SIZES="${SIZES:-1440,900 1920,1080 1280,800}"
for s in $SIZES; do
  curl -s -m 3 -G "$API" --data-urlencode "Function=ResizeWindow" --data-urlencode "Value=$s"; echo
  sleep 1.5
  curl -s -m 5 -G "$API" --data-urlencode "Function=SnapshotWindow" --data-urlencode "Value=$PWD/build/logs/ui_${s/,/x}.png"; echo
done
echo "UI SHOT DONE"
