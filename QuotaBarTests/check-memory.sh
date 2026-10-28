#!/bin/bash
# Compile only the shared RAM sampler and a read-only native-tool comparison.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
OUT="${QUOTABAR_MEMORY_CHECK_OUT:-${TMPDIR:-/tmp}/quotabar-memory-check}"
swiftc -parse-as-library -target arm64-apple-macos14.0 \
  "$HERE/MemoryCheck.swift" \
  "$HERE/UsageSourcesStub.swift" \
  "$ROOT/QuotaBar/Models.swift" \
  "$ROOT/QuotaBar/MemoryMonitor.swift" \
  -o "$OUT"
"$OUT"
