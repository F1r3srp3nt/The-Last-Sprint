#!/usr/bin/env bash
# One command: package build/Relay.app, then open exactly that new copy. Works from any directory.
#
# Usage: bash relay/scripts/run-latest.sh           # package and open (no tests)
#        bash relay/scripts/run-latest.sh --test    # run the tests first; stop if they fail
#
# Nothing is opened unless every earlier step succeeded. `open` only brings an already-running Relay to
# the front, so a running copy (same bundle identifier) is asked to quit first. Nothing is deleted:
# other copies of Relay.app, preferences and the Keychain item stay where they are.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUNDLE_ID="com.oslosprint.relay"
APP="$ROOT/build/Relay.app"
EXE="$APP/Contents/MacOS/Relay"
# True while this exact copy is running (fixed-string match on the Relay processes only).
this_copy_running() {
  local pid
  for pid in $(pgrep -x Relay 2>/dev/null); do
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
bash "$ROOT/scripts/build-app.sh"

echo "== 3/3 Open"
if pgrep -x Relay >/dev/null 2>&1; then
  echo "Asking the running Relay to quit…"
  osascript -e "tell application id \"$BUNDLE_ID\" to quit" || true
  for _ in $(seq 1 40); do
    pgrep -x Relay >/dev/null 2>&1 || break
    sleep 0.5
  done
  if pgrep -x Relay >/dev/null 2>&1; then
    echo "Relay is still running. Not launching a second copy." >&2
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
  echo "Relay was opened but is not running. It may have crashed at launch." >&2
  echo "Look for a Relay report in Console › Crash Reports (~/Library/Logs/DiagnosticReports)." >&2
  exit 1
fi
