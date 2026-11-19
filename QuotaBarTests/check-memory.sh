#!/bin/bash
# Compile only the shared RAM sampler and a read-only native-tool comparison.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
OUT="${QUOTABAR_MEMORY_CHECK_OUT:-${TMPDIR:-/tmp}/quotabar-memory-check}"
CACHE="${QUOTABAR_MODULE_CACHE:-$(dirname "$OUT")/quotabar-module-cache}"
mkdir -p "$CACHE"
CACHE="$(cd "$CACHE" && pwd -P)"
swiftc -parse-as-library -target arm64-apple-macos14.0 -module-cache-path "$CACHE" \
  "$HERE/MemoryCheck.swift" \
  "$HERE/UsageSourcesStub.swift" \
  "$ROOT/QuotaBar/Models.swift" \
  "$ROOT/QuotaBar/MemoryMonitor.swift" \
  -o "$OUT"
"$OUT"
