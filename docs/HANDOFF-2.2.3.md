# HongMix 2.2.3 — handoff (Claude → GPT)

Date: 2026-11-14 · Repo: local `main`, last commit `e4c3254` = v2.2.0 (published)

**Publish 2.2.3.** 2.2.1 was built but **not published** — 2.2.3 contains it (SRT receive fix, SRT settings by double-click, recent / saved SRT list: `docs/HANDOFF-2.2.1.md`). There is no 2.2.2 (the user chose the number: from now on every improvement changes the last digit). Everything is **uncommitted** on top of `e4c3254`.

## 1. State

| What | Value |
|---|---|
| Version | `Resources/Info.plist` **2.2.3**, build **128** (126–127 were test builds) |
| Installers | `build/dist/HongMix-2.2.3.dmg` / `.pkg`, ad-hoc signed |
| SHA-256 | DMG `387cdbac354827391c4b30caaac9e5552cb9279c40817ca3f1600cedd2547f36` · PKG `f4174c7b29b59705d41867d2aca922be178566436de7ab7c1a0d545531555fcf` (`build/dist/SHA256.txt`) |
| Copy for the user | `~/Desktop/HongMix/HongMix 2.2.3 배포/` (DMG, PKG, SHA256.txt, `test-results/`), `~/Desktop/HongMix 2.2.3.app` (**running now** on the user's Mac with their project) |
| Screenshots | `docs/screenshots/2.2.1/` (SRT settings, KO / EN) — no UI change in 2.2.3 |
| Test results | `docs/test-results/2.2.1/` (the receive fix) and `docs/test-results/2.2.3/` (incident log examples) |

## 2. How to publish
1. Use the DMG/PKG as is (if you rebuild: build **129**). `test-core.sh` PASS, `check-i18n.py` PASS (8 new EN strings), `hdiutil verify` VALID.
2. Commit as `Seunghoon Hong <176268839+HongMix@users.noreply.github.com>`. New since `e4c3254`: `Sources/App/Engine/SRTPresets.swift`, `docs/HANDOFF-2.2.1.md`, `docs/HANDOFF-2.2.3.md`, `docs/screenshots/2.2.1/*`, `docs/test-results/2.2.1/*`, `docs/test-results/2.2.3/*`. Never add `HongMIX-signing/` or `build/`.
3. Release notes `docs/RELEASE-NOTES-2.2.3.md` / `.ko.md` / `-GITHUB.md` = 2.2.1 §5 + §4 here. KO notes `ko-04-srt-settings.png`, EN / GitHub `en-04-srt-settings.png`. US spelling; read EN against KO.
4. `gh release create v2.2.3 --repo HongMix/HongMix --latest`. Recommend the update to everyone who receives SRT.

## 3. What's new in 2.2.3: the blackbox says *why* an SRT link broke
User: "can't you tell why it cuts out?" — with remote control off, the live SRT state of the running app couldn't be read afterwards; the incident log only said "SRT drop N packets" / "signal lost".

Now every SRT incident (`srtLoss`, and `signalLost` of an on-air SRT input) records:
- **In `incidents.txt`**: buffer ms / latency ms · RTT · loss % · drops in the last 30 s · Mbps · frames per second HongMix took · **verdict**. After a disconnect the numbers are the ones *just before* it ("Just before the drop: …").
- **`srt.txt` in the incident folder**: the verdict and the link's last 30 s, one line per second: buffer, latency, RTT, loss %, drops, retransmissions, Mbps, fps.

Verdict (`SRTMonitor.Link.verdict`, in this order):
| Verdict | Rule |
|---|---|
| Disconnected — the sender or network closed the connection | not connected |
| No data arriving — sender stopped / path blocked | rate < 0.05 Mbps |
| **HongMix reading too slowly** (HongMix problem) | receive buffer > latency + max(1 s, latency) |
| Network problem — latency too short for the RTT | max RTT (30 s) × 4 > latency |
| **Dropped by the sender** — missing without retransmission | drops and retransmissions < ¼ of drops (there was time to resend; the sender didn't: bandwidth limit, overload) |
| Network loss — retransmission couldn't recover everything | drops with retransmissions |
| Network loss — being recovered (no visible effect yet) | loss > 1 %, no drops |
| No clear cause — see the attached log | otherwise |

Also fixed: **SRT statistics were read with "clear interval counters"** (`srt_bstats(…, 1)`), so the status board, statistics window, API and monitor reset each other's figures — rate / loss / retransmissions often showed 0 or random values. Now `srt_bistats(…, clear 0, instantaneous 1)` (current rate, buffer; running totals) and loss % over one shared ≥ 1 s window per link (`mc_srt.c`).

## 4. Release-note bullet (KO / EN) — add to 2.2.1's
- **끊김 원인을 블랙박스에 자동 기록** — SRT가 끊기거나 패킷이 빠지면 그 순간의 버퍼·Latency·RTT·손실·재전송·fps와 판정(HongMix / 회선 / 보내는 쪽)을 사고 기록에 남기고, 직전 30초 기록을 파일로 저장 / **The blackbox now says why an SRT link broke** — buffer, latency, RTT, loss, retransmissions and fps at that moment plus a verdict (HongMix / network / sender), with the last 30 seconds saved next to the incident.
- **SRT 통계가 0이나 엉뚱한 값으로 보이던 문제 수정** / **Fixed SRT statistics sometimes showing 0 or wrong rate / loss.**

## 5. Verification (user's project + defaults backed up and restored byte-identical; the user's HongMix was quit for the test with their OK, test incidents removed from the user's log afterwards and kept in `docs/test-results/2.2.3/`)
| Test | Result |
|---|---|
| Local SRT caller input on air, sender killed | `signalLost` · "Just before the drop: buffer 283 ms / latency 200 ms · RTT 0.3 ms · loss 0.00% · drops 0 · 8.87 Mbps · 60.1 fps · Disconnected"; `srt.txt` 30 lines, latency / Mbps filled (`srt-disconnect-example.txt`) |
| Local SRT sender limited to 4.8 Mbps for an 8 Mbps stream (`maxbw`) | `srtLoss` every ~10 s · loss ~42 %, retransmissions 0 · verdict **"Dropped by the sender"** (build 127 said "network problem" → rule fixed in 128) (`srt-sender-drop-example.txt`) |
| Stats with several readers (API + monitor + UI) | rate 8.87 Mbps, loss / retransmissions consistent (were 0 / random) |
| The receive fix itself (2.2.1) on the user's real link | `docs/test-results/2.2.1/`; plus 20 min on the user's own HongMix 2.2.1: 0 incidents (2.2.0: signal lost 16 min after start) |
| Not tested | "HongMix reading too slowly" and "network loss" verdicts (can't be produced on purpose without root network shaping); their rules are thresholds on the same figures |

## 6. Live status on the user's Mac (19:46–19:56, HongMix 2.2.3 receiving their real SRT link)
- 0 signal lost. One incident right after start: `19:46:08 SRT loss 7.74 % · buffer 1137 / latency 1000 ms · RTT 13.8 ms · drops 0 · 8.61 Mbps · 60.0 fps · verdict: network loss, recovered by retransmission (no visible effect)` — a short network wobble at connect (RTT normally 5 ms), handled by SRT. This is the new 2.2.3 incident format working on the real link.
- Status: the cause of the drop-outs (HongMix consuming ~2.7 % too slowly) is fixed; to be confirmed over a few hours of real use. If it cuts out again, the incident line and `srt.txt` now give the cause.

## 7. For the user
- Running now: `~/Desktop/HongMix 2.2.3.app`. `/Applications` still has 2.2.0 — install the 2.2.3 PKG.
- Incident log: `~/Movies/HongMix/Incidents/incidents.txt`; each incident folder has `srt.txt` for SRT links.
