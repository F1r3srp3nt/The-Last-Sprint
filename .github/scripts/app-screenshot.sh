#!/bin/bash
# Launches a macOS app bundle, captures its main window to a PNG, then stops the app.
# Used by CI only. Usage: app-screenshot.sh <App.app> <out.png> [arguments for the app...]
# Needs WINDOW_ID set to a compiled .github/scripts/window-id.swift.
set -euo pipefail
app="$1"; out="$2"; shift 2
name="$(basename "$app" .app)"
exe="$app/Contents/MacOS/$name"

# No window restoration, so every launch starts from the same state.
"$exe" -ApplePersistenceIgnoreState YES "$@" >/dev/null 2>&1 &
pid=$!
stop() { kill "$pid" 2>/dev/null || true; wait "$pid" 2>/dev/null || true; }
trap stop EXIT

window=""
for _ in $(seq 1 60); do
  if window="$("$WINDOW_ID" "$pid")"; then break; fi
  window=""
  sleep 0.5
done
if [[ -z "$window" ]]; then
  echo "No window from $name after 30 s; capturing the whole screen instead." >&2
  sleep 2
  screencapture -x "$out"
else
  sleep "${SETTLE_SECONDS:-4}"   # let the first layout, the demo and any comparison finish
  screencapture -x -o -l "$window" "$out"
fi
printf '%s: %s\n' "$out" "$(sips -g pixelWidth -g pixelHeight "$out" | awk '/pixel/ {printf "%s ", $2}')"
