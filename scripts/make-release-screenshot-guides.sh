#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DIR="$ROOT/docs/screenshots/2.0.9"
FONT="/System/Library/Fonts/SFNS.ttf"

make_en() {
  local input="$1" output="$2" title="$3" subtitle="$4" line_y="$5"
  ffmpeg -hide_banner -loglevel error -y -i "$DIR/$input" \
    -vf "drawbox=x=0:y=0:w=iw:h=${line_y}:color=0x111419:t=fill,drawbox=x=0:y=$((line_y-5)):w=iw:h=5:color=0x2f8cff:t=fill,drawtext=fontfile='${FONT}':text='${title}':fontcolor=white:fontsize=56:x=70:y=28,drawtext=fontfile='${FONT}':text='${subtitle}':fontcolor=0xb9bdc6:fontsize=31:x=70:y=99" \
    -frames:v 1 -update 1 "$DIR/$output"
}

make_en guide-01-main-overview-ko.png guide-01-main-overview-en.png \
  "HongMix 2.0.9 · Main Production View" \
  "Fictional presenter test source · No real people or broadcast footage used" 190

make_en guide-02-ai-background-removal-ko.png guide-02-ai-background-removal-en.png \
  "AI Person Key · Virtual Studio Composite" \
  "Original on left · Person segmentation + studio image on right (Fast · edge 0.55)" 190

make_en guide-03-live-captions-ko.png guide-03-live-captions-en.png \
  "Live AI Caption Settings" \
  "1 Language & translation · 2 Continuous recognition · 3 Glossary & corrections · 4 Caption style" 190

make_en guide-04-replay-window-ko.png guide-04-replay-window-en.png \
  "4-Channel Instant Replay" \
  "CAM assignment · A/B decks · Frame-accurate TC · Clip creation & playback" 190

make_en guide-05-replay-export-ko.png guide-05-replay-export-en.png \
  "Replay Clip Export" \
  "1 Landscape / vertical / square · 2 Normal / slow motion · 3 H.264 / HEVC / ProRes" 190
