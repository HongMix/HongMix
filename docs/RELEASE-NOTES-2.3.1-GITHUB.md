# HongMix 2.3.1 · build 149

> 입력을 닫을 때 한 번 더 확인하고, 웹 입력 충돌을 고쳤습니다. Input removal now asks first, and a rare web-input crash is fixed.

## 한국어

- 타일의 **×**나 메뉴로 입력을 닫을 때 확인 — **다시 묻지 않기** 선택 가능, **설정 › 일반 › 실수 방지**에서 다시 켜기
- Suno처럼 바로 소리가 나는 웹 페이지를 입력으로 추가할 때 드물게 앱이 종료되던 문제 수정
- 충돌 후 다음 실행 때 GitHub 이슈에 첨부할 충돌 보고서 안내
- 오디오 웹 페이지 추가·삭제 120회 테스트에서 충돌 없음

## English

- The tile **×** and menu now ask before closing an input, with **Don't ask again**; turn it back on in **Settings › General › Safety**
- Fixes a rare crash when adding a web page that starts playing sound immediately, such as a Suno overlay
- The next launch offers the crash report to attach to a GitHub issue
- No crash in 120 add/remove cycles with an audio web page

Full notes: [English](https://github.com/HongMix/HongMix/blob/main/docs/RELEASE-NOTES-2.3.1.md) · [한국어](https://github.com/HongMix/HongMix/blob/main/docs/RELEASE-NOTES-2.3.1.ko.md)

Full manuals: [English](https://github.com/HongMix/HongMix/blob/main/docs/manual/HongMix-Manual.en.md) · [한국어](https://github.com/HongMix/HongMix/blob/main/docs/manual/HongMix-Manual.ko.md)

## Verification

Core and translation checks passed. The DMG, checksums and ad-hoc app signature were verified for build 149. The app is not Apple-notarized yet.
