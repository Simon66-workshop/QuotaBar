#!/bin/bash
# Compile and run usage, menu-bar, RAM, and panel-fit regression checks.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
OUT="${QUOTABAR_TEST_OUT:-${TMPDIR:-/tmp}/quotabar-claude-tests}"
swiftc \
  "$HERE/main.swift" \
  "$HERE/UsageSourcesStub.swift" \
  "$ROOT/QuotaBar/Models.swift" \
  "$ROOT/QuotaBar/ClaudeUsage.swift" \
  "$ROOT/QuotaBar/PanelFit.swift" \
  -o "$OUT"
"$OUT"
