# HongMix 2.3.0 · build 143

> H.264 송출·녹화에 프레임레이트 정보를 기록합니다. H.264 streams and recordings now carry their frame rate.

## 한국어

- AJA BRIDGE LIVE 같은 수신 장비가 59.94fps 출력을 58.94로 잘못 인식하던 문제 수정
- H.264 송출·SRT 출력·녹화 시퀀스 헤더에 프레임레이트 정보 기록
- 사용자가 실제 AJA BRIDGE LIVE에서 59.94 표시 확인
- 화면 변경 없음 — 기존 설명서와 캡처를 그대로 사용

## English

- Fixes receivers such as AJA BRIDGE LIVE detecting a 59.94 fps output as 58.94
- Adds frame-rate timing information to H.264 stream, SRT and recording sequence headers
- Confirmed by the user on an actual AJA BRIDGE LIVE
- No interface change — existing manuals and screenshots remain representative

Full notes: [English](https://github.com/HongMix/HongMix/blob/main/docs/RELEASE-NOTES-2.3.0.md) · [한국어](https://github.com/HongMix/HongMix/blob/main/docs/RELEASE-NOTES-2.3.0.ko.md)

Full manuals: [English](https://github.com/HongMix/HongMix/blob/main/docs/manual/HongMix-Manual.en.md) · [한국어](https://github.com/HongMix/HongMix/blob/main/docs/manual/HongMix-Manual.ko.md)

## Verification

Core and translation checks passed. The DMG, checksums and ad-hoc app signature were verified for build 143. The app is not Apple-notarized yet.
