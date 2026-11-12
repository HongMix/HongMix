# HongMix 2.1.3 — handoff (Claude → GPT)

Date: 2026-11-13 · Mac: Apple M1 Max, macOS 27.3 · Repo: local `main`, last commit `85879a7` = v2.1.2 release (build 109, already published on GitHub)

**GPT publishes to GitHub.** 2.1.3 is **uncommitted** in the working tree on top of `85879a7`. The untracked `docs/screenshots/2.0.9/*.png` are still 2.0.9 leftovers — not part of this release.

## 1. State

| What | Value |
|---|---|
| Version | `Resources/Info.plist` **2.1.3**, build **110** |
| Public installers (already built) | `build/dist/HongMix-2.1.3.dmg` / `.pkg`, ad-hoc signed, LGPL FFmpeg |
| SHA-256 | DMG `4f832b9f57c5fdfc91c846b62db78b50efc05e47042dd3e71efd0b060dfeb6fb` · PKG `9b7847b5671686792b81d41778e8b42d68c22b8444c56ce868a83c1b7fc60437` (also `build/dist/SHA256.txt`) |
| Copy for the user | `~/Desktop/HongMix/HongMix 2.1.3 배포/` and `~/Desktop/HongMix 2.1.3.app` (from this DMG) |
| Screenshots (KO/EN) | `docs/screenshots/2.1.3/` — §8 |

## 2. How to publish

1. **Use the DMG/PKG already in `build/dist/` (2.1.3 build 110).** If you must rebuild, bump to build **111** first, then `SIGN_ID="-" bash scripts/make-dmg.sh`.
2. Check: `codesign -dvv` → `Signature=adhoc`, `HongMix Focus.shortcut` + `en.json` present, version 2.1.3 (110).
3. `bash scripts/test-core.sh` (PASS on this tree; C core unchanged since 2.1.2).
4. Commit as `Seunghoon Hong <176268839+HongMix@users.noreply.github.com>`; never add `HongMIX-signing/` or `build/`. New files to add: `scripts/check-i18n.py`, `docs/screenshots/2.1.3/*`, this file.
5. Release notes `docs/RELEASE-NOTES-2.1.3.md` / `.ko.md` / `-GITHUB.md` from §7 (**put the remote-control default change first** — it changes behaviour for Companion users), README "Latest update" with §8 screenshots.
6. `gh release create v2.1.3 --repo HongMix/HongMix --latest`, same asset set as v2.1.2 (DMG, PKG, manuals EN/KO, SHA256.txt, THIRD-PARTY-NOTICES.txt, screenshots).
7. Manuals + `docs/FUNCTIONS.md`: remote-control switch (§3.1), ⌘W (§3.2).

## 3. What's new

### 3.1 Remote control switch — off by default (`ControlAPI.swift` `APIAccess.enabled`, `SwitcherEngine.applyRemoteControl()`, `OutputsSheet.swift` `RemoteControlSection`)
User decision (vMix-style, "only for those who need it"): Settings › Network › **Remote Control › Enable remote control**.
- **Off = ports 8088 (HTTP API / web remote) and 8099 (Companion TCP) are not opened at all.** Turning it on/off applies immediately (listeners started/stopped; `allowLocalEndpointReuse` so it re-binds at once).
- On = previous behaviour: devices on the network (or "This Mac only"), optional IP allow-list, optional HTTP password.
- Default: **off** for new installs and for anyone who never touched the old "Allow" picker. Users who had chosen a mode in an earlier version (`apiAccessMode` = lan/local) stay on. → **Companion / Stream Deck users must turn it on once after updating** (release notes!).
- Launch screen and Pre-show check show "Remote control off (Settings › Network)" instead of a warning.
- Not changed by user decision: password / stream keys stay in plain settings/project files; HTTP stays unencrypted (with the switch off nothing listens); test hooks stay for now (the user will remove them later).

