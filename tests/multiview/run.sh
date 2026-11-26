#!/bin/bash
# Builds and runs the standalone MultiView layout test.
#   bash tests/multiview/run.sh [outdir]
set -e
cd "$(dirname "$0")/../.."
OUT="${1:-${TMPDIR:-/tmp}/hongmix-multiview-test}"
mkdir -p "$OUT"
swiftc -O -module-cache-path "$OUT/mcache" -o "$OUT/multiview_test" \
  Sources/App/Engine/MultiView.swift tests/multiview/main.swift
"$OUT/multiview_test"
