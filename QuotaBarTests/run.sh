#!/bin/bash
# Compile and run usage, menu-bar, RAM, and panel-fit regression checks.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
OUT="${QUOTABAR_TEST_OUT:-${TMPDIR:-/tmp}/quotabar-claude-tests}"
CACHE="${QUOTABAR_MODULE_CACHE:-$(dirname "$OUT")/quotabar-module-cache}"
mkdir -p "$CACHE"
CACHE="$(cd "$CACHE" && pwd -P)"
swiftc -module-cache-path "$CACHE" \
  "$HERE/main.swift" \
  "$HERE/UsageSourcesStub.swift" \
  "$HERE/GoogleChecks.swift" \
  "$ROOT/QuotaBar/Models.swift" \
  "$ROOT/QuotaBar/GoogleUsage.swift" \
  "$ROOT/QuotaBar/ClaudeUsage.swift" \
  "$ROOT/QuotaBar/PanelFit.swift" \
  -o "$OUT"
"$OUT" "$HERE/Fixtures/google-usage.json"
