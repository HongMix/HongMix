#!/bin/bash
# Standalone MIDI engine test: compiles Sources/App/Engine/MIDIControl.swift (pure + CoreMIDI parts,
# app part excluded via -D MIDI_STANDALONE_TEST) with tests/midi/midi_test.swift and runs it.
#   bash tests/midi/run.sh
set -e
cd "$(dirname "$0")/../.."
OUT="${TMPDIR:-/tmp}/hongmix-midi-test"
mkdir -p "$OUT"
cp tests/midi/midi_test.swift "$OUT/main.swift"
xcrun swiftc -swift-version 5 -O -D MIDI_STANDALONE_TEST -target arm64-apple-macos14.0 \
  -module-cache-path "$OUT/module-cache" \
  Sources/App/Engine/MIDIControl.swift "$OUT/main.swift" -framework CoreMIDI -o "$OUT/midi_test"
"$OUT/midi_test"
