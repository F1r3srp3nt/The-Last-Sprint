#!/bin/bash
# In-app launch check for a packaged macOS app, used by CI after launch-check.sh. launch-check.sh shows
# the process starts and keeps running; this asks the running app itself what it loaded. The app is
# opened with --self-check <file>; about 3 s after launch it writes its bundle identifier, the commit
# read from its Info.plist, its visible windows and bundled resources to that file, then quits.
#
# Usage: self-check.sh <App.app> [timeout seconds, default 60]
set -uo pipefail
app="$(cd "$(dirname "$1")" && pwd)/$(basename "$1")"
timeout="${2:-60}"
plist="$app/Contents/Info.plist"
report="$(mktemp -d)/self-check.json"
fail() { echo "SELF-CHECK FAILED: $*" >&2; exit 1; }

[[ -d "$app" ]] || fail "$app does not exist (packaging did not produce it)."
exe_name="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$plist")"
exe="$app/Contents/MacOS/$exe_name"
bundle_id="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$plist")"
commit_key="$(plutil -convert json -o - "$plist" | python3 -c 'import json,sys; print(next((k for k in json.load(sys.stdin) if k.endswith("GitCommit")), ""))')"
expected_commit="$([[ -n "$commit_key" ]] && /usr/libexec/PlistBuddy -c "Print :$commit_key" "$plist")"

open -n "$app" --args -ApplePersistenceIgnoreState YES --self-check "$report" || fail "open returned an error."
for _ in $(seq 1 "$timeout"); do [[ -s "$report" ]] && break; sleep 1; done
stop() { pkill -f -- "$exe" 2>/dev/null || true; }
[[ -s "$report" ]] || { stop; fail "$exe_name wrote no report within $timeout s (it did not start, exited, or hung)."; }
sleep 2; stop
echo "Report written by the running app:"
cat "$report"; echo

field() { plutil -extract "$1" raw -o - "$report" 2>/dev/null; }
problems=0
check() {
  if [[ "$2" == "$3" ]]; then echo "  ok    $1: $2"; else echo "  FAIL  $1: got '$2', expected '$3'"; problems=$((problems + 1)); fi
}
check "bundle identifier" "$(field bundleIdentifier)" "$bundle_id"
check "bundle path" "$(field bundlePath)" "$app"
check "executable" "$(field executable)" "$exe_name"
[[ -n "$commit_key" ]] && check "commit read from Info.plist ($commit_key)" "$(field commit)" "$expected_commit"
windows="$(field visibleWindows)"
if [[ "${windows:-0}" -ge 1 ]]; then echo "  ok    visible windows: $windows"; else echo "  FAIL  visible windows: ${windows:-none}"; problems=$((problems + 1)); fi
[[ $problems -eq 0 ]] || fail "$problems check(s) did not match."
echo "PASS: $exe_name started from $app, showed a window and read its own Info.plist."
