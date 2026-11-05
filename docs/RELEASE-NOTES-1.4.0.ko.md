# HongMix 1.4.0 (Build 54)

배포일: 2026-11-05

## 주요 변경사항

- 카메라 영상 장치와 관련 마이크·캡처 오디오 장치를 자동으로 매칭합니다.
- 카메라 입력 설정에 오디오 수동 선택, 자동 매칭, 장치 목록 새로고침을 추가했습니다.
- macOS 아이폰 연속성 카메라 검색과 캡처를 지원합니다.
- 카메라·캡처 NV12 프레임의 입력 타일 프리뷰 경로를 개선했습니다.
- DeckLink SDK 16 로컬 빌드 연동과 입력·출력 설정 UI를 추가했습니다.
- DeckLink 출력에 일반 영상, Straight Fill & Key, Premultiplied Fill & Key 방식을 추가했습니다.
- 약 5초 동안 초기화 상태를 보여 주는 시작 애니메이션을 추가했습니다.
- 오디오 미터 움직임을 부드럽고 안정적으로 조정했습니다.
- 29.97/30fps 입력을 59.94/60fps 프로그램에서 사용할 때 확인할 수 있는 프레임·오디오 큐 진단값을 보강했습니다.

## 확인 상태

| 항목 | 상태 | 설명 |
| --- | --- | --- |
| 아이폰 연속성 카메라 | 지원 및 이전 실제 연결 확인 | 현재 macOS 장치 목록에 아이폰이 나타날 때 추가 실기 캡처가 가능합니다. |
| FaceTime 카메라 + 맥 마이크 | 이번 세션에서 실제 입력 확인 | 1080p29.97 프리뷰와 움직이는 오디오 미터를 함께 확인했습니다. |
| DeckLink SDK 빌드 | 구현 완료 | 사용자가 직접 받은 SDK가 있을 때 빌드합니다. Blackmagic SDK와 런타임은 재배포하지 않습니다. |
| DeckLink Fill & Key 설정 | 코드·UI 구현 완료 | 실제 SDI 입력, 임베디드 오디오, 출력 및 Fill/Key는 DeckLink 장비 테스트 전입니다. |
| SRT / RTMP | 기존 기능 유지 | 사용자가 SRT 동작을 확인했고 RTMP도 기존 동작을 유지합니다. 장시간·네트워크 장애 복구 테스트는 별도입니다. |
| 혼합 프레임레이트 | 진단 기능 보강 | 실제 캡처 장비를 이용한 장시간 A/V 동기 테스트를 계속해야 합니다. |

## 공개 캡처

- `screenshots/1.4.0/1.4.0-main-switcher-redacted.png` — 10개 입력을 사용한 메인 스위처.
- `screenshots/1.4.0/1.4.0-camera-live-audio-redacted.png` — FaceTime 실제 영상과 오디오 미터.
- `screenshots/1.4.0/1.4.0-camera-audio-match-redacted.png` — 카메라·오디오 장치 매칭 설정.
- `screenshots/1.4.0/1.4.0-decklink-output-settings-redacted.png` — DeckLink 출력 라우팅과 장비 미연결 상태.
- `screenshots/1.4.0/1.4.0-decklink-fill-key-options-redacted.png` — 일반, Straight, Premultiplied 출력 방식.
- `screenshots/1.4.0/1.4.0-launch-redacted.png` — 시작 애니메이션과 초기화 상태.

공개 캡처는 왼쪽 Preview 영상 전체와 그 밖의 식별 가능한 얼굴을 모자이크 처리했습니다. 모자이크하지 않은 원본은 Git에서 제외합니다.

## 아직 확인이 필요한 항목

- 실제 DeckLink 장비를 연결한 입력·출력 및 Fill/Key 검증
- 장시간 송출, SRT 재연결, 오디오·영상 드리프트 검증
- 여러 캡처카드와 다양한 Apple Silicon 모델에서의 호환성 확인
