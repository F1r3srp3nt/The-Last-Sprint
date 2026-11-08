#!/bin/bash
# Launch verification for a packaged macOS app, used by CI. Separate from the build: a bundle that
# compiled and signed can still crash at launch, and this is what tells the two apart.
#
# Usage: launch-check.sh <App.app> [seconds to stay running, default 8]
#
# 1. Checks the bundle: Info.plist parses, CFBundleExecutable exists and is executable, signature verifies.
# 2. Opens it with `open` (LaunchServices, as a person would), waits for the process, and requires it to
#    still be running after the given time, with no new crash report for it.
# 3. Stops it with SIGTERM (no Apple Events, so no automation prompt on the runner).
set -uo pipefail
app="$(cd "$(dirname "$1")" && pwd)/$(basename "$1")"
stay="${2:-8}"
plist="$app/Contents/Info.plist"
fail() { echo "LAUNCH CHECK FAILED: $*" >&2; exit 1; }

[[ -d "$app" ]] || fail "$app does not exist (packaging did not produce it)."
plutil -lint "$plist" >/dev/null || fail "Info.plist does not parse."
exe_name="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$plist")"
exe="$app/Contents/MacOS/$exe_name"
[[ -x "$exe" ]] || fail "CFBundleExecutable $exe_name is missing or not executable."
codesign --verify --strict "$app" || fail "codesign --verify failed."
echo "Bundle: $app"
for key in CFBundleIdentifier CFBundleShortVersionString CFBundleVersion LSMinimumSystemVersion; do
  printf '  %-28s %s\n' "$key" "$(/usr/libexec/PlistBuddy -c "Print :$key" "$plist" 2>/dev/null)"
done
echo "  architectures                $(lipo -archs "$exe" 2>/dev/null)"

reports="$HOME/Library/Logs/DiagnosticReports"
marker="$(mktemp)"
pid=""
find_pid() {
  local p
  for p in $(pgrep -x "$exe_name" 2>/dev/null); do
    ps -o command= -p "$p" | grep -Fq -- "$exe" && { echo "$p"; return 0; }
  done
  return 1
}

open "$app" || fail "open returned an error."
for _ in $(seq 1 30); do pid="$(find_pid)" && break; sleep 0.5; done
[[ -n "$pid" ]] || fail "$exe_name did not start within 15 s."
echo "Started: pid $pid"
sleep "$stay"
crash="$(find "$reports" -newer "$marker" -iname "*${exe_name}*" 2>/dev/null | head -1)"
if ! kill -0 "$pid" 2>/dev/null; then
  [[ -n "$crash" ]] && { echo "Crash report: $crash"; head -40 "$crash"; }
  fail "$exe_name exited within $stay s of launch."
fi
[[ -z "$crash" ]] || { echo "Crash report: $crash"; head -40 "$crash"; fail "a crash report for $exe_name appeared."; }
echo "PASS: $exe_name launched with open and was still running after $stay s; no crash report."
kill "$pid" 2>/dev/null
for _ in $(seq 1 20); do kill -0 "$pid" 2>/dev/null || break; sleep 0.25; done
kill -9 "$pid" 2>/dev/null || true
rm -f "$marker"
