#!/bin/bash
# Builds and runs the standalone Talent Cue timer test.
#   bash tests/talentcue/run.sh [outdir]
set -e
cd "$(dirname "$0")/../.."
OUT="${1:-${TMPDIR:-/tmp}/hongmix-talentcue-test}"
mkdir -p "$OUT"
swiftc -O -module-cache-path "$OUT/mcache" -o "$OUT/talentcue_test" \
  Sources/App/Engine/TalentTimer.swift Sources/App/Engine/TalentAccess.swift Sources/App/Engine/BackstageRules.swift tests/talentcue/main.swift
"$OUT/talentcue_test"
