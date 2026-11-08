#!/usr/bin/env bash
# Scripted, text-only run of the warehouse training demo (no speech services, no network).
set -euo pipefail
cd "$(dirname "$0")/.."
swift build --product relay-runner >/dev/null
printf '%s\n' \
  "start" \
  "next" \
  "understood" \
  "next" \
  "What if the delivery is not on the list?" \
  "Which gloves do I need?" \
  "damage or count?" \
  "How do I handle frozen goods?" \
  "po polsku" \
  "next" \
  "Co zrobić, gdy widzę wyciek?" \
  "quit" | "$(swift build --show-bin-path)/relay-runner" warehouse
