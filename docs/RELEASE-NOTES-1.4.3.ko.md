# HongMix 1.4.3

## 업데이트해도 권한 유지
- 문제: Desktop Capture가 "Screen Recording permission needed"를 띄웠습니다. 시스템 설정에서 HongMix가 켜져 있어도
  마찬가지였습니다. macOS는 권한을 앱 서명에 기록하는데, 이전 버전은 빌드마다 값이 바뀌는 임시(ad-hoc) 서명이라
  업데이트할 때마다 새 앱으로 취급됐습니다.
- 변경: 배포본을 고정된 "HongMix Code Signing" 인증서로 서명합니다. 지정 요구사항은 앱 ID + 인증서이고 cdhash가 아닙니다.
  한 번 준 화면 녹음·카메라·마이크 권한이 이후 업데이트에도 유지됩니다.
- scripts/make-dmg.sh: 키체인에 해당 인증서가 있으면 자동으로 사용하고, 없으면 ad-hoc + 경고를 냅니다.
- README(한/영)에 "macOS 권한" 절을 추가했습니다. 기능별 권한과, 이전 버전에서 올라올 때 한 번 하는 해결 방법을 넣었습니다.

## 이전 버전에서 업데이트할 때 (한 번만)
1. HongMix 종료 → 2. `tccutil reset ScreenCapture com.hongseunghoon.HongMix`
3. HongMix 실행 → Desktop Capture 추가 → 시스템 설정 열기 → HongMix 켜기 → 4. HongMix 다시 실행

## 참고
- Apple 공증은 아직 없습니다. 처음 열 때 우클릭 → 열기가 한 번 필요합니다.
- 인증서와 키는 저장소 밖(HongMIX-signing)에 있습니다. 잃어버리면 다음 배포에서 권한을 한 번 다시 줘야 합니다.
