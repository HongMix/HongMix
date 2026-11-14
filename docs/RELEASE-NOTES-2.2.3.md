# HongMix 2.2.3 (build 128)

HongMix 2.2.3 is a recommended update for everyone who receives SRT. It includes the unreleased 2.2.1 receive-path fix and SRT connection tools, plus automatic incident diagnosis and corrected statistics.

## SRT receive reliability

- Fixed SRT inputs dropping out every few minutes, especially at 60 fps. HongMix consumed live streams about 2.7% too slowly, so the receive buffer grew until packets were dropped. The buffer now stays near the configured latency.
- Real-link tests after the fix kept the buffer stable at both 1,000 ms and 200 ms latency with 0 drops and 0 signal loss. Local listener, caller and output tests also completed without SRT errors.

## Faster SRT setup

- Double-click an SRT, RTMP or UDP stream-input tile to open its connection settings. Other inputs still open their normal Input Settings.
- Recent SRT connections are remembered, and favorites can be saved with a name. Click to fill the fields or double-click to fill and reconnect. Passphrases are never displayed.
- Live link advice shows RTT, loss, recent drops and a one-click recommended latency.
- API XML now exposes `<inputSrtStats>` without peer addresses or passphrases.

## Incident diagnosis

- When an on-air SRT input loses signal or packets, the incident blackbox records buffer, latency, RTT, loss, drops, receive rate, fps and an automatic verdict.
- Each SRT incident folder contains `srt.txt` with the verdict and one sample per second from the preceding 30 seconds, including retransmissions.
- Verdicts distinguish a disconnect or stopped sender, HongMix reading too slowly, insufficient latency, sender-side drops and network loss.
- Fixed SRT rate, loss and retransmission statistics sometimes showing zero or incorrect values because the API, monitor and UI reset one another's counters.

## Verification

- Force-stopping a local sender recorded the values immediately before the disconnect and a 30-line history.
- Limiting sender bandwidth below the video bitrate produced about 42% loss, zero retransmissions and the expected sender-drop verdict.
- The HongMix-slow-reader and unrecovered-network-loss verdicts were not deliberately triggered because doing so requires privileged network shaping. They use thresholds over the same verified measurements.
- Core tests, translation checks, checksums, DMG verification and ad-hoc app signing passed.

## Known limitations

- Double-clicking a tile, selecting recent rows and using the naming dialog still need wider hands-on verification.
- Passphrases are stored in app preferences like project passphrases; they are not stored in Keychain because ad-hoc signing would prompt again after updates.
- The public app is ad-hoc signed and is not Apple-notarized yet.
