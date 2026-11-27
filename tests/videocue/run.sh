#!/bin/bash
# Builds and runs the standalone Video Cue logic test.
#   bash tests/videocue/run.sh [outdir]
set -e
cd "$(dirname "$0")/../.."
OUT="${1:-${TMPDIR:-/tmp}/hongmix-videocue-test}"
mkdir -p "$OUT"
swiftc -O -module-cache-path "$OUT/mcache" -o "$OUT/videocue_test" \
  Sources/App/Engine/VideoCueLogic.swift tests/videocue/main.swift
"$OUT/videocue_test"
