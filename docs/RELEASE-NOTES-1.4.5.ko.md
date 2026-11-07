# HongMix 1.4.5

## Desktop Capture 권한
- 문제: 시스템 설정에서 HongMix 를 켰는데도 Desktop Capture 가 "Screen Recording permission needed" 를 계속 띄웠습니다.
  실제 원인(예전 서명에 기록된 권한)이 고정 문구에 가려졌고, 입력이 다시 시도하지 않았습니다.
- macOS 가 알려준 실제 이유를 함께 표시합니다 (예: "사용자가 응용 프로그램, 윈도우, 디스플레이 캡처의 TCC를 거절함").
- 권한은 조용히 확인하고(CGPreflightScreenCaptureAccess), 허용 요청은 앱 실행당 최대 한 번만 합니다.
  이전에는 재시도할 때마다 macOS "기록하려고 합니다" 창이 다시 떴습니다.
- 3초마다 다시 시도해서, 허용되면 저절로 캡처를 시작합니다. 입력을 지웠다 다시 만들 필요가 없습니다.
- 캡처 시작이 빨리 실패하면 입력이 멈춰 버리던 문제를 고쳤습니다.

## 업데이트 후 (한 번)
HongMix 를 켜 두었는데도 권한 필요가 나오면:
1. HongMix 종료 → 2. `tccutil reset ScreenCapture com.hongseunghoon.HongMix`
3. HongMix 실행 → Desktop Capture 추가 → 시스템 설정 열기 → HongMix 켜기 → 4. HongMix 다시 실행

## 서명
- 배포판은 계속 ad-hoc 서명입니다(공증 없음). 1.4.3 에서 시도한 고정 자체 인증서는 그 인증서를 "코드 서명 신뢰"로
  지정한 맥의 개발 빌드용입니다. 신뢰하지 않는 맥에서는 화면 녹음 권한이 아예 적용되지 않기 때문입니다.
  1.4.3·1.4.4 는 배포하지 않았습니다.

## 검증 (M1 Max)
- Desktop Capture 동작(Display 1728×1117), 실제 화면 캡처 확인. 같은 코드 라인에서 Display 출력 회귀 테스트 16/16 PASS.
