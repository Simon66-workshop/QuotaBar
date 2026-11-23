#!/bin/bash
# Double-click this file. Do not open the .xcodeproj.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
SRC="$HERE/QuotaBar"
APP="$HOME/Applications/QuotaBar.app"
BIN="$APP/Contents/MacOS/QuotaBar"
STAMP="$APP/Contents/Resources/.sourcesha"
LOG="$HOME/Library/Logs/QuotaBar-build.log"

CHECK_BUILD=0
case "$#:${1:-}" in
  0:) ;;
  1:--check-build) CHECK_BUILD=1 ;;
  *) echo 'Usage: Start QuotaBar.command [--check-build]' >&2; exit 2 ;;
esac

WORK=
REPLACED=0
cleanup() {
  [[ -n "$WORK" ]] || return 0
  if [[ "$REPLACED" = 0 && ( -e "$WORK/previous.app" || -L "$WORK/previous.app" ) ]]; then
    if [[ -e "$APP" || -L "$APP" ]] || ! /bin/mv -h "$WORK/previous.app" "$APP"; then
      printf 'Could not restore the previous app; it is preserved at %s/previous.app\n' "$WORK" >&2
      return 0
    fi
  fi
  rm -rf -- "$WORK"
}
probe_sdk() {
  [[ -d "$1" ]] || return 1
  swiftc -typecheck -target arm64-apple-macos14.0 -sdk "$1" \
    -module-cache-path "$WORK/probe-cache" "$WORK/SDKProbe.swift"
}

select_sdk() {
  local default_sdk fallback_sdk
  # Importing SwiftUI alone won't check that the @State macro can expand.
  cat > "$WORK/SDKProbe.swift" <<'SWIFT'
import SwiftUI
struct QuotaBarSDKProbe: View {
    @State private var enabled = false
    var body: some View { Toggle("Probe", isOn: $enabled) }
}
SWIFT
  if [[ -n "${QUOTABAR_SDK:-}" ]]; then
    SDK="$QUOTABAR_SDK"
    if ! probe_sdk "$SDK"; then
      echo 'QUOTABAR_SDK is not usable with this swiftc; set it to a compatible installed SDK. No app was replaced or stopped.' >&2
      return 1
    fi
  else
    default_sdk="$(xcrun --sdk macosx --show-sdk-path)" || default_sdk=
    if probe_sdk "$default_sdk"; then
      SDK="$default_sdk"
    else
      echo 'Default macOS SDK failed the SwiftUI compiler check; looking for the installed macOS 26.5 SDK.' >&2
      fallback_sdk="$(xcrun --sdk macosx26.5 --show-sdk-path)" || fallback_sdk=
      if [[ "$fallback_sdk" == "$default_sdk" ]] || ! probe_sdk "$fallback_sdk"; then
        echo 'No compatible macOS SDK passed the SwiftUI check. Set QUOTABAR_SDK to a compatible installed SDK. No app was replaced or stopped.' >&2
        return 1
      fi
      SDK="$fallback_sdk"
    fi
  fi
  printf 'QuotaBar build SDK: %s\n' "$SDK"
}

