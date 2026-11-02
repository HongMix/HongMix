# HongMix 1.3.26 · Build 41

HongMix is a Mac live-production switcher for Preview/Program switching, media and live inputs, layered graphics, replay, audio mixing, and broadcast outputs. This release continues the v1.3.22–1.3.26 work on media timing, audio buffering, operator layout, and replay controls.

> **Release status:** the app build is prepared. The notes below describe code and UI changes; they are not a claim that every media source has passed a long live-broadcast test. See **Verification and limits** before using this build on air.

## Screenshots / 캡처

These screenshots were captured from the running HongMix 1.3.26 app. The media example uses the local `ENG_5_0003.mp4` test clip (2160p59.94); it is a UI illustration, and a single frame of statistics is not a playback-stability test.

| Screen | What it shows |
|---|---|
| [Media input and switcher](screenshots/1.3.26-media-demo.jpg) | Separate Preview and Program monitors, the loaded video input tile, overlay 1–8 controls, the folded input rail, and the audio mixer. |
| [Main switcher](screenshots/1.3.26-main-switcher.jpg) | Main Preview/Program layout and source grid. |
| [Audio mixer](screenshots/1.3.26-audio-mixer.jpg) | Mixer strips and live meter display at the moment of capture. A still image cannot prove uninterrupted audio. |
| [Replay window](screenshots/1.3.26-replay.jpg) | Replay deck controls and TC display layout. This capture shows the replay window idle, not an active recording or replay. |

현재 실행 중인 HongMix 1.3.26에서 캡처했습니다. 미디어 예시는 로컬 테스트 파일 `ENG_5_0003.mp4`(2160p59.94)를 사용한 UI 설명용 화면입니다. 통계 수치 한 장으로 재생 안정성을 입증하지는 않습니다.

| 화면 | 확인할 수 있는 내용 |
|---|---|
| [미디어 입력과 스위처](screenshots/1.3.26-media-demo.jpg) | Preview/Program 모니터 분리, 불러온 비디오 입력 타일, Overlay 1–8, 왼쪽 접힌 입력 레일, 오디오 믹서 |
| [메인 스위처](screenshots/1.3.26-main-switcher.jpg) | Preview/Program 배치와 입력 타일 |
| [오디오 믹서](screenshots/1.3.26-audio-mixer.jpg) | 캡처 순간의 믹서 채널과 미터. 정지 이미지는 끊김 없는 오디오의 증거가 아닙니다. |
| [리플레이 창](screenshots/1.3.26-replay.jpg) | 리플레이 덱 조작부와 TC 표시 배치. 이 캡처는 대기 상태이며 녹화/재생 중인 장면은 아닙니다. |

## What changed and what we did

### 1. Folded inputs now reclaim tile-grid space

**Problem:** collapsing a source left an empty tile-sized area, so folding did not meaningfully free space.

**Action:** folded cards are collected into a narrow vertical rail at the left of the input area. The rail preserves each source's original input number, name, and state. Select a row to load that source into Preview; use its arrow to restore the full tile. Drag reordering remains available. The separate compact-thumbnail mode remains separate from fold/unfold state.

**Screenshot:** [Media input and switcher](screenshots/1.3.26-media-demo.jpg) shows the folded rail beside expanded tiles. The expanded comparison state was not separately captured.

### 2. File audio now follows media presentation time

