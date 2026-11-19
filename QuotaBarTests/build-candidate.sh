#!/bin/bash
# Local Mini1 candidate only. Never installs, quits, signs, or opens an app.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BASE="/Volumes/2T扩展盘/Agent文件/QuotaBar-GO-upgrade-20261119"
if ! mount | grep -Fq ' on /Volumes/2T扩展盘 ('; then
  echo 'Required external volume is not mounted.' >&2; exit 1
fi
if [[ "$ROOT" != "$BASE/worktree" ]]; then
  echo 'Candidate build is restricted to the GO upgrade worktree.' >&2; exit 1
fi
APP="$BASE/candidate/QuotaBar.app"
CACHE="${QUOTABAR_MODULE_CACHE:-$BASE/candidate/swift-module-cache}"
SDK="${QUOTABAR_SDK:-$(xcrun --sdk macosx --show-sdk-path)}"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$CACHE"
CACHE="$(cd "$CACHE" && pwd -P)"
cp "$ROOT/QuotaBar/Info.plist" "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c 'Set :CFBundleExecutable QuotaBar' "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c 'Set :CFBundleIdentifier app.quotabar.mac' "$APP/Contents/Info.plist"
printf 'APPL????' > "$APP/Contents/PkgInfo"
swiftc -parse-as-library -O -target arm64-apple-macos14.0 -sdk "$SDK" -module-cache-path "$CACHE" \
  "$ROOT"/QuotaBar/*.swift -o "$APP/Contents/MacOS/QuotaBar" \
  -framework AppKit -framework SwiftUI -framework Combine -framework UserNotifications \
  -framework Security -framework CryptoKit -framework IOKit -framework DiskArbitration -lsqlite3
echo "Candidate built (NOT launched): $APP"
