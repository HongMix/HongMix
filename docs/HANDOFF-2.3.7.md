# HongMix 2.3.7 — handoff (Claude → GPT)

Date: 2026-11-27 · Repo: local `main`, last commit `3637801` = v2.3.6 (published).

**Publish 2.3.7** — community contribution PR #9 by **@otiumvisuals** (MultiView, Talent Cue, hardware look, outputs panel and more), merged and fixed. The operator approved merging it as a whole after reviewing it in the running app.

## 1. State — a merge is in progress
- `git merge --no-ff --no-commit pr9` was run: `.git/MERGE_HEAD` = `997243ab25f8027ad0e2f8d1fea7d1d7044a12ba` (PR #9 head). **Commit it as a merge commit** (don't abort, squash or rebase), so the contributor's 6 commits keep their authorship and GitHub marks PR #9 as merged when `main` is pushed.
- On top of the merge (uncommitted): `scripts/make-dmg.sh`, `Sources/App/UI/Backstage.swift`, `Sources/App/UI/TalentCueWindow.swift`, `Resources/en.json`, `Resources/Info.plist`, this file, `docs/screenshots/2.3.7/*`, `docs/test-results/2.3.7/*`.

| What | Value |
|---|---|
| Version | `Resources/Info.plist` **2.3.7**, build **171** (169–170 = test builds) |
| Installers | `build/dist/HongMix-2.3.7.dmg` / `.pkg`, ad-hoc signed |
| SHA-256 | DMG `d30053f899a07aa8a19ad1edc8b44cc5f14be59c7a455f1bf5fd984aa44bf044` · PKG `508fb50f2b12ddc1e8537f9279e82ac707da979a12897af14c5fed1a5f8766b7` |
| Don't commit | `Blackmagic-settings-backup-2026-11-16/`, `docs/screenshots/2.0.9/*`, `build/`, `HongMIX-signing/` |

## 2. What 2.3.7 adds (from PR #9)
- **MultiView**: several MultiViews, 7 layouts (2+8, 8+2, left/right, 2×2, 3×3, 4×4), a source per cell, names / tally borders, editor window, send to a monitor; usable for Output 2–4, Display output and monitor outputs. MultiViews drop frame rate first under heavy load so Program keeps full rate.
- **Talent Cue** (stage timer): presenter screen with countdown / count-up, colour phases, prepared messages (blink), idle screen, blackout; "Talent Display" source; moderator browser link `/talent?key=…` (own secret key, Talent only).
- **Backstage** crash safety net (Settings › General, **off by default**): helper keeps the Talent Display up and relaunches HongMix after a crash / Force Quit (max 3 × in 2 min). Streaming/recording are not protected.
- **Hardware look** (Settings › General, on by default): console-style mixer strips, raised keys, aluminium relief; the center column keeps the 2.3.5 layout. Off = previous flat look.
- **Outputs panel** reworked (one row per monitor, multiple output windows, renaming), **Audio Mixer as a separate window**, **CPU / GPU / RAM** in the top bar, **720p50, 2160p25, 2160p50**, **Dutch** captions, **drag inputs onto category tabs**, fixed Input Properties size, Replay window look.

## 3. Changes by Claude on top of PR #9
1. `scripts/make-dmg.sh`: bundled libraries now load each other via `@loader_path/` — the Backstage helper could not start at all in the installed app (dyld: libssl not found from libsrt). Verified: helper starts, relaunch after `kill -9` ≈ 1 s.
2. `scripts/make-dmg.sh`: strip the Backstage helper binary like the main binary (23.5 MB → 8.8 MB, no symbols).
3. `Backstage.swift`: **off by default** (opt-in).
4. `TalentCueWindow.swift` + `en.json`: "−1분 / +1분" in the Korean UI (was English); "Background color" US spelling.

## 4. Verification
`docs/test-results/2.3.7/verification.md`. Summary: check-i18n, test-core, PR tests (multiview, talentcue), hdiutil, deep codesign all pass; operator's own project opens; Backstage off by default / on: relaunch + clean quit OK; display output regression OK; MultiView over NDI 1080p ~58 fps; moderator link access rules OK. Open: one AppKit launch crash in 8 launches (not reproduced), no second monitor for monitor features. Operator's project / settings / incidents restored (settings identical by value).

## 5. Screenshots (`docs/screenshots/2.3.7/`, synthetic, LAN address masked)
`ko-`/`en-` + `main` (hardware look), `center`, `mixer`, `multiview` (editor), `talentcue` (control window), `talent` (presenter screen); `multiview-output.png` (MultiView frame received over NDI, no UI text).

## 6. How to publish
1. Use the DMG/PKG as is (if you rebuild: build **172**).
2. `git add` the files in §1 and `git commit` (completes the merge) as `Seunghoon Hong <176268839+HongMix@users.noreply.github.com>`, message e.g. `Release HongMix 2.3.7: MultiView, Talent Cue and hardware look (merge PR #9 by @otiumvisuals)`. Push `main` → PR #9 shows as merged.
3. Release notes `docs/RELEASE-NOTES-2.3.7.md` / `.ko.md` / `-GITHUB.md` from §7, with the thanks line at the top. EN notes `en-*`, KO notes `ko-*`. US spelling.
4. README (KO + EN): add a short "Thanks / 감사" line: "MultiView, Talent Cue and the hardware look in 2.3.7 were contributed by @otiumvisuals."
5. Manuals: version 2.3.7; new sections MultiView, Talent Cue (+ moderator link), Backstage (off by default), hardware look, outputs panel.
6. `gh release create v2.3.7 --repo HongMix/HongMix --latest`, then post §8 on PR #9 (it will already show "merged").

## 7. Release-note bullets (KO / EN)
- 감사 / Thanks: **이번 버전의 MultiView, Talent Cue, 하드웨어 룩 등은 @otiumvisuals 님이 기여해 주셨습니다. 감사합니다!** / **MultiView, Talent Cue, the hardware look and more in this release were contributed by @otiumvisuals — thank you!**
- **MultiView 여러 개** — 레이아웃 7종, 칸마다 화면 선택, 모니터·출력으로 보내기 / **Multiple MultiViews** — 7 layouts, choose what each cell shows, send to monitors and outputs.
- **Talent Cue (무대 타이머)** — 발표자 화면에 남은 시간·메시지, 사회자는 휴대폰 링크로 조작 / **Talent Cue (stage timer)** — time left and messages on a presenter screen, controlled from a phone link.
- **하드웨어 룩** — 콘솔 같은 믹서 채널과 입체 버튼 (설정에서 끌 수 있음) / **Hardware look** — console-style mixer strips and raised keys (can be turned off in Settings).
- **Backstage (선택)** — 켜면 HongMix가 비정상 종료돼도 자동으로 다시 실행 / **Backstage (optional)** — when on, HongMix restarts automatically after a crash.
- **출력 패널 개편·출력 창 여러 개, 믹서 별도 창, CPU·GPU·RAM 표시** / **Reworked outputs panel and multiple output windows, Audio Mixer in its own window, CPU / GPU / RAM in the top bar.**
- **720p50 · 2160p25 · 2160p50, 네덜란드어 자막, 카테고리로 끌어 넣기** / **720p50 · 2160p25 · 2160p50, Dutch captions, drag inputs onto categories.**
- 참고 / Note: 새 MultiView·Talent 소스를 쓴 프로젝트는 2.3.6 이하에서 열리지 않습니다 / Projects that use the new MultiView or Talent sources don't open in 2.3.6 or older.

## 8. Comment to post on PR #9 (after release)
> Merged and released in **2.3.7** — thank you so much! I took the whole PR in one piece after testing it. A few changes on top: Backstage is off by default (opt-in in Settings › General), and `make-dmg.sh` now makes the bundled libraries load via `@loader_path` (in the installed app the helper couldn't find libssl from libsrt and exited at launch) and strips the helper binary. Your name is in the release notes. Thanks again for MultiView and Talent Cue!
