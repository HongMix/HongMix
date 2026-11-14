#!/bin/bash
# HongMix test media: synthetic only (test patterns, color bars, sine tones) — no people, footage or
# copyrighted material, safe to use in public screenshots. Covers the codecs, sizes, frame rates, scan
# types, alpha and audio layouts the stability / compatibility tests feed into HongMix.
#
#   bash scripts/make-test-media.sh <output folder> [seconds]     (default 20 s per clip)
#
# Needs ffmpeg with libx264, libx265, prores_ks, libvpx-vp9, libopus, libsvtav1, mpeg2video, mp2, ac3,
# libmp3lame. Clips loop seamlessly enough for long soak tests (Loop on in HongMix).
set -euo pipefail
OUT="${1:?usage: make-test-media.sh <output folder> [seconds]}"
D="${2:-20}"
mkdir -p "$OUT"
cd "$OUT"
F="ffmpeg -v error -y"
tone() { echo "sine=frequency=$1:sample_rate=$2:duration=$D"; }   # freq, rate

echo "== video"
# 1 H.264 1080p29.97 stereo AAC 48k — the everyday camera / file case
$F -f lavfi -i "testsrc2=s=1920x1080:r=30000/1001:d=$D" -f lavfi -i "$(tone 1000 48000)" -f lavfi -i "$(tone 1500 48000)" \
   -filter_complex "[1][2]amerge=inputs=2[a]" -map 0:v -map "[a]" -c:v libx264 -preset veryfast -pix_fmt yuv420p -g 60 -c:a aac -b:a 192k \
   01_h264_1080p2997_stereo48k.mp4
# 2 H.264 720p59.94
$F -f lavfi -i "testsrc2=s=1280x720:r=60000/1001:d=$D" -f lavfi -i "$(tone 800 48000)" \
   -c:v libx264 -preset veryfast -pix_fmt yuv420p -c:a aac -ac 2 02_h264_720p5994.mp4
# 3 H.264 640x360 25p, mono AAC 44.1k — low-res input (AI upscaling ×2), odd audio rate
$F -f lavfi -i "testsrc2=s=640x360:r=25:d=$D" -f lavfi -i "$(tone 440 44100)" \
   -c:v libx264 -preset veryfast -pix_fmt yuv420p -c:a aac -ac 1 03_h264_360p25_mono44k.mp4
# 4 H.264 1080p50 (PAL-rate HD)
$F -f lavfi -i "smptehdbars=s=1920x1080:r=50:d=$D" -f lavfi -i "$(tone 1000 48000)" \
   -c:v libx264 -preset veryfast -pix_fmt yuv420p -c:a aac -ac 2 04_h264_1080p50_bars.mp4
# 5 HEVC 2160p30 8-bit (4K → downscaled to the output)
$F -f lavfi -i "testsrc2=s=3840x2160:r=30:d=$D" -f lavfi -i "$(tone 1000 48000)" \
   -c:v libx265 -preset ultrafast -tag:v hvc1 -pix_fmt yuv420p -x265-params log-level=error -c:a aac -ac 2 05_hevc_2160p30.mp4
# 6 HEVC 1080p 10-bit Main10 (iPhone / mirrorless HDR-less 10-bit)
$F -f lavfi -i "testsrc2=s=1920x1080:r=30:d=$D" -c:v libx265 -preset ultrafast -tag:v hvc1 -pix_fmt yuv420p10le \
   -x265-params log-level=error 06_hevc_1080p30_10bit_noaudio.mp4
# 7 ProRes 422 HQ 1080p23.976, PCM 24-bit 48k (edit-suite file)
$F -f lavfi -i "testsrc2=s=1920x1080:r=24000/1001:d=$D" -f lavfi -i "$(tone 1000 48000)" \
   -c:v prores_ks -profile:v 3 -pix_fmt yuv422p10le -c:a pcm_s24le -ac 2 07_prores422hq_1080p2398_pcm24.mov
# 8 ProRes 4444 with alpha: lower-third graphic on a transparent 1920x1080 canvas (Trim Transparent Background)
$F -f lavfi -i "color=c=0x1D9E75@1:s=720x180:r=30:d=$D,format=rgba" -f lavfi -i "color=c=black@0:s=1920x1080:r=30:d=$D,format=rgba" \
   -filter_complex "[1][0]overlay=x=120:y=820:format=auto,drawtext=text='LOWER THIRD':x=160:y=880:fontsize=64:fontcolor=white,format=yuva444p10le" \
   -c:v prores_ks -profile:v 4 -alpha_bits 16 08_prores4444_alpha_lowerthird.mov
