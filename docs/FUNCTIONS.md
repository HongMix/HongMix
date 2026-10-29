# BraceletMix 제어 함수 설명서

BraceletMix는 HTTP(`http://<IP>:8088/api/?Function=이름&Input=…&Value=…`)와 TCP 8099(`FUNCTION 이름 Input=…&Value=…`)로 제어합니다. 함수 이름과 파라미터 이름(Input, Value, Duration, SelectedName, SelectedIndex)은 vMix 공개 Web/TCP API와 같게 맞췄기 때문에, 기존 Companion·Stream Deck 버튼과 스크립트를 IP만 바꿔서 쓸 수 있습니다. 이 문서는 BraceletMix 동작을 기준으로 새로 작성했습니다.

**공통 규칙**

- `Input`에는 입력 번호(1부터), 입력 이름, 또는 key(UUID)를 넣을 수 있습니다.
- 성공하면 HTTP는 `Function completed successfully.`, TCP는 `FUNCTION OK 이름`을 돌려줍니다.
- 실패하면 HTTP는 500, TCP는 `FUNCTION ER 메시지`를 돌려줍니다.
- 일부러 구현하지 않은 함수는 `Not supported in BraceletMix: 이름`으로 응답합니다.

## 커버리지 (vMix 공개 함수 레퍼런스 기준, Replay·PTZ 등 제외 범주 빼고)

| 범주 | 구현 | 전체 |
|---|---|---|
| Transition | 20 | 20 |
| Output | 30 | 31 |
| Overlay | 25 | 34 |
| Audio | 48 | 70 |
| Title | 24 | 24 |
| Input | 54 | 98 |
| NDI | 2 | 5 |
| Browser | 8 | 8 |
| **합계** | **211** | **290** |

제외한 범주(맥 포팅 범위에서 뺌): Replay (~175), PTZ (22), PlayList (5), DataSources (9), Scripting (5), Preset (3)

## 전환 (Transition)

| 함수 | 파라미터 | 동작 |
|---|---|---|
| `Cut` | [Input] | Preview를 Output으로 바로 전환합니다. Input을 주면 그 입력을 먼저 Preview에 올립니다. |
| `Fade / Merge / Wipe / Slide / Fly / CrossZoom / Zoom` | [Input] [Duration=ms] | 해당 효과로 Preview를 Output으로 전환합니다. |
| `QuickPlay` | Input | 입력을 Preview에 올린 뒤 1번 전환으로 바로 Output에 보냅니다. |
| `CutDirect / ActiveInput` | Input | Preview는 그대로 두고 입력을 바로 Output으로 보냅니다. |
| `Transition1~4` | [Input] | 전환 버튼 1~4를 실행합니다. |
| `SetTransitionEffect1~4` | Value=효과 이름 | 전환 버튼의 효과를 바꿉니다 (Fade, Merge, Wipe, Slide, Fly, CrossZoom, Zoom, FadeToBlack). |
| `SetTransitionDuration1~4` | Value=ms | 전환 버튼의 시간을 바꿉니다. |
| `Stinger1~4` | [Input] | 지정한 미디어 입력을 위에 재생하면서 컷 지점에서 전환합니다. 화면의 Stinger ▾ 메뉴에서 입력과 컷 지점을 정합니다. |
| `SetFader` | Value=0~255 | T-바 위치입니다. 255에 닿으면 전환이 완료됩니다. |
| `FadeToBlack` |  | 블랙 페이드를 켜고 끕니다. 오디오도 함께 페이드합니다. |
| `PreviewInput / PreviewInputNext / PreviewInputPrevious` | Input | Preview를 선택합니다. |

## 오버레이 (Overlay)

| 함수 | 파라미터 | 동작 |
|---|---|---|
| `OverlayInput1~4` | Input | 오버레이 채널을 토글합니다 (페이드 0.5초). |
| `OverlayInput1~4In / Out` | Input | 오버레이를 넣거나 뺍니다 (페이드). |
| `OverlayInput1~4Off` |  | 페이드 없이 즉시 뺍니다. |
| `OverlayInput1~4Last` |  | 마지막 입력을 다시 올립니다. |
| `OverlayInput1~4Zoom` | Input | 토글과 같습니다 (줌 애니메이션은 없습니다). |
| `OverlayInputAllOff` |  | 모든 오버레이를 뺍니다. |

