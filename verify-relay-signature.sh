#!/bin/bash
# Verify on disk only; never launches the executable or provisions a credential.
set -euo pipefail
export LC_ALL=C

fail() { printf 'QuotaBar signature check: %s\n' "$1" >&2; exit 1; }
[[ $# -eq 1 || $# -eq 2 ]] || fail 'expected APP_PATH [approved TEAM_ID]'
APP="$1"
BIN="$APP/Contents/MacOS/QuotaBar"
[[ "$APP" = /* && -f "$BIN" && ! -L "$BIN" ]] || fail 'missing regular app executable'
[[ "$(/usr/bin/lipo -archs "$BIN" 2>/dev/null)" == arm64 ]] || fail 'expected the arm64-only build'
PLIST="$APP/Contents/Info.plist"
[[ "$(/usr/libexec/PlistBuddy -c 'Print CFBundleExecutable' "$PLIST" 2>/dev/null)" == QuotaBar &&
   "$(/usr/libexec/PlistBuddy -c 'Print CFBundleIdentifier' "$PLIST" 2>/dev/null)" == app.quotabar.mac ]] ||
  fail 'unexpected bundle executable or identifier'
/usr/bin/codesign --verify --strict "$APP" 2>/dev/null || fail 'invalid bundle signature'

# Check the exact Mach-O that runs as the Keychain reader, not just its wrapper.
DETAILS="$(/usr/bin/codesign --display --verbose=4 "$BIN" 2>&1)" || fail 'cannot inspect executable signature'
FLAGS=$'\n''CodeDirectory v=[[:digit:]]+ size=[[:digit:]]+ flags=0x([[:xdigit:]]+)\('
[[ "$DETAILS" =~ $FLAGS ]] && (( (16#${BASH_REMATCH[1]} & 0x10000) != 0 )) ||
  fail 'Hardened Runtime is required'
# With Hardened Runtime and no entitlements, there is no library-validation
# exception, debug attachment allowance, or opt-in for DYLD environment variables.
XML="$(/usr/bin/codesign --display --entitlements - "$BIN" 2>/dev/null)" || fail 'cannot inspect XML entitlements'
DER="$(/usr/bin/codesign --display --entitlements - --der "$BIN" 2>/dev/null | /usr/bin/wc -c)" ||
  fail 'cannot inspect DER entitlements'
[[ -z "$XML" && "$DER" -eq 0 ]] || fail 'entitlements are not permitted'

if [[ $# -eq 2 ]]; then
  TEAM="$2"
  [[ "$TEAM" =~ ^[A-Z0-9]{10}$ ]] || fail 'expected an approved Apple signing Team ID'
  [[ "$DETAILS"$'\n' == *$'\n'"TeamIdentifier=$TEAM"$'\n'* ]] ||
    fail 'ad-hoc or unapproved signer; do not grant Keychain access'
  RULE="anchor apple generic and identifier \"app.quotabar.mac\" and certificate leaf[subject.OU] = \"$TEAM\""
  /usr/bin/codesign --verify --strict -R "$RULE" "$BIN" 2>/dev/null ||
    fail 'signer or executable identity did not verify; do not grant Keychain access'
  echo 'QuotaBar relay ACL signature check: PASS for approved Team ID'
fi
