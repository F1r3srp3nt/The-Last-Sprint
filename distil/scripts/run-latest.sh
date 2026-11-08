#!/bin/bash
# One command: package dist/Distil.app, then open exactly that new copy. Works from any directory.
#
# Usage: bash distil/scripts/run-latest.sh           # package and open (no tests)
#        bash distil/scripts/run-latest.sh --test    # run the tests first; stop if they fail
#
# Nothing is opened unless every earlier step succeeded. `open` only brings an already-running Distil to
# the front, so a running copy (same bundle identifier, including older "Token Lab" builds) is asked to
# quit first, through the app's normal unsaved-changes prompt. If that quit is cancelled, this script
# stops without launching a second copy.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUNDLE_ID="dev.tokenlab.prototype"
APP="$ROOT/dist/Distil.app"
EXE="$APP/Contents/MacOS/Distil"
# True while this exact copy is running (fixed-string match, so any folder name is safe).
this_copy_running() {
  local pid
  for pid in $(pgrep -x Distil 2>/dev/null); do
    ps -o command= -p "$pid" | grep -Fq -- "$EXE" && return 0
  done
  return 1
}

if [[ "${1:-}" == "--test" ]]; then
  echo "== 1/3 Tests"
  bash "$ROOT/scripts/test.sh"
else
  echo "== 1/3 Tests: not run (pass --test to run them first)"
fi

echo "== 2/3 Package"
bash "$ROOT/scripts/build-macos.sh"

echo "== 3/3 Open"
if pgrep -f "/Contents/MacOS/(Distil|TokenLab)$" >/dev/null 2>&1; then
  echo "Asking the running Distil to quit…"
  osascript -e "tell application id \"$BUNDLE_ID\" to quit" || true
  for _ in $(seq 1 60); do
    pgrep -f "/Contents/MacOS/(Distil|TokenLab)$" >/dev/null 2>&1 || break
    sleep 0.5
  done
  if pgrep -f "/Contents/MacOS/(Distil|TokenLab)$" >/dev/null 2>&1; then
    echo "Distil is still running (quit was cancelled or is waiting for you). Not launching a second copy." >&2
    exit 1
  fi
fi

open "$APP"
for _ in $(seq 1 20); do
  this_copy_running && break
  sleep 0.5
done
sleep 2
if this_copy_running; then
  echo "Running: $APP"
  echo "The sidebar's Build card and Settings › About this build show the commit and build time."
else
  echo "Distil was opened but is not running. It may have crashed at launch." >&2
  echo "Look for a Distil report in Console › Crash Reports (~/Library/Logs/DiagnosticReports)." >&2
  exit 1
fi
