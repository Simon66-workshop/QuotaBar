#!/bin/bash
# Compile and run the Claude AC / AT / AF parser checks.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
OUT="${TMPDIR:-/tmp}/quotabar-claude-tests"
swiftc \
  "$HERE/main.swift" \
  "$HERE/UsageSourcesStub.swift" \
  "$ROOT/QuotaBar/Models.swift" \
  "$ROOT/QuotaBar/ClaudeUsage.swift" \
  -o "$OUT"
"$OUT"
