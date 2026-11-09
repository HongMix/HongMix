#!/bin/bash
# Builds and runs the standalone PTZ engine test against the fake VISCA camera.
#   bash tests/ptz/run.sh [outdir]
set -e
cd "$(dirname "$0")/../.."
OUT="${1:-${TMPDIR:-/tmp}/hongmix-ptz-test}"
mkdir -p "$OUT"
swiftc -O -D PTZ_STANDALONE -module-cache-path "$OUT/mcache" -o "$OUT/ptz_test" \
  Sources/App/Engine/PTZ.swift tests/ptz/main.swift
"$OUT/ptz_test" "$OUT/fake_camera.log" tests/ptz/fake_visca_camera.py