## 출력 (Output)

| 함수 | 파라미터 | 동작 |
|---|---|---|
| `StartStreaming / StopStreaming / StartStopStreaming` | [Value=n] | 스트림 출력을 켜고 끕니다. |
| `StartSRTOutput / StopSRTOutput / StartStopSRTOutput` | [Value=Output 번호] | SRT 프로토콜 스트림 출력만 켜고 끕니다. |
| `StreamingSetURL / StreamingSetKey / StreamingSetUsername / StreamingSetPassword` | Value=텍스트 또는 "인덱스,텍스트" | 스트림 대상을 바꿉니다. srt://로 시작하면 SRT URL로 설정됩니다. |
| `StartRecording / StopRecording / StartStopRecording` |  | 녹화 출력을 켜고 끕니다. |
| `StartExternal / StopExternal / StartStopExternal` |  | NDI와 DeckLink 출력을 함께 켜고 끕니다. |
| `StartMultiCorder / StopMultiCorder / StartStopMultiCorder` |  | 입력별 ISO 녹화를 켜고 끕니다. 입력 속성에서 'MultiCorder' 체크가 필요합니다. |
| `SetOutput2 / 3 / 4` | Value=Output|Clean|Preview|MultiView|Input [+Input] | Output 2~4의 소스를 정합니다. |
| `SetOutputFullscreen / SetOutputFullscreen2` | Value=Output|Output2|Output3|Output4 | 풀스크린 출력에 보낼 Output을 정합니다. |
| `SetOutputExternal2` | Value=Output|Output2… | 두 번째 NDI/DeckLink 출력의 소스를 정합니다. |
| `Fullscreen / FullscreenOn / FullscreenOff` |  | 보조 모니터 풀스크린 출력을 켜고 끕니다. |
| `Snapshot` | [Value=파일 경로] | Output을 PNG로 저장합니다 (기본 위치 ~/Pictures/BraceletMix). |
| `SnapshotInput` | Input [Value=경로] | 입력 화면을 PNG로 저장합니다. |

## 입력 (Input)

