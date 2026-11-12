# HongMix 2.1.4 · build 111

> **업데이트 후 확인 / Important:** 원격 제어는 기본으로 꺼집니다. Companion·Stream Deck·웹 리모트 사용자는 **설정 › 네트워크 › 원격 제어**에서 한 번 켜 주세요. / Remote control is now off by default. Companion, Stream Deck and web-remote users should enable it once in **Settings › Network › Remote Control**.

## 한국어

- 입력 우클릭으로 두 번째 디코더 없이 **가상 입력** 생성 (`CreateVirtualInput` API 지원)
- 레이어 편집의 **이동/자르기 모드**, 주황 손잡이와 방향별 자르기 슬라이더
- 입력 설정 위치 탭의 실시간 결과 미리보기, 입력 더블클릭으로 설정 열기
- 입력 썸네일 6·15·30fps 선택; Program·녹화·송출은 항상 원래 속도
- ⌘W로 도구 창·시트 닫기—메인 스위처와 Display 출력은 보호
- 화면 지연·최근 렌더러·오디오 언더런 진단 개선
- 한국어·영어 화면과 시작 상태 문구 번역 완성

## English

- Create a **Virtual Input** from an input context menu without a second decoder (`CreateVirtualInput` API supported)
- **Move/Crop modes**, orange canvas handles and per-edge crop sliders for layers
- Live result preview in Input Settings › Position; double-click an input to open settings
- 6/15/30 fps input thumbnails; Program, recording and outputs always remain full rate
- ⌘W closes tool windows and sheets while protecting the switcher and Display output
- Improved display-lag, recent renderer and audio-underrun diagnostics
- Completed Korean/English UI and launch-status translations

Full notes: [English](https://github.com/HongMix/HongMix/blob/main/docs/RELEASE-NOTES-2.1.4.md) · [한국어](https://github.com/HongMix/HongMix/blob/main/docs/RELEASE-NOTES-2.1.4.ko.md)

## Verification notes

Core tests, translation checks and ad-hoc signing passed. Virtual inputs were tested at 59.94 fps with no extra decoder or render drops. Physical mouse double-click, crop-handle dragging and ⌘W on every sheet still need one manual check. Local CBR SRT loopback kept a stable rate and decoded without errors, but recurring MPEG-TS DTS/PCR warnings remain under investigation. Listening-path audio dropouts were not reproduced.
