#!/usr/bin/env bash
# Fails if anything credential-shaped is tracked under relay/. Run before committing.
set -euo pipefail
cd "$(dirname "$0")/.."
pattern='(sk_[A-Za-z0-9]{20,})|(xi-api-key["'"'"']?\s*[:=]\s*["'"'"']?[A-Za-z0-9]{16,})|(Bearer\s+[A-Za-z0-9._-]{20,})'
# Test fixtures use deliberately fake keys; they are listed explicitly.
if git ls-files -co --exclude-standard . | grep -v '^Tests/' | xargs grep -nE "$pattern" 2>/dev/null; then
  echo "Possible credential found (above). Remove it before committing." >&2
  exit 1
fi
echo "OK: no credential-shaped strings outside Tests/ (test files contain only fake keys)."
