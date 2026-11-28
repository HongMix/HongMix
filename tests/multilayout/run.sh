#!/bin/bash
# Builds and runs the standalone MultiLayout logic test.
#   bash tests/multilayout/run.sh [outdir]
set -e
cd "$(dirname "$0")/../.."
OUT="${1:-${TMPDIR:-/tmp}/hongmix-multilayout-test}"
mkdir -p "$OUT"
swiftc -O -module-cache-path "$OUT/mcache" -o "$OUT/multilayout_test" \
  Sources/App/Engine/MultiLayoutLogic.swift tests/multilayout/main.swift
"$OUT/multilayout_test"
