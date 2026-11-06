# HongMix 1.4.2

## 출력 창(Display) 전체화면
- 출력 창을 macOS 전체화면(초록 버튼)으로 바꾼 뒤 끄면 검은 "전체 화면" 데스크탑이 남던 문제를 고쳤습니다.
  원인: 창을 숨기기만 하고 macOS 전체화면을 해제하지 않았고, 창이 실제로 닫히지 않았습니다.
- 출력 창은 macOS 전체화면 데스크탑(Space)을 더 이상 쓰지 않습니다. 초록 버튼 = 그 창이 있는 디스플레이를
  테두리 없이 채우기, Esc · 더블클릭 · 우클릭으로 원래 창 크기·위치로 돌아옵니다. (스와이프·Mission Control 로 방송 화면이 넘어가지 않음)
- 혹시 전체화면 상태로 닫히는 창은 전체화면을 먼저 해제한 뒤 닫습니다.

## 출력 설정 창 분리
- Record ⚙ = 녹화만, External ⚙ = NDI · DeckLink 만(+ Output 2–4 라우팅), Stream ⚙ = 스트림·리턴 피드만 보이는 각각의 설정 창.
- "출력 추가"도 그 종류만. 모든 출력을 한 번에 보려면 도구 › 모든 출력 보기….

## Monochrome UI (기본 스킨)
- 흑백 UI, 색은 의미에만: Program 빨강 · Preview 초록(방송 탤리), ON AIR · REC 빨강.
- 상단·하단 바는 떠 있는 Liquid Glass(macOS 26+, 이전은 반투명 재질).
- 모니터: 얇은 탤리 테두리 + 점 · PREVIEW / PROGRAM 라벨, 둥근 모서리.
- CUT 흰 버튼, Quick Play 흰 테두리. 입력 타일 머리는 중립색, 탤리는 테두리로.
- 하단 출력 버튼: 켜지면 "● REC 00:12:31 · 30.0 Mb/s" 처럼 경과 시간·비트레이트. 상단에 ON AIR 경과 시간.
- 믹서: ON AIR 빨강 · ON 흰색 · AUTO 회색 테두리 · MUTE 어두운 바탕 빨강 글자.
- 스킨은 Monochrome / 기본 두 가지 (Graphite 제거). 설정 › 일반 › 화면 모양, 1.4.2 처음 실행 시 한 번 Monochrome 으로 전환.
- 믹서 Follow(→) 버튼은 Monochrome 에서 회색 (빨강은 방송 중 표시에만).

## 하단 바
- Display ⚙ = 디스플레이 출력 설정 패널 (방식 · 디스플레이 · 소스 · 항상 위 · 16:9 · 켜기/끄기), 한국어/영어.
- Instant Replay · Scopes 를 도구 메뉴에서 하단 버튼으로 이동. 도구 › 모든 출력 보기… 유지.

## 테스트용 API (HongMix 확장)
- MainWindowFullscreen (on/off/toggle), DisplayOutputMode (window/fullscreen), OutputWindowZoomButton (초록 버튼 실제 클릭),
  OutputWindowSystemFullScreen (⌃⌘F), OutputWindowFill, OutputWindowExit — 창 동작 자동 점검용.

## 출력 창이 다른 데스크탑으로 튀던 문제 (추가 수정)
- 스위처 창이 macOS 전체화면일 때 Display 를 켜면 macOS 가 다른 데스크탑으로 전환해 스위처가 사라지고
  출력이 "안 되는" 것처럼 보였습니다. 출력 창이 현재 데스크탑(전체화면 Space 포함) 위에 뜨도록 수정
  (fullScreenAuxiliary + moveToActiveSpace). 전체화면 Space 안에서는 메뉴바/Dock 옵션을 건드리지 않음.
- 채우기 상태 기억이 남아 다음 Esc 가 창을 다시 여는 문제, 화면 설정 변경 시 채운 창이 다른 모니터로 옮겨가던 문제,
  "스위처 화면" 판별이 출력 창을 스위처로 오인하던 문제 수정.

## 코드 정리
- 스킨 값 캐시(색상 접근마다 UserDefaults 읽기 제거), 스킨 변경 시 모든 창 갱신(.id(language + skin)).
- Monochrome 에서 Overlay 8 색을 빨강 → 슬레이트(Program 빨강과 구분). 하단 출력 버튼 1초 타이머는 켜져 있을 때만.
- 쓰지 않는 macOS 전체화면 해제 경로 제거, Graphite 잔여 문자열 제거.

## 개발 빌드 주의 (중요)
- build/cli 의 개발 빌드는 FFmpeg 를 ~/Documents/... 에서 읽어 macOS 가 "문서 폴더 접근" 허용을 묻고, 답할 때까지 앱이 멈춥니다
  (빌드마다 서명이 바뀌어 다시 물음). 실행·테스트는 scripts/make-dmg.sh 로 만든 DMG 의 앱(라이브러리 내장)으로 하세요.

## 검증 (M1 Max, 내장 디스플레이 1대, DMG 빌드)
- tests/window/test-display-output.sh: 스위처 창 일반 / macOS 전체화면 두 상태 × 8단계 = 16/16 PASS
  (데스크탑 이동 없음, HongMix 전체화면 Space 추가 0, 창 크기·표시 확인).
- 초록 버튼: 출력 창 960×540 → 1728×1117 → Esc → 960×540.
- scripts/test-core.sh 통과. 릴리스 빌드 경고 없음. DMG 앱 외부 라이브러리 의존 없음.
- 미확인: 다중 모니터, 유리 바(Liquid Glass)의 실제 화면 모양.
