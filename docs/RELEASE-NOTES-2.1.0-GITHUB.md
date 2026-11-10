# HongMix 2.1.0

## 한국어

- 새 영상은 기본으로 루프 없이 들어갑니다(설정 › 일반에서 변경).
- 화면 맞추기·꽉 채우기·늘리기와 가로·세로 개별 줌으로 LED 와이드 화면을 지원합니다.
- 설정 창이 열려 있어도 정상 종료됩니다.
- 맥 잠자기·덮개 닫힘은 드롭 대신 경고로 기록합니다.
- 송출이 연결되지 않으면 STREAM 버튼이 주황으로 깜빡입니다.

검증: 루프 기본값, 화면 맞춤·X/Y 줌, 종료 경로, Metal 빌드와 SRT 코어 테스트. 실제 덮개 닫힘과 주황 송출 미연결 표시는 직접 확인하지 못했습니다.

처음 실행이 막히면 **시스템 설정 › 개인정보 보호 및 보안 › 그래도 열기**를 누르세요. [한국어 전체 내용](https://github.com/HongMix/HongMix/blob/main/docs/RELEASE-NOTES-2.1.0.ko.md)

---

## English

- New videos no longer loop by default (change under Settings › General).
- Fit, Fill, Stretch and separate horizontal/vertical zoom support wide LED walls.
- Quit works while a settings sheet is open.
- Mac sleep and lid-close pauses are reported as warnings, not dropped frames.
- STREAM blinks orange while a destination is not connected.

Verified: loop defaults, fit modes, X/Y zoom, quit paths, Metal build and the SRT core test. A real lid-close cycle and the orange disconnected-stream indicator were not directly tested.

If macOS blocks the first launch, use **System Settings › Privacy & Security › Open Anyway**. [Full English notes](https://github.com/HongMix/HongMix/blob/main/docs/RELEASE-NOTES-2.1.0.md)
