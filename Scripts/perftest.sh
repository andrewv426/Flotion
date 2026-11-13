#!/bin/bash
# Measures the in-app budgets (launch, page open, typing, scrolling, memory) in a release build.
# Usage: Scripts/perftest.sh [output-dir]
set -uo pipefail
cd "$(dirname "$0")/.."
OUT=${1:-.build/perftest}
rm -rf "$OUT"; mkdir -p "$OUT"
xcodegen generate --quiet
xcodebuild -project Flotion.xcodeproj -scheme Flotion -configuration Release \
  -derivedDataPath .build/xcode-perf 'SWIFT_ACTIVE_COMPILATION_CONDITIONS=$(inherited) SELFTEST' build -quiet \
  2>&1 | grep -E "error:" | cut -c1-300
APP=.build/xcode-perf/Build/Products/Release/Flotion.app/Contents/MacOS/Flotion
[[ -x "$APP" ]] || { echo "release build failed"; exit 2; }
# First launch creates the workspace; the measured launch is the second, as a user's would be.
FLOTION_DB="$OUT/flotion.sqlite" FLOTION_SELFTEST="$OUT/warmup" FLOTION_FAKE_AI=1 "$APP" >/dev/null 2>&1
FLOTION_DB="$OUT/flotion.sqlite" FLOTION_PERFTEST="$OUT" FLOTION_FAKE_AI=1 "$APP" >"$OUT/app.log" 2>&1 &
PID=$!
for _ in $(seq 1 120); do kill -0 $PID 2>/dev/null || break; sleep 0.5; done
if kill -0 $PID 2>/dev/null; then kill $PID; echo "performance test timed out"; exit 1; fi
wait $PID; STATUS=$?
cat "$OUT/result.txt" 2>/dev/null || echo "no result written"
echo
# Idle memory is measured in its own launch, so the stress run above does not inflate it.
FLOTION_DB="$OUT/flotion.sqlite" FLOTION_MEMTEST="$OUT" FLOTION_FAKE_AI=1 "$APP" >>"$OUT/app.log" 2>&1
MEM=$?
cat "$OUT/memory.txt" 2>/dev/null || echo "no memory result written"
echo
[[ $STATUS -eq 0 && $MEM -eq 0 ]]
