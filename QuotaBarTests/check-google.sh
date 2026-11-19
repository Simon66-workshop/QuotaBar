#!/bin/bash
# Default: render real UsageTable with synthetic data, offscreen, without a status item.
# --live: explicitly run the official read-only agy command once; no raw output saved.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BASE="/Volumes/2T扩展盘/Agent文件/QuotaBar-GO-upgrade-20261119"
if ! mount | grep -Fq ' on /Volumes/2T扩展盘 (' || [[ "$ROOT" != "$BASE/worktree" ]]; then
  echo 'Requires the GO upgrade worktree and mounted external volume.' >&2; exit 1
fi
OUT="$BASE/candidate"
CACHE="${QUOTABAR_MODULE_CACHE:-$OUT/swift-module-cache}"
SDK="${QUOTABAR_SDK:-$(xcrun --sdk macosx --show-sdk-path)}"
mkdir -p "$CACHE"
CACHE="$(cd "$CACHE" && pwd -P)"
swiftc -parse-as-library -D QUOTABAR_COMPONENT_CHECK -target arm64-apple-macos14.0 -sdk "$SDK" -module-cache-path "$CACHE" \
  "$ROOT/QuotaBarTests/GoogleCheck.swift" "$ROOT"/QuotaBar/*.swift -o "$OUT/quotabar-google-check" \
  -framework AppKit -framework SwiftUI -framework Combine -framework UserNotifications \
  -framework Security -framework CryptoKit -framework IOKit -framework DiskArbitration -lsqlite3
"$OUT/quotabar-google-check" "$ROOT/QuotaBarTests/Fixtures/google-usage.json" "$OUT" "$@"