### 3.2 ⌘W closes windows (`HongMixApp.swift` `WindowCloser`)
- File › **Close Window ⌘W**; also caught by the app key monitor so it works while a text field in a sheet has focus.
- Closes: Scopes, Rundown, Replay, PTZ, Statistics, input monitor, Pre-show check, Settings; SwiftUI sheets (input editor, scheduler, outputs …) close like their Cancel.
- **Never closes** the switcher window (would quit HongMix mid-show) or the Display output window → beep. Confirmation alerts / open-save panels → beep (closing them could count as an answer).

### 3.3 Display-lag alert only when it's actionable (`SystemHealth.swift`, `SafetyChips.swift`)
User feedback: the orange "Mac display is slow" bar kept showing and blamed whatever app used CPU (e.g. Claude Helper) — unsettling during a show although output was fine.
- Orange bar **only** when a stuck macOS widget helper is found (one click fixes it). Text: "Mac display lag caused by Live Activities widget — Clean Up fixes it right away (output not affected)".
- Anything else → small grey **"Display lag"** chip in the top bar (tooltip lists CPU-heavy apps; click → Pre-show check › Mac Cleanup).
- Alert and old results clear by themselves after **60 s without a stall** (before: stayed until a successful cleanup).
- Auto cleanup runs silently (incident recorder only), no bar.
- Every cleanup's 10 s result is logged in the incident recorder.

### 3.4 Pre-show check › Renderer judges recent drops (`Preflight.swift`, `SwitcherEngine.recentDrops`)
User asked why "Renderer" was orange: it was 1 drop since launch (project load) while render was 1.2 ms of a 16.7 ms budget. Now warns only for drops in the **last 5 minutes** (first 60 s after launch ignored); otherwise green "no drops in last 5 min (N total)".

### 3.5 Audio underrun numbers fixed (`MediaBuffers.swift` `AudioRing.read(diagnose:)`, `AudioMixer.swift`)
Statistics showed ~30 000 red "audio underruns" on off-air inputs (qtrle graphics without sound, paused clips). Cause: the off-air **meter-only** read counted an empty ring as an underrun ~47×/s. Now only real on-air reads count. Test: off-air inputs 0 (was 30 k after 11 min); cuts 8↔10 → on-air mix underflows 0.

### 3.6 English UI completed (`Resources/en.json`, `scripts/check-i18n.py`)
- 4 lists cached the first language in a `static let` (Mac Cleanup setup guide, scheduler weekdays, caption languages/targets) → computed, follow a language switch.
- Missing strings added; American spelling and consistent terms in 85 entries (colour→color, programme→program, Show safety→On-Air Safety, Play→Playback header, Pre-show Check, Mac Cleanup, Clean Up …). Section headers that shared a key with buttons got their own keys (`재생 설정`, `MIDI 매핑`, `설정 열기`).
- **`scripts/check-i18n.py` runs in `build-cli.sh`**: the build fails if a Korean `L("…")` key has no English or an `L()` is cached in a `static let`.

### 3.7 Test hook
`SnapshotView` name `remote` (Settings › Network › Remote Control section).

## 4. Verification (real app on the user's Mac; defaults + last-session backed up)

| Test | Result |
|---|---|
| Launch with remote control off | `lsof`: **no** listening port; API unreachable |
| Settings toggle on → off → on (live, real UI) | 8088/8099 open → closed (connection refused) → open, HTTP 200 |
| ⌘W (File › Close Window) | Scopes, Pre-show check, Settings closed; switcher window stays, app alive |
| Audio | off-air underrun counters 0 (were ~30 000); on-air underflows 0 across cuts |
| `scripts/check-i18n.py` | PASS (0 missing, 0 cached) |
| `scripts/test-core.sh` | PASS |
| DMG/PKG 2.1.3 (110) | `codesign --verify --deep --strict` OK, ad-hoc, shortcut + en.json present |

Not verified automatically: ⌘W on a SwiftUI sheet (scheduler / input editor) — asked the user to try once.