| 함수 | 파라미터 | 동작 |
|---|---|---|
| `Play / Pause / PlayPause / Restart` | Input | 미디어를 제어합니다. |
| `Loop / LoopOn / LoopOff` | Input | 반복 재생을 설정합니다. |
| `SetPosition` | Input, Value=ms | 재생 위치로 이동합니다. |
| `SetRate / SetRateSlowMotion` | Input, Value=0.05~4 | 재생 속도를 바꿉니다. 1이 아니면 오디오는 음소거됩니다. |
| `MarkIn / MarkOut / MarkReset / MarkResetIn / MarkResetOut` | Input | 현재 위치를 구간 시작·끝으로 지정하거나 해제합니다. 반복 재생은 이 구간 안에서 돕니다. |
| `AutoPlayOn/Off, AutoPauseOn/Off, AutoRestartOn/Off` | Input | Output에 들어가거나 빠질 때의 자동 동작을 정합니다. |
| `AddInput` | Value=Type|경로 | 입력을 추가합니다. Type은 Video, Image, Colour, NDI, Stream, Title, Browser, DesktopCapture, Audio 중 하나입니다 (예: Title|lowerThird, Browser|https://…). |
| `RemoveInput / MoveInput / SetInputName` | Input [Value] | 입력을 삭제하거나, 순서를 옮기거나, 이름을 바꿉니다. |
| `SetZoom / SetPanX / SetPanY` | Input, Value | 위치를 바꿉니다. 줌은 0.01~5, 팬은 -2~2입니다. |
| `SetCropX1 / X2 / Y1 / Y2, SetCrop` | Input, Value=0~1 (SetCrop: X1,Y1,X2,Y2) | 크롭합니다. |
| `SetAlpha` | Input, Value=0~255 | 불투명도를 바꿉니다. |
| `MirrorOn/Off, DeinterlaceOn/Off, SharpenOn/Off` | Input | 영상 처리를 켜고 끕니다. |
| `SetCCGainR/G/B/RGB, SetCCGammaR/G/B/RGB, SetCCLiftR/G/B/RGB` | Input, Value | 색보정입니다. 범위: Gain 0~4, Gamma 0.1~4, Lift -1~1. |
| `SetCCSaturation / SetCCHue` | Input, Value | 채도(0~3, 1=원본)와 색상(-180~180°)을 바꿉니다. |
| `ColourCorrectionReset / ResetInput` | Input | 색보정 또는 모든 영상 설정을 초기화합니다. |
| `NDISelectSourceByName / NDISelectSourceByIndex` | Input, Value | NDI 입력의 소스를 바꿉니다. |

## 타이틀 (GT)

| 함수 | 파라미터 | 동작 |
|---|---|---|
| `SetText` | Input, SelectedName 또는 SelectedIndex, Value | 텍스트를 바꿉니다. 필드 이름 예시: Headline.Text, Description.Text, TeamA.Text. |
| `SetTextColour` | Input, SelectedName, Value=#RRGGBB 또는 색 이름 | 텍스트 색을 바꿉니다. |
| `SetTextVisible / On / Off` | Input, SelectedName | 텍스트를 보이거나 숨깁니다. |
| `SetImage` | Input, SelectedName, Value=파일 경로 또는 URL | 이미지를 바꿉니다. |
| `SetImageVisible / On / Off` | Input, SelectedName | 이미지를 보이거나 숨깁니다. |
| `SetColor` | Input, SelectedName(기본 Background.Fill), Value | 도형 색을 바꿉니다. |
| `SetCountdown` | Input, Value=mm:ss 또는 hh:mm:ss | 카운트다운 시간을 설정합니다. |
| `StartCountdown / StopCountdown / PauseCountdown / SuspendCountdown` | Input | 카운트다운을 시작, 정지(리셋), 일시정지 토글, 일시정지합니다. |
| `AdjustCountdown / ChangeCountdown` | Input, Value=초 / 시간 | 카운트다운에 시간을 더하거나 빼고, 남은 시간을 바꿉니다. |
| `SetTickerSpeed` | Input, Value | 티커 속도를 바꿉니다. |
| `PauseRender / ResumeRender` | Input | 타이틀 갱신을 멈추거나 다시 시작합니다. |
| `SelectTitlePreset / NextTitlePreset / PreviousTitlePreset` | Input [Value=인덱스] | 저장한 텍스트 프리셋을 적용합니다. |
| `TitleBeginAnimation` | Input, Value=TransitionIn|TransitionOut | 인/아웃 애니메이션을 재생합니다. |

## 오디오 (Audio)

| 함수 | 파라미터 | 동작 |
|---|---|---|
| `Audio / AudioOn / AudioOff` | Input | 입력 음소거를 바꿉니다. |
| `AudioAuto / AudioAutoOn / AudioAutoOff` | Input | Audio Auto(오디오가 비디오를 따라감)를 설정합니다. |
| `AudioBus / AudioBusOn / AudioBusOff` | Input, Value=M,A,B… | 입력의 버스 라우팅을 바꿉니다. |
| `SetVolume / SetVolumeFade` | Input, Value=0~100 / "볼륨,ms" | 입력 볼륨을 바꿉니다. SetVolumeFade는 지정한 시간 동안 페이드합니다. |
| `SetVolumeChannel1/2, SetGain, SetGainChannel1/2, SetBalance` | Input, Value | 채널 볼륨, 게인(0~24dB), 밸런스(-1~1)를 바꿉니다. |
| `Solo / SoloOn / SoloOff` | Input | 헤드폰 Solo를 켜고 끕니다. |
| `BusAAudio, BusBAudio (+On/Off), BusXAudio (+On/Off)` | Value=A~G (BusX의 경우) | 버스 음소거를 바꿉니다. |
| `BusXSendToMaster (+On/Off), BusXSolo (+On/Off)` | Value=A~G | 버스를 Master로 보내거나 Solo로 돌립니다. |
| `SetBusAVolume ~ SetBusGVolume` | Value=0~100 | 버스 볼륨을 바꿉니다. |
| `SetMasterVolume, MasterAudio (+On/Off), SetHeadphonesVolume` | Value | 마스터 볼륨·음소거와 헤드폰 볼륨을 바꿉니다. |
| `AudioMixerShowHide` |  | 오디오 믹서 패널을 보이거나 숨깁니다. |

## 웹 브라우저 (Browser)

| 함수 | 파라미터 | 동작 |
|---|---|---|
| `BrowserNavigate` | Input, Value=URL | 페이지를 엽니다. |
| `BrowserReload / BrowserBack / BrowserForward` | Input | 새로고침, 뒤로, 앞으로. |
| `BrowserKeyboardEnabled/Disabled, BrowserMouseEnabled/Disabled` | Input | 호환용입니다. 페이지 조작은 입력 메뉴의 '브라우저 창 열기'에서 합니다. |

## TCP 8099 명령

| 명령 | 응답 |
|---|---|
| `FUNCTION 이름 쿼리` | `FUNCTION OK 이름` / `FUNCTION ER 메시지` |
| `XML` | `XML <바이트 수>` 다음에 XML 본문 |
| `XMLTEXT vmix/inputs/input[1]/@title` | `XMLTEXT OK 값` |
| `TALLY` | `TALLY OK 0121…` (입력마다 한 자리: 0 꺼짐, 1 Output, 2 Preview) |
| `SUBSCRIBE TALLY` / `SUBSCRIBE ACTS` | 변경이 생길 때마다 TALLY 또는 ACTS 줄을 보냄 |
| `ACTS Input 1` | `ACTS OK Input 1 1` |
| `QUIT` | 연결 종료 |

## 아직 구현하지 않은 함수 (범주별)

- **Output**: WriteDurationToRecordingLog
- **Overlay**: MoveMultiViewOverlay, MultiViewOverlay, MultiViewOverlayOff, MultiViewOverlayOn, PreviewOverlayInput1, PreviewOverlayInput2, PreviewOverlayInput3, PreviewOverlayInput4, SetMultiViewOverlay
- **Audio**: AudioChannelMatrixApplyPreset, AudioPluginOff, AudioPluginOn, AudioPluginOnOff, AudioPluginShow, BusAAudioPluginOff, BusAAudioPluginOn, BusAAudioPluginOnOff, BusAAudioPluginShow, BusBAudioPluginOff, BusBAudioPluginOn, BusBAudioPluginOnOff, BusBAudioPluginShow, BusXAudioPluginOff, BusXAudioPluginOn, BusXAudioPluginOnOff, BusXAudioPluginShow, MasterAudioPluginOff, MasterAudioPluginOn, MasterAudioPluginOnOff, MasterAudioPluginShow, SetVolumeChannelMixer
- **Input**: AutoPlayFirst, AutoPlayFirstOff, AutoPlayFirstOn, AutoPlayNext, AutoPlayNextOff, AutoPlayNextOn, ColourCorrectionAuto, CreateVirtualInput, InputPreviewHide, InputPreviewShow, InputPreviewShowHide, LayerOff, LayerOn, LayerOnOff, ListAdd, ListExport, ListPlayOut, ListRemove, ListRemoveAll, ListShowHide, ListShuffle, LivePlayPause, MoveLayer, NextItem, NextPicture, PreviousItem, PreviousPicture, SaveVideoDelay, SelectCategory, SelectIndex, SetDynamicInput1, SetDynamicInput2, SetDynamicInput3, SetDynamicInput4, SetLayer, SetPictureEffect, SetPictureEffectDuration, SetPictureTransition, VideoCallAudioSource, VideoCallVideoSource, VideoDelayStartRecording, VideoDelayStartStopRecording, VideoDelayStopRecording, WaitForCompletion
- **NDI**: NDICommand, NDIStartRecording, NDIStopRecording
