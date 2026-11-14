#!/bin/bash
# The single gate. Default: package build + all headless tests (unit, contract,
# concurrency, AI-fake, performance budgets) + app build.
#   --no-app    skip the Xcode app build
#   --ui        also run the in-app UI smoke test and the in-app performance budgets
#               (both launch the app for a few seconds)
#   --live-ai   also run the live Claude smoke test (uses your subscription)
set -euo pipefail
cd "$(dirname "$0")/.."

PKG=Packages/FlotionKit
APP=1; UI=0; LIVE=0
for arg in "$@"; do
  case "$arg" in
    --no-app) APP=0 ;;
    --ui) UI=1 ;;
    --live-ai) LIVE=1 ;;
    *) echo "unknown option: $arg" >&2; exit 2 ;;
  esac
done

step() { printf '\n==> %s\n' "$1"; }

# Runs a command quietly: prints only lines matching the pattern on success,
# the whole log on failure.
filtered() {
  local pattern=$1; shift
  local log; log=$(mktemp)
  if "$@" >"$log" 2>&1; then
    grep -E "$pattern" "$log" || true
  else
    cat "$log"; exit 1
  fi
}

step "Package build (warnings are errors)"
swift build --package-path "$PKG"

step "Headless tests"
if [[ $LIVE -eq 1 ]]; then export FLOTION_LIVE_AI=1; fi
filtered "✘|Test run" swift test --package-path "$PKG" --skip FlotionPerfTests

step "Performance budgets (release build)"
filtered "PERF|✘|Test run" swift test --package-path "$PKG" -c release --filter FlotionPerfTests

if [[ $APP -eq 1 ]]; then
  step "App build"
  xcodegen generate --quiet
  xcodebuild -project Flotion.xcodeproj -scheme Flotion -configuration Debug \
    -derivedDataPath .build/xcode build -quiet
fi

if [[ $UI -eq 1 ]]; then
  step "In-app UI smoke test (runs in the background; FLOTION_FOREGROUND=1 to watch)"
  Scripts/selftest.sh .build/selftest

  step "In-app performance budgets (release build, in the background)"
  Scripts/perftest.sh .build/perftest
fi

printf '\nverify: all green\n'