## 5. API
No public changes. With remote control off, the HTTP/TCP API is unavailable (by design).

## 6. Known / open
- CBR stream not measured end-to-end (from 2.1.2).
- The audio dropouts the user hears are still not reproduced; the misleading counter is fixed, the real listening path is still needed.
- UI stalls while macOS's Live Activities renderer is busy (it was at 64 % again during this test); cure = iPhone Live Activities off.
- App not notarized (no developer account planned this year).

## 7. Release-note bullets (KO / EN)

- **원격 제어 켜기/끄기 (기본: 꺼짐)** — 설정 › 네트워크 › 원격 제어. 끄면 8088·8099 포트를 아예 열지 않아 같은 와이파이의 다른 기기가 HongMix를 조작할 수 없습니다. **Companion·Stream Deck·웹 리모트를 쓰시면 업데이트 후 한 번 켜 주세요** (이전 버전에서 허용 범위를 직접 고른 경우는 켜진 채 유지) / **Remote control on/off (default: off)** — Settings › Network › Remote Control. When off, ports 8088 and 8099 stay closed, so no other device on the same Wi-Fi can control HongMix. **Companion, Stream Deck and web-remote users: turn it on once after updating** (kept on if you had chosen an Allow option before).
- ⌘W로 창 닫기 (스코프·큐시트·리플레이·통계·설정·입력 편집 등). 방송이 끊기지 않도록 메인 스위처 창과 출력 창은 닫히지 않습니다 / ⌘W closes windows and sheets (Scopes, Rundown, Replay, Statistics, Settings, input editor …). The switcher and Display output windows never close, so a show can't be cut by accident.
- 화면 지연 알림 정리: 주황 줄은 "정리하기"로 바로 고칠 수 있을 때만 뜨고, 그 밖에는 위쪽에 작은 "화면 지연" 표시만 나옵니다. 1분 동안 괜찮으면 저절로 사라집니다 (송출에는 영향 없음) / Calmer display-lag alerts: the orange bar appears only when Clean Up can fix it; otherwise a small "Display lag" chip, which clears after a calm minute (output never affected).
- 시작 전 점검 렌더러는 최근 5분 기준으로 판정 (앱 켤 때 생긴 드롭 1개로 주황불이 켜지지 않음) / Pre-show Check judges the renderer on the last 5 minutes (a single drop while loading at launch no longer turns it orange).
- 통계의 오디오 언더런 숫자 수정 — 꺼진 입력의 레벨 확인을 끊김으로 세던 문제 / Fixed inflated audio-underrun counts in Statistics (meter reads of off-air inputs were counted).
- 영문 화면 완성: 남은 번역, 언어 전환 후에도 한국어로 남던 목록, 미국식 철자·용어 통일 / Complete English UI: remaining strings, lists that stayed Korean after switching language, American spelling and consistent terms.

## 8. Screenshots (`docs/screenshots/2.1.3/`)

| File | Shows |
|---|---|
| `ko-01-mac-cleanup.png`, `en-01-mac-cleanup.png` | Pre-show Check › Mac Cleanup (English guide now translated) |
| `ko-02-health-banner.png`, `en-02-health-banner.png` | Orange bar, new wording (only when Clean Up can fix it) |
| `ko-03-remote-control.png`, `en-03-remote-control.png` | Settings › Network › Remote Control switch |

No people, footage, IP addresses or stream keys (the status row with the local IP is cropped off).

## 9. Working rules from the user
- UI mockup and approval before UI changes (approved in chat for this release). New build number every build; Desktop copy `HongMix <ver>.app`; deliver DMG (+PKG).
- Korean + English UI (`L("한국어")`, append lines to `en.json`, never re-serialize; `check-i18n.py` must pass).
- Tests must not touch the user's project: back up `last-session.bmix` and `defaults export com.hongseunghoon.HongMix`, restore after; never connect to real stream destinations.
- Reply to the user in Korean.
