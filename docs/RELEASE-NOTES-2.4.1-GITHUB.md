# HongMix 2.4.1 · build 202

## 한국어

- **트랜지션이 다시 부드럽게:** 2.4.0에서 AUTO(Fade·Merge 등) 중 Preview/Program 모니터가 끊기던 문제를 고쳤습니다. 실제 Program 송출 프레임은 빠지지 않았습니다.
- **T바·AUTO 반응 가볍게:** T바를 움직이거나 트랜지션을 시작할 때 화면 전체를 다시 그리지 않습니다.
- 2.4.0의 창 미리 만들기는 트랜지션을 느리게 해서 제거했습니다. 보조 창을 처음 열 때는 약 0.1~0.4초 걸릴 수 있습니다.

## English

- **Smooth transitions again:** in 2.4.0, the Preview/Program monitors stuttered during AUTO transitions such as Fade and Merge. Fixed. Program output itself was never dropping frames.
- **Lighter T-bar and AUTO:** moving the T-bar or starting a transition no longer redraws the whole interface.
- Window prewarming from 2.4.0 was removed because it slowed transitions. Opening a secondary window for the first time can take about 0.1–0.4 seconds.

Full notes: [English](https://github.com/HongMix/HongMix/blob/main/docs/RELEASE-NOTES-2.4.1.md) · [한국어](https://github.com/HongMix/HongMix/blob/main/docs/RELEASE-NOTES-2.4.1.ko.md)

Full manuals: [English](https://github.com/HongMix/HongMix/blob/main/docs/manual/HongMix-Manual.en.md) · [한국어](https://github.com/HongMix/HongMix/blob/main/docs/manual/HongMix-Manual.ko.md)

## Verification and limits

Five runs of each AUTO transition 1–4 measured 53–60 fps on the switcher monitors and zero Program drops. Launch/fade/cut regression checks recorded 0/0/0 drops, and five launch-stress runs completed with no crashes. Replay recording was not started in this round; the 2.4.0 Replay code was unchanged. The Audio Mixer report was not reproduced. Translation, core and MultiView tests, DMG verification and deep ad-hoc signing passed. The app is not Apple-notarized and the PKG is unsigned.
