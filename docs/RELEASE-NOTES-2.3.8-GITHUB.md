# HongMix 2.3.8 · build 173

> **2.3.7 사용자 모두에게 업데이트를 권장합니다. Recommended for everyone on 2.3.7.**

## 한국어

- 하드웨어 룩을 켰을 때 실행, 컷과 트랜지션 중 Program 프레임이 끊기던 문제를 고쳤습니다.
- 버튼 약 100개의 입체 그림자를 GPU 부담이 없는 어두운 바탕 두 겹으로 바꿨으며 모양은 거의 같습니다.
- 운영자의 4K 59.94 프로젝트에서 2.3.7은 실행 후 63, 페이드 20회에서 34, 컷 10회에서 8프레임을 드랍했습니다. 2.3.8은 같은 측정을 두 번 반복해 모두 0이었습니다.

## English

- Fixes Program frames dropping at launch and during cuts and transitions when the hardware look is enabled.
- Replaces the raised-key shadows on about 100 controls with lightweight offset fills that keep almost the same appearance without the extra GPU work.
- In the operator's 4K 59.94 project, 2.3.7 dropped 63 frames after launch, 34 over 20 fades and 8 over 10 cuts. Two repeated 2.3.8 runs recorded zero in every test.

Full notes: [English](https://github.com/HongMix/HongMix/blob/main/docs/RELEASE-NOTES-2.3.8.md) · [한국어](https://github.com/HongMix/HongMix/blob/main/docs/RELEASE-NOTES-2.3.8.ko.md)

Full manuals: [English](https://github.com/HongMix/HongMix/blob/main/docs/manual/HongMix-Manual.en.md) · [한국어](https://github.com/HongMix/HongMix/blob/main/docs/manual/HongMix-Manual.ko.md)

## Verification and limits

Translation and core tests, DMG verification and deep ad-hoc signing passed. Build 173 uses the measured build 172 source but was not opened with the operator's project because its ad-hoc signature would prompt for folder access again. The app is not Apple-notarized; the PKG is unsigned.
