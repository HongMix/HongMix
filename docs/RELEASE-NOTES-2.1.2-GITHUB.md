# HongMix 2.1.2

## 한국어

- 레이어 영상이 부모 입력과 함께 재생·정지되며, 여러 카메라가 공유하는 루프는 컷해도 이어집니다.
- SRT·RTMP 송출에 VBR / CBR 비트레이트 모드를 추가했습니다.
- 입력 썸네일이 Fill·Stretch·위치·자르기를 포함해 Program과 동일하게 보입니다.
- 입력 칸의 모니터 버튼으로 보기 전용 입력 모니터 창을 열 수 있습니다.
- 끝난 영상이 출력에서 멈춘 채 나가던 문제를 수정하고 출력 영상 멈춤 자동 복구를 추가했습니다.
- 장시간 켜 둔 맥에서 macOS 위젯이 화면 합성을 막는 증상을 감지하고, 다른 앱이나 설정을 건드리지 않은 채 해당 위젯만 재시작하는 **맥 정리**를 추가했습니다.

![맥 정리](https://github.com/HongMix/HongMix/releases/download/v2.1.2/ko-01-mac-cleanup.png)

![입력 크게 보기](https://github.com/HongMix/HongMix/releases/download/v2.1.2/ko-05-input-monitor-window.png)

[한국어 전체 릴리스 노트](https://github.com/HongMix/HongMix/blob/main/docs/RELEASE-NOTES-2.1.2.ko.md)

---

## English

- Layer media now follows its parent input and shared loops continue across camera cuts.
- SRT and RTMP streaming now offer VBR / CBR bitrate modes.
- Input tiles match Program placement, including Fill, Stretch, position and crop.
- A tile’s monitor button opens that input in a large view-only monitor window.
- Finished clips restart correctly, with a new on-air media watchdog and incident logging.
- **Mac cleanup** detects a stuck macOS widget helper that can stall the HongMix window during long-running shows, then restarts only that helper without closing other apps or requiring a reboot.

![Mac cleanup](https://github.com/HongMix/HongMix/releases/download/v2.1.2/en-01-mac-cleanup.png)

![Input monitor](https://github.com/HongMix/HongMix/releases/download/v2.1.2/en-05-input-monitor-window.png)

[Full English release notes](https://github.com/HongMix/HongMix/blob/main/docs/RELEASE-NOTES-2.1.2.md)

CBR compiled and passed the core test, but constant SRT transport rate has not yet been measured end to end. Reported audio dropouts were not reproduced because the listening output path was unavailable during testing.

The public build is ad-hoc signed and not notarized. If macOS blocks it, use **System Settings › Privacy & Security › Open Anyway**.
