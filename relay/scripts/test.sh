#!/usr/bin/env bash
# Builds and tests the platform-independent parts (RelayCore, RelayAdapters, relay-runner); on macOS
# `swift build` also compiles the SwiftUI app target. Testing only: no Relay.app is packaged
# (scripts/build-app.sh does that). Three stages: source build, test compilation, test run.
# Exit status: 0 pass, 1 tests failed or did not complete, 2 a build stage failed (tests not run).
# Works from any directory, on macOS (needs Xcode's XCTest) and Linux.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT" || exit 1

bash "$ROOT/scripts/check-prereqs.sh" --tests || exit 1

mkdir -p "$ROOT/.build"
LOG="$ROOT/.build/test.log"
: > "$LOG"
# Three stages, so a failure says what failed: the package's own sources, the test targets, or the tests.
run_stage() {
  local label="$1"; shift
  echo "== $label: $* =="
  echo "\$ $*" >> "$LOG"
  "$@" 2>&1 | tee -a "$LOG"
  return "${PIPESTATUS[0]}"
}
first_errors() { grep -E '(error|fatal error):' "$LOG" | sort -u | head -10 | sed 's/^/    /'; }
echo "Full output also in $LOG"
if ! run_stage "1/3 Source build" swift build; then
  echo
  echo "Tests did NOT run: the package's own sources failed to compile (libraries or app, not the tests)."
  echo "Nothing was launched, so this is not an app crash. First errors:"
  first_errors
  echo "Result: FAIL (source build)"
  exit 2
fi
if ! run_stage "2/3 Test compilation" swift build --build-tests; then
  echo
  if grep -q "no such module 'XCTest'" "$LOG"; then
    echo "Tests did NOT run: the test targets could not be compiled because XCTest is missing from the selected"
    echo "developer tools (usually Command Line Tools instead of Xcode). This is a toolchain problem, not an app crash."
    echo "Run: bash $ROOT/scripts/check-prereqs.sh --tests   for the exact fix."
  else
    echo "Tests did NOT run: the test targets failed to compile. Nothing was launched, so this is not an app crash."
    echo "First errors:"
    first_errors
  fi
  echo "Result: FAIL (test compilation)"
  exit 2
fi
run_stage "3/3 Test run" swift test --skip-build
status=$?

echo
summary="$(grep -E 'Executed [0-9]+ tests?, with' "$LOG" | tail -1)"
if [[ -n "$summary" ]]; then
  run="$(sed -nE 's/.*Executed ([0-9]+) tests?.*/\1/p' <<<"$summary")"
  skipped="$(sed -nE 's/.* with ([0-9]+) tests? skipped.*/\1/p' <<<"$summary")"
  failed="$(sed -nE 's/.* and ([0-9]+) failures?.*/\1/p; s/.*, with ([0-9]+) failures?.*/\1/p' <<<"$summary" | head -1)"
  echo "Tests: ${run} run, ${skipped:-0} skipped, ${failed:-?} failed."
else
  echo "Tests did NOT run to completion (exit status $status before results were reported)."
  echo "See the first 'error:' lines in $LOG."
fi

if [[ $status -eq 0 ]]; then echo "OK: build and tests passed on $(uname -s)"; else echo "Result: FAIL (exit status $status)"; fi
exit $status