**Problem reported in [Issue #2](https://github.com/HongMix/HongMix/issues/2):** file audio could arrive in bursts and the mixer could discard excess queued samples, producing periodic gaps.

**Action:** file audio is scheduled against its own presentation timestamps (PTS) and fed with a bounded lead. The mixer uses a smaller priming cushion for file sources than for live/capture sources, keeps priming through a brief underrun, and records short-read/underrun diagnostics. Live sources retain a larger jitter cushion. This addresses the identified timing/buffering path; it does **not** prove that a particular ENG1 file or every codec/device route is now dropout-free.

**Screenshot:** [Audio mixer](screenshots/1.3.26-audio-mixer.jpg) shows the mixer UI only. Statistics counters during a controlled playback run were not captured, so this image does not establish that the reported audio issue is resolved.

### 3. Input-grid preview work is limited

**Problem:** many large source thumbnails can add avoidable scaling and refresh work while the operator is monitoring the main Preview/Program displays.

**Action:** input thumbnails are capped at 6 fps, and large-frame scaling is requested only for tiles visible in a window. Preview and Program continue to use source frames; this is a UI-thumbnail optimization, not a lower-resolution broadcast output or a proxy-media workflow.

**Screenshot:** [Media input and switcher](screenshots/1.3.26-media-demo.jpg) shows the input grid alongside full-size Preview/Program monitors.

### 4. Off-air audio-follow-video inputs do less mixer work

**Problem:** muted/off-air sources could still incur per-sample copy and DSP work even when they could not be heard.

**Action:** once an audio-follow-video source has faded fully off air, the mixer advances its PCM ring without copying samples or running per-sample DSP. The fade-to-zero block, transition pre-roll, and ISO recording keep their normal processing path so transitions and recordings are not skipped by this fast path.

**Screenshot:** [Audio mixer](screenshots/1.3.26-audio-mixer.jpg) shows Master, input strips, and meter activity. A collapsed-meter state is not shown.

### 5. Replay has timecode-led dual-deck controls

Replay provides independently controlled Deck A and Deck B, a timeline scrubber, frame/second jog, playback speed and reverse controls, IN/OUT marking, clip saving, and selected-channel take/live controls. The window shows the recording timecode, selected playback timecode, and Mac system time; recorded positions can be correlated with the system clock. The REC start time is also displayed.

**Screenshot:** [Replay window](screenshots/1.3.26-replay.jpg) documents the control and timecode layout while idle. REC/Selected/System TC values during active recording, deck position, and saved clip list were not captured.

### 6. Properties and operator controls are easier to reach

**Problem reported in [Issue #4](https://github.com/HongMix/HongMix/issues/4):** a fixed-width row of property tabs was wider than the window and clipped at both sides.

**Action:** input properties use a left-side section list and a wider sheet, avoiding the row of nine fixed-width tabs. Frequently used switching controls include a single Stinger selector and Overlay 1–8 buttons; each overlay channel recalls its assigned input independently of Preview. Less frequently used utilities are grouped under the Tools menu to reduce toolbar crowding.

**Screenshot:** [Media input and switcher](screenshots/1.3.26-media-demo.jpg) shows Stinger/Overlay 1–8 and the folded input rail. The properties navigation and expanded Tools menu were not captured in this pass.

### 7. Output routing and the media workflow

CoreAudio output routes can be assigned to Master/buses and headphone monitoring, with device and channel choices exposed by the output settings. This is a routing capability; attached-device, channel-map, and end-to-end monitoring behavior still need verification on the target Mac and hardware.

A Video input is for a single media file. A List input groups multiple files and shows the list/current item on its source tile. Files remain cued until taken to Program under the current media playback behavior; adding a file is not intended to start every media source in the background.

Dedicated screenshots of CoreAudio device/channel assignment and the List input's current item/order were not captured in this pass.

## Performance approach and dependencies

- Keep VideoToolbox hardware decoding and the CoreVideo/IOSurface-to-Metal path where supported; use the existing FFmpeg fallback for other supported media paths.
- Limit FFmpeg `swscale` conversion workers to two per conversion context (one on a single-core system) to avoid each simultaneous source creating a large automatic worker pool. Codec decoder threading remains automatic.
- No always-on decoding was added for cued media files, and source files are not transcoded or modified.
- No new decoder package was introduced in these changes. FFmpeg is dynamically linked as LGPL v3 without GPL/nonfree components; Apple media frameworks are supplied by macOS. Existing CEF, NDI runtime/SDK, and DeckLink SDK notices and terms still apply. HongMix is not wholly made of free/open-source components.

## Verification and limits

- HongMix 1.3.26 Build 41 app and installer artifacts were built. A successful build establishes compilation and packaging only.
- Offline Homebrew FFmpeg decode/scale measurements for the supplied ENG1 1080p60 and ENG_5 UHD clips showed no throughput regression at two `swscale` workers versus automatic worker count. These were CLI measurements using Homebrew FFmpeg, not HongMix's linked FFmpeg in a live session.
- ENG1 and ENG2 were inspected as H.264 Main 1920×1080p60 with AAC-LC stereo 48 kHz; a full software decode completed without reported decode errors. That does not prove real-time presentation is clean.
- No controlled long-duration test has established glitch-free playback across the ENG1 clip, all codec/sample-rate combinations, CoreAudio devices, transitions, concurrent capture inputs, or lower-spec Apple Silicon Macs. Confirm frame and audio stability on the actual show setup before broadcast.
- The screenshots above document visible UI only. Dedicated active replay, audio-underrun diagnostics, CoreAudio route, List input, properties-navigation, and Tools-menu screenshots remain outstanding; the still images do not certify long-duration playback or broadcast reliability.

## Acknowledgments

Special thanks to **Seokhyuun (@seokhyuun)** for the detailed reports and code-level analysis in [Issues #1–#4](https://github.com/HongMix/HongMix/issues). The reports were a great help in identifying concrete playback, audio-routing, and properties-window issues to investigate and improve. Thank you for taking the time to document them so carefully.

---

## 한국어

HongMix는 Preview/Program 전환, 미디어·라이브 입력, 레이어 그래픽, 리플레이, 오디오 믹싱, 방송 출력을 위한 Mac용 라이브 프로덕션 스위처입니다. 이번 버전은 v1.3.22–1.3.26에서 미디어 시간 동기화, 오디오 버퍼링, 입력 배치, 리플레이 조작을 다듬었습니다.

> **릴리스 상태:** 앱 빌드는 준비됐습니다. 아래 설명은 코드와 UI에 반영된 변경 사항이며, 모든 미디어와 장치 조합이 장시간 방송 테스트를 통과했다는 뜻은 아닙니다. 방송 전 실제 장비로 확인해 주세요.

## 변경 사항과 조치

### 1. 입력을 접으면 왼쪽 세로 레일로 이동

**문제:** 소스를 접어도 카드 크기의 빈 공간이 남아 타일 영역을 충분히 확보하지 못했습니다.

**조치:** 접힌 입력을 입력 영역 왼쪽의 좁은 세로 레일로 모읍니다. 기존 입력 번호와 이름, 상태를 유지하고, 항목을 누르면 Preview 소스로 선택됩니다. 화살표로 원래 타일을 펼칠 수 있으며 드래그 순서 변경도 유지됩니다. 컴팩트 타일 설정은 접기/펼치기 상태와 별도로 동작합니다.

**캡처:** [미디어 입력과 스위처](screenshots/1.3.26-media-demo.jpg)에서 접힌 레일과 펼쳐진 타일을 확인할 수 있습니다. 같은 입력을 전체 펼친 비교 화면은 별도로 캡처하지 않았습니다.

### 2. 파일 오디오를 미디어 재생 시각에 맞춰 공급

**Issue #2 제보:** 파일 오디오가 덩어리로 들어오고 믹서가 쌓인 샘플을 버려 일정한 간격으로 소리가 끊길 수 있다는 상세 분석이 있었습니다.

**조치:** 파일 오디오를 자체 PTS(미디어 표시 시각)에 맞춰 예약하고 제한된 선행 버퍼로 공급합니다. 파일 입력은 라이브·캡처 입력보다 짧은 초기 버퍼 기준을 사용하고, 짧은 언더런 뒤에도 초기화 상태를 유지하며, 짧은 읽기와 언더런 진단값을 기록합니다. 라이브 입력은 장치 지터를 위한 더 큰 버퍼 기준을 유지합니다. 이는 확인된 시간 동기화·버퍼 경로를 개선한 것이며, 특정 ENG1 파일이나 모든 코덱·장치에서 끊김이 해결됐다고 단정하지 않습니다.

**캡처:** [오디오 믹서](screenshots/1.3.26-audio-mixer.jpg)는 믹서 UI만 보여줍니다. 통제된 재생 중 Statistics의 오디오 버퍼/언더런 수치는 캡처하지 않았으므로, 이 화면만으로 오디오 문제가 해결됐다고 판단하지 않습니다.

### 3. 입력 타일 프리뷰 작업량 제한

**문제:** 큰 소스가 많은 환경에서 입력 썸네일의 스케일 변환과 갱신이 메인 Preview/Program 감시에 불필요한 작업을 더할 수 있습니다.

**조치:** 입력 썸네일 갱신을 초당 6회로 제한하고, 창에 보이는 타일에 대해서만 큰 프레임 스케일 변환을 요청합니다. Preview와 Program은 원본 소스 프레임을 계속 사용합니다. 이는 입력 썸네일 최적화이며, 송출 해상도를 낮추거나 프록시 영상을 만드는 기능은 아닙니다.

**캡처:** [미디어 입력과 스위처](screenshots/1.3.26-media-demo.jpg)에서 입력 타일과 별도 Preview/Program 모니터를 함께 볼 수 있습니다.

### 4. 온에어가 아닌 AFV 입력의 믹서 처리량 절감

**문제:** 들리지 않는 오프에어 소스도 샘플 복사와 DSP 처리를 계속할 수 있었습니다.

**조치:** 오디오 팔로우 비디오 입력의 페이드가 완전히 0이 되면 PCM 링을 진행시키되 샘플 복사와 샘플별 DSP를 건너뜁니다. 페이드가 0으로 내려가는 첫 블록, 전환 프리롤, ISO 녹화는 기존 정상 처리 경로를 유지합니다.

**캡처:** [오디오 믹서](screenshots/1.3.26-audio-mixer.jpg)에서 Master, 입력 스트립, 캡처 순간의 미터를 볼 수 있습니다. 미터 접힘 상태는 포함하지 않았습니다.

### 5. 타임코드 중심의 2덱 리플레이

Deck A와 Deck B를 독립 제어하고, 타임라인 스크럽, 프레임/초 단위 이동, 재생 속도·역재생, IN/OUT 마킹, 클립 저장, 선택 채널 온에어/라이브 제어를 제공합니다. 녹화 타임코드, 선택 재생 타임코드, Mac 시스템 시각을 함께 표시해 녹화 위치를 시스템 시각과 대조할 수 있습니다. REC 시작 시각도 표시합니다.

**캡처:** [리플레이 창](screenshots/1.3.26-replay.jpg)은 대기 상태의 조작부와 타임코드 배치를 보여줍니다. 실제 녹화 중 REC/Selected/System TC 값, 덱 위치, 저장 클립 목록은 캡처하지 않았습니다.

### 6. 속성 창과 조작 도구 배치 개선

**Issue #4 제보:** 고정 폭 탭 9개가 속성 창보다 넓어 양쪽 내용이 잘렸습니다.

**조치:** 입력 속성 창을 왼쪽 항목 탐색 방식과 넓은 창으로 바꿔 고정 폭 탭 줄에서 생기던 잘림을 피했습니다. 전환 영역에는 Stinger 선택 하나와 Overlay 1–8 버튼을 두고, 각 오버레이 채널은 Preview와 별개로 지정된 입력을 기억합니다. 자주 쓰지 않는 도구는 Tools 메뉴에 모아 하단 도구 모음의 혼잡을 줄였습니다.

**캡처:** [미디어 입력과 스위처](screenshots/1.3.26-media-demo.jpg)에서 Stinger/Overlay 1–8과 접힌 입력 레일을 볼 수 있습니다. 속성 탐색 및 Tools 메뉴를 펼친 화면은 이번 캡처에 포함되지 않았습니다.

### 7. 오디오 출력 경로와 미디어 입력 방식

CoreAudio 출력 장치를 Master/버스 및 헤드폰 모니터 경로에 지정하고 채널을 선택할 수 있습니다. 이는 라우팅 기능이며, 실제 장치·채널 매핑·모니터링은 대상 Mac과 연결 장비에서 확인해야 합니다.

Video 입력은 단일 미디어 파일을 대상으로 합니다. 여러 파일을 순서대로 묶으려면 List 입력을 사용하며, 입력 타일에 리스트와 현재 항목이 표시됩니다. 미디어 파일은 현재 동작에서 온에어 전 큐 상태로 준비되며, 추가만으로 모든 파일 입력이 백그라운드 재생되지는 않습니다.

CoreAudio 장치/채널 지정과 List 입력의 현재 항목/순서를 보여주는 전용 캡처는 이번 작업에서 추가하지 않았습니다.

## 최적화 방향과 라이선스

- 지원되는 경로에서는 VideoToolbox 하드웨어 디코딩과 CoreVideo/IOSurface-to-Metal 전달 경로를 유지하고, 다른 지원 미디어 경로에는 기존 FFmpeg 폴백을 사용합니다.
- 여러 소스가 각각 CPU 수만큼 변환 작업자를 만들며 경쟁하지 않도록 FFmpeg `swscale` 변환 컨텍스트당 작업자를 최대 2개로 제한했습니다(단일 코어에서는 1개). 코덱 디코더 작업자 설정은 자동으로 둡니다.
- 큐 상태의 파일을 계속 디코딩하는 기능은 추가하지 않았으며 원본 파일을 트랜스코딩하거나 수정하지 않습니다.
- 새 디코더 패키지는 추가되지 않았습니다. FFmpeg는 GPL/nonfree 구성요소 없이 LGPL v3 동적 링크로 사용합니다. Apple 미디어 프레임워크는 macOS에 포함됩니다. 기존 CEF, NDI 런타임/SDK, DeckLink SDK의 고지와 약관은 계속 적용됩니다. HongMix 전체가 무료 오픈소스 구성요소로만 이루어진 것은 아닙니다.

## 검증 범위와 한계

- HongMix 1.3.26 Build 41 앱과 설치 파일 빌드를 완료했습니다. 빌드 성공은 컴파일·패키징 확인이며, 생방송 안정성 인증은 아닙니다.
- 제공된 ENG1 1080p60 및 ENG_5 UHD 파일로 Homebrew FFmpeg CLI 디코드/스케일 측정을 했을 때 `swscale` 작업자 2개는 자동 설정 대비 처리량 저하가 없었습니다. 이는 HongMix에 링크된 FFmpeg로 실제 재생한 결과가 아닙니다.
- ENG1과 ENG2는 H.264 Main 1920×1080p60 및 AAC-LC 스테레오 48kHz로 확인했고, 전체 소프트웨어 디코드에서 보고된 오류는 없었습니다. 이것만으로 실시간 표시가 매끄럽다고 증명되지는 않습니다.
- ENG1 장시간 재생, 모든 코덱/샘플레이트, CoreAudio 장치, 전환, 동시 캡처, 저사양 Apple Silicon에서 무끊김을 입증하는 통제된 장시간 테스트는 아직 완료되지 않았습니다. 실제 방송 전에 사용하는 맥과 장비에서 영상 프레임과 오디오를 확인해 주세요.
- 위 캡처는 UI 상태를 설명하기 위한 자료입니다. 활성 리플레이, 오디오 언더런 진단, CoreAudio 경로, List 입력, 속성 탐색, Tools 메뉴의 전용 캡처는 아직 없으며, 정지 이미지는 장시간 재생이나 방송 안정성을 인증하지 않습니다.

## 감사 인사

[Issue #1–#4](https://github.com/HongMix/HongMix/issues)에 재현 절차와 코드 수준 분석을 자세히 남겨주신 **Seokhyuun (@seokhyuun)**께 특별히 감사드립니다. 제보 덕분에 재생·오디오 라우팅·속성 창에서 구체적으로 확인하고 개선할 지점을 찾는 데 큰 도움이 되었습니다. 세심하게 정리해 주셔서 감사합니다.
