#!/usr/bin/env bash
# Fails if a .env file or something that looks like a real provider key is tracked by git.
# Test keys in this repo are fake strings (e.g. "test-elevenlabs-key-SECRET-456") and do not match.
set -euo pipefail
cd "$(dirname "$0")/.."

status=0
tracked_env=$(git ls-files -- . | grep -E '(^|/)\.env(\..*)?$' | grep -v '\.env\.example$' || true)
if [ -n "$tracked_env" ]; then
  echo "Tracked .env file(s) — remove them from git:"
  echo "$tracked_env"
  status=1
fi

# Patterns: Anthropic keys start with "sk-ant-"; ElevenLabs keys commonly look like "sk_" plus 48 hex characters.
if git grep -nE 'sk-ant-[A-Za-z0-9_-]{20,}|sk_[0-9a-f]{48}' -- . ':(exclude)package-lock.json'; then
  echo "Possible API key(s) found above — remove them and rotate the key."
  status=1
fi

[ "$status" -eq 0 ] && echo "No credentials found in tracked files."
exit "$status"
