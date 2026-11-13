# HongMix 2.1.6 · build 114

## 한국어

- 미리보기에서 위치·레이어를 마우스로 편집: 안쪽 끌기 이동, 노란 모서리 크기, 주황 손잡이 자르기, Option-끌기 보이는 부분 이동
- Program과 같은 미리보기를 오른쪽에 고정하고 출력 픽셀 값을 표시
- 자막·PNG 레이어의 **투명 여백 자동 자르기**
- 원본 오디오가 AUTO일 때 가상 입력이 무음이 되던 문제 수정

## English

- Edit Position and Layers on the picture: drag to move, yellow corners to resize, orange handles to crop, and Option-drag to slide the visible part
- Keep the Program-matched preview fixed on the right and show output-pixel values
- **Trim Transparent Edges** for title and PNG layers
- Fix silent Virtual Inputs when the original input's audio is on Auto

Full notes: [English](https://github.com/HongMix/HongMix/blob/main/docs/RELEASE-NOTES-2.1.6.md) · [한국어](https://github.com/HongMix/HongMix/blob/main/docs/RELEASE-NOTES-2.1.6.ko.md)

## Verification notes

Core tests, translation checks, checksums and ad-hoc signing passed. Geometry and pixel readouts were checked with graphics-only inputs at 1080p59.94. Physical mouse dragging and Trim Transparent Edges still need wider hands-on testing. This build is not Apple-notarized yet.