build_candidate() {
  local candidate="$1"
  local binary="$candidate/Contents/MacOS/QuotaBar"
  select_sdk
  mkdir -p "$candidate/Contents/MacOS" "$candidate/Contents/Resources"
  cat > "$candidate/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleIdentifier</key>
  <string>app.quotabar.mac</string>
  <key>CFBundleName</key>
  <string>QuotaBar</string>
  <key>CFBundleExecutable</key>
  <string>QuotaBar</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>CFBundleVersion</key>
  <string>41</string>
  <key>CFBundleShortVersionString</key>
  <string>1.8.28</string>
  <key>LSUIElement</key>
  <true/>
  <key>LSMinimumSystemVersion</key>
  <string>14.0</string>
  <key>NSHighResolutionCapable</key>
  <true/>
  <key>NSUserNotificationAlertStyle</key>
  <string>alert</string>
</dict>
</plist>
PLIST
  echo -n 'APPL????' > "$candidate/Contents/PkgInfo"

  if ! swiftc -parse-as-library -O -target arm64-apple-macos14.0 -sdk "$SDK" \
    -module-cache-path "$WORK/build-cache" \
    "$SRC/QuotaBarApp.swift" \
    "$SRC/Models.swift" \
    "$SRC/ClaudeUsage.swift" \
    "$SRC/GoogleUsage.swift" \
    "$SRC/TokenReader.swift" \
    "$SRC/ClaudeDesktop.swift" \
    "$SRC/UsageClient.swift" \
    "$SRC/UsageStore.swift" \
    "$SRC/UsageSource.swift" \
    "$SRC/PanelFit.swift" \
    "$SRC/RelayStatusModels.swift" \
    "$SRC/RelayStatusClient.swift" \
    "$SRC/RelayStatusKeychain.swift" \
    "$SRC/RelayStatusStore.swift" \
    "$SRC/RelayStatusSection.swift" \
    "$SRC/MenuPanel.swift" \
    "$SRC/GrokDeviceAuth.swift" \
    "$SRC/DiskMonitor.swift" \
    "$SRC/MemoryMonitor.swift" \
    -o "$binary" \
    -framework AppKit \
    -framework SwiftUI \
    -framework Combine \
    -framework UserNotifications \
    -framework Security \
    -framework CryptoKit \
    -framework IOKit \
    -framework DiskArbitration \
    -lsqlite3; then
    echo 'QuotaBar compilation failed. No app was replaced or stopped.' >&2
    return 1
  fi
  chmod +x "$binary"
  echo "$SHA" > "$candidate/Contents/Resources/.sourcesha"
  # Local builds are hardened but ad-hoc. The separate relay ACL gate
  # requires an approved Apple signing identity before trusting the binary.
  /usr/bin/codesign --force --sign - --options runtime "$candidate"
  /bin/bash "$HERE/verify-relay-signature.sh" "$candidate"
}

main() {
  trap cleanup EXIT
  trap 'exit 130' INT
  trap 'exit 143' TERM
  if ! command -v swiftc >/dev/null 2>&1; then
    if [[ "$CHECK_BUILD" = 1 ]]; then
      echo 'Swift compiler not found; no tools or app were installed.' >&2
      exit 1
    fi
    osascript -e 'display dialog "第一次需要安装 Apple Command Line Tools（不是 Xcode 应用，大约几分钟）。点确定后按系统提示安装，装完再双击本文件。" buttons {"好"} default button 1 with title "QuotaBar"'
    xcode-select --install || true
    exit 0
  fi

  SHA="$(cat "$SRC"/*.swift "$HERE/Start QuotaBar.command" "$HERE/verify-relay-signature.sh" | shasum -a 256 | awk '{print $1}')"
  if [[ "$CHECK_BUILD" = 1 ]]; then
    WORK="$(mktemp -d "${TMPDIR:-/tmp}/quotabar-build.XXXXXX")"
    build_candidate "$WORK/QuotaBar.app"
    echo 'QUOTABAR_CHECK_BUILD=PASS · signed candidate verified; no install, stop, or launch'
    exit 0
  fi

  OLD="$(cat "$STAMP" 2>/dev/null || true)"
  if [[ ! -x "$BIN" || "$SHA" != "$OLD" ]] || ! /bin/bash "$HERE/verify-relay-signature.sh" "$APP"; then
    osascript -e 'display notification "正在编译 QuotaBar 1.8.28…" with title "QuotaBar"' || true
    mkdir -p "$(dirname "$APP")"
    # Keep both moves on the install volume; never build into the installed bundle.
    WORK="$(mktemp -d "$(dirname "$APP")/.quotabar-build.XXXXXX")"
    CANDIDATE="$WORK/QuotaBar.app"
    build_candidate "$CANDIDATE"
    if [[ -e "$APP" || -L "$APP" ]]; then
      /bin/mv -h "$APP" "$WORK/previous.app"
    fi
    /bin/mv -h "$CANDIDATE" "$APP"
    REPLACED=1
  fi

  xattr -dr com.apple.quarantine "$APP" "$HERE" 2>/dev/null || true
  pkill -x QuotaBar 2>/dev/null || true
  sleep 0.2
  open "$APP"

  osascript -e 'display notification "已出现在屏幕右上角 · G 为共享池 · Claude / Codex / 磁盘照常" with title "QuotaBar 1.8.28"' || true

  tty -s && osascript <<'EOF' || true
tell application "Terminal"
  if (count of windows) > 0 then close front window
end tell
EOF
}

if [[ "$CHECK_BUILD" = 0 ]]; then
  mkdir -p "$(dirname "$LOG")"
  main 2>&1 | tee -a "$LOG"
else
  main
fi
