# HongMix 1.3.22 (Build 37)

## Playback and CPU scheduling

- Bound FFmpeg `swscale` conversion to two workers per conversion context (one on a single-core
  system). Previously, every conversion context requested automatic per-CPU parallelism. Multiple
  simultaneous sources could therefore create competing conversion workers. This change aims to
  reduce that contention; the offline test did not quantify live UI/audio benefit. FFmpeg codec
  decoder threading remains automatic because reducing it materially slowed the sample-file decode
  test.
- Kept VideoToolbox hardware decoding and IOSurface/CoreVideo frame delivery as the preferred path.
  FFmpeg remains the fallback for codecs or formats VideoToolbox cannot decode. This release does
  not transcode or alter source media.
- No always-on playback was added for cued file inputs. They still start on Take, preserving the
  operator's requested behavior.

## License and dependency notes

- No new bundled decoder dependency was added. FFmpeg remains dynamically linked under LGPL v3,
  built without GPL/nonfree components. VideoToolbox, CoreVideo, and Metal are Apple system
  frameworks provided by macOS, not separately bundled open-source projects.
- Existing third-party notices remain applicable for FFmpeg dependencies, CEF, NDI runtime, and
  DeckLink SDK. NDI remains subject to its SDK agreement; HongMix is not wholly composed of free or
  open-source components.

## Measurement

On the supplied `ENG1_2606302238_2689.mp4` (1080p60) and `ENG_5_0003.mp4` (UHD 60000/1001), a
system Homebrew FFmpeg null-output decode plus BGRA scale run measured:

| File | swscale workers | Wall time |
| --- | ---: | ---: |
| ENG1 1080p60 | automatic | 3.21 s |
| ENG1 1080p60 | 2 | 3.14 s |
| ENG1 1080p60 | 4 | 3.33 s |
| ENG_5 UHD59.94 | automatic | 3.38 s |
| ENG_5 UHD59.94 | 2 | 3.29 s |
| ENG_5 UHD59.94 | 4 | 3.35 s |

These offline CLI measurements show no throughput regression at two workers for these two clips.
They do not prove live HongMix playback is glitch-free: the CLI used the Homebrew FFmpeg build,
not the app's linked LGPL build, and did not exercise UI, CoreAudio, transitions, or concurrent
capture inputs. Build/runtime verification is recorded with the delivered artifact.

## Supplied media inspection

- `ENG1_2606302238_2689.mp4` and `ENG2_2606172348_1438.mp4` report the same stream properties:
  H.264 Main, 1920×1080p60, about 45 Mb/s, plus AAC-LC stereo 48 kHz at about 128 kb/s. A full
  software decode of ENG1's video and audio streams exited successfully with no reported decode
  errors. That rules out obvious packet corruption, but does not prove clean real-time presentation.
- `ENG_5_0003.mp4` is H.264 Baseline, 3840×2160p59.94, about 80 Mb/s, AAC-LC stereo 44.1 kHz at
  192 kb/s. Its different audio sample rate requires resampling to HongMix's 48 kHz mixer rate;
  AAC-LC itself is supported by the bundled FFmpeg decoder.