# 9 VP9 1080p30 + Opus in WebM (browser / screen-recording style)
$F -f lavfi -i "testsrc2=s=1920x1080:r=30:d=$D" -f lavfi -i "$(tone 600 48000)" \
   -c:v libvpx-vp9 -deadline realtime -cpu-used 8 -b:v 4M -c:a libopus -ac 2 09_vp9_1080p30_opus.webm
# 10 MPEG-2 PAL 576i25 interlaced (top field first) + MP2 (old DVD / broadcast file → deinterlace path)
$F -f lavfi -i "testsrc2=s=720x576:r=50:d=$D" -f lavfi -i "$(tone 1000 48000)" \
   -vf "interlace=scan=tff,setfield=tff" -c:v mpeg2video -b:v 8M -flags +ilme+ildct -c:a mp2 -ac 2 10_mpeg2_576i25_tff.mpg
# 11 H.264 720x480 29.97i NTSC SD interlaced
$F -f lavfi -i "testsrc2=s=720x480:r=60000/1001:d=$D" -f lavfi -i "$(tone 1000 48000)" \
   -vf "interlace=scan=tff" -c:v libx264 -preset veryfast -flags +ilme+ildct -x264-params tff=1 -pix_fmt yuv420p -c:a aac -ac 2 11_h264_480i2997_tff.mp4
# 12 Vertical phone video 1080x1920 30p
$F -f lavfi -i "testsrc2=s=1080x1920:r=30:d=$D" -f lavfi -i "$(tone 900 48000)" \
   -c:v libx264 -preset veryfast -pix_fmt yuv420p -c:a aac -ac 2 12_h264_vertical_1080x1920.mp4
# 13 AV1 1080p30 (newer screen recordings / downloads)
$F -f lavfi -i "testsrc2=s=1920x1080:r=30:d=$D" -c:v libsvtav1 -preset 12 -svtav1-params log-level=0 -pix_fmt yuv420p 13_av1_1080p30_noaudio.mp4
# 14 H.264 1080p30 with AC-3 5.1 audio (6 channels → stereo mix)
$F -f lavfi -i "testsrc2=s=1920x1080:r=30:d=$D" -f lavfi -i "$(tone 1000 48000)" \
   -filter_complex "[1]pan=5.1|FL=c0|FR=c0|FC=c0|LFE=c0|BL=c0|BR=c0[a]" -map 0:v -map "[a]" \
   -c:v libx264 -preset veryfast -pix_fmt yuv420p -c:a ac3 -b:a 384k 14_h264_1080p30_ac3_51.mkv
# 15 Short clip (2 s) — end / loop / auto-next handling
$F -f lavfi -i "smptebars=s=1280x720:r=30:d=2" -f lavfi -i "sine=frequency=1000:sample_rate=48000:duration=2" \
   -c:v libx264 -preset veryfast -pix_fmt yuv420p -c:a aac -ac 2 15_h264_720p30_2s_short.mp4

echo "== audio only"
$F -f lavfi -i "$(tone 1000 48000)" -c:a pcm_s16le -ac 2 20_tone_1k_48k_stereo.wav
$F -f lavfi -i "$(tone 440 44100)" -c:a libmp3lame -b:a 192k -ac 2 21_tone_440_44k_stereo.mp3
$F -f lavfi -i "$(tone 250 48000)" -c:a aac -b:a 160k -ac 2 22_tone_250_48k_stereo.m4a

echo "== images"
$F -f lavfi -i "testsrc2=s=1920x1080" -frames:v 1 30_png_1080p_opaque.png
$F -f lavfi -i "color=c=0x534AB7:s=640x200,format=rgba" -f lavfi -i "color=c=black@0:s=1920x1080,format=rgba" \
   -filter_complex "[1][0]overlay=x=1180:y=80:format=auto,format=rgba" -frames:v 1 31_png_alpha_corner_logo.png
$F -f lavfi -i "testsrc2=s=4032x3024" -frames:v 1 -q:v 3 32_jpg_4032x3024_large.jpg
$F -f lavfi -i "testsrc2=s=480x270:r=15:d=4" -vf "split[a][b];[a]palettegen[p];[b][p]paletteuse" 33_gif_animated_480x270.gif

echo "done → $OUT"
ls -la "$OUT"
