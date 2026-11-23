#!/bin/bash
# Compile and render synthetic data. Never loads a real Keychain or network provider.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
VOLUME='/Volumes/2T扩展盘'
if ! /sbin/mount | grep -F " on $VOLUME (" >/dev/null ||
   [[ "$ROOT" != "$VOLUME/"* || ! -w "$ROOT/QuotaBarTests" ]] ||
   ! df -Pk "$ROOT" | awk 'NR == 2 { ok = ($4 > 262144) } END { exit !ok }'; then
    echo 'Requires this checkout on the mounted, writable external volume with >256 MiB free.' >&2
    exit 1
fi
WORK="$(mktemp -d "${QUOTABAR_TEST_TMPDIR:-$ROOT/QuotaBarTests}/.relay-check.XXXXXX")"
trap 'rm -rf -- "$WORK"' EXIT
OUT="${QUOTABAR_RELAY_PREVIEWS:-$ROOT/QuotaBarTests/Previews}"
SDK="${QUOTABAR_SDK:-$(xcrun --sdk macosx --show-sdk-path)}"
mkdir -p "$OUT" "$WORK/cache" "$WORK/previews"
swiftc -parse-as-library -D QUOTABAR_COMPONENT_CHECK -target arm64-apple-macos14.0 \
    -sdk "$SDK" -module-cache-path "$WORK/cache" \
    "$ROOT/QuotaBarTests/RelayStatusCheck.swift" "$ROOT"/QuotaBar/*.swift -o "$WORK/relay-check" \
    -framework AppKit -framework SwiftUI -framework Combine -framework UserNotifications \
    -framework Security -framework CryptoKit -framework IOKit -framework DiskArbitration -lsqlite3
TZ=America/New_York "$WORK/relay-check" time > "$WORK/New_York.txt"
TZ=UTC "$WORK/relay-check" time > "$WORK/UTC.txt"
diff -u "$WORK/New_York.txt" "$WORK/UTC.txt"
printf 'SHANGHAI_TIME=PASS · TZ=America/New_York and TZ=UTC: '
cat "$WORK/UTC.txt"
"$WORK/relay-check" check "$ROOT" "$WORK/previews"
# Publish only after validation; default work and preview paths share a volume.
for preview in "$WORK"/previews/relay-*.png; do
    mv -f -- "$preview" "$OUT/"
done
printf 'PREVIEWS=%s\n' "$OUT"
