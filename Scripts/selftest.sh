#!/bin/bash
# Runs the app's in-process UI smoke test on a throwaway database.
# Usage: Scripts/selftest.sh [output-dir]   (PNG snapshots and result.txt land there)
# By default the app runs in the background: no Dock icon, no visible window, never takes focus,
# and its own preferences. Checks that need keyboard focus are then skipped and listed as "skip".
# FLOTION_FOREGROUND=1 shows the window and asks for focus so those checks run too.
set -uo pipefail
cd "$(dirname "$0")/.."
OUT=${1:-.build/selftest}
rm -rf "$OUT"; mkdir -p "$OUT"
APP=.build/xcode/Build/Products/Debug/Flotion.app/Contents/MacOS/Flotion
[[ -x "$APP" ]] || { echo "build the app first (Scripts/verify.sh)"; exit 2; }
FLOTION_DB="$OUT/flotion.sqlite" FLOTION_SELFTEST="$OUT" FLOTION_FAKE_AI=1 "$APP" >"$OUT/app.log" 2>&1 &
PID=$!
for _ in $(seq 1 60); do kill -0 $PID 2>/dev/null || break; sleep 0.5; done
if kill -0 $PID 2>/dev/null; then kill $PID; echo "self-test timed out"; exit 1; fi
wait $PID; STATUS=$?
cat "$OUT/result.txt" 2>/dev/null || echo "no result written"
grep -i "warning\|error\|exception" "$OUT/app.log" || true
exit $STATUS
