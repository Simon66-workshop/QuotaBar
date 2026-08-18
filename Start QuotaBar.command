#!/bin/bash
# Double-click this file. Do not open the .xcodeproj.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
SRC="$HERE/QuotaBar"
APP="$HOME/Applications/QuotaBar.app"
BIN="$APP/Contents/MacOS/QuotaBar"
STAMP="$APP/Contents/Resources/.sourcesha"
LOG="$HOME/Library/Logs/QuotaBar-build.log"

mkdir -p "$(dirname "$LOG")"
exec > >(tee -a "$LOG") 2>&1

need_tools() {
  if command -v swiftc >/dev/null 2>&1; then
    return 1
  fi
  return 0
}

if need_tools; then
  osascript -e 'display dialog "第一次需要安装 Apple Command Line Tools（不是 Xcode 应用，大约几分钟）。点确定后按系统提示安装，装完再双击本文件。" buttons {"好"} default button 1 with title "QuotaBar"'
  xcode-select --install || true
  exit 0
fi

mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cat > "$APP/Contents/Info.plist" <<'PLIST'
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
  <string>11</string>
  <key>CFBundleShortVersionString</key>
  <string>1.7</string>
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
echo -n 'APPL????' > "$APP/Contents/PkgInfo"

SHA="$(cat "$SRC"/*.swift | shasum -a 256 | awk '{print $1}')"
OLD="$(cat "$STAMP" 2>/dev/null || true)"
if [[ ! -x "$BIN" || "$SHA" != "$OLD" ]]; then
  osascript -e 'display notification "正在编译 QuotaBar 1.7…" with title "QuotaBar"'
  pkill -x QuotaBar 2>/dev/null || true
  sleep 0.3
  swiftc -parse-as-library -O \
    "$SRC/QuotaBarApp.swift" \
    "$SRC/Models.swift" \
    "$SRC/TokenReader.swift" \
    "$SRC/UsageClient.swift" \
    "$SRC/UsageStore.swift" \
    "$SRC/UsageSource.swift" \
    "$SRC/MenuPanel.swift" \
    "$SRC/GrokDeviceAuth.swift" \
    "$SRC/DiskMonitor.swift" \
    -o "$BIN" \
    -framework AppKit \
    -framework SwiftUI \
    -framework Combine \
    -framework UserNotifications \
    -framework Security \
    -framework CryptoKit \
    -framework IOKit \
    -framework DiskArbitration \
    -lsqlite3
  chmod +x "$BIN"
  echo "$SHA" > "$STAMP"
fi

xattr -dr com.apple.quarantine "$APP" "$HERE" 2>/dev/null || true
pkill -x QuotaBar 2>/dev/null || true
sleep 0.2
open "$APP"

osascript -e 'display notification "已出现在屏幕右上角 · 只显示已连接服务 · 左键面板 · 右键短菜单" with title "QuotaBar 1.7"' || true

tty -s && osascript <<'EOF' || true
tell application "Terminal"
  if (count of windows) > 0 then close front window
end tell
EOF
exit 0
