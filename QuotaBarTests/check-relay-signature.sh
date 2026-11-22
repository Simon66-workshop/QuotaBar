#!/bin/bash
# Inspect disposable synthetic signatures; never launch or read provisioned credentials.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
VOLUME='/Volumes/2T扩展盘'
if ! /sbin/mount | grep -F " on $VOLUME (" >/dev/null ||
   [[ "$ROOT" != "$VOLUME/"* || ! -w "$ROOT/QuotaBarTests" ]] ||
   ! df -Pk "$ROOT" | awk 'NR == 2 { ok = ($4 > 262144) } END { exit !ok }'; then
    echo 'Requires this checkout on the mounted, writable external volume with >256 MiB free.' >&2
    exit 1
fi
WORK="$(mktemp -d "$ROOT/QuotaBarTests/.relay-signature.XXXXXX")"
trap 'rm -rf -- "$WORK"' EXIT
APP="$WORK/Fixture.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$ROOT/QuotaBar/Info.plist" "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c 'Set CFBundleExecutable QuotaBar' -c 'Set CFBundleIdentifier app.quotabar.mac' \
    "$APP/Contents/Info.plist"
printf 'int main(void) { return 0; }\n' > "$WORK/main.c"
cc -arch arm64 "$WORK/main.c" -o "$APP/Contents/MacOS/QuotaBar"
printf 'original\n' > "$APP/Contents/Resources/stamp"
VERIFY="$ROOT/verify-relay-signature.sh"

reject() {
    local expected="$1" output
    shift
    if output="$(bash "$VERIFY" "$APP" "$@" 2>&1)" || [[ "$output" != *"$expected"* ]]; then
        printf 'Signature gate did not reject fixture as expected: %s\n' "$output" >&2
        exit 1
    fi
}

/usr/bin/codesign --force --sign - "$APP"
reject 'Hardened Runtime is required'
/usr/bin/codesign --force --sign - --options runtime "$APP"
bash "$VERIFY" "$APP"
reject 'ad-hoc or unapproved signer' ABCDE12345

printf 'modified\n' > "$APP/Contents/Resources/stamp"
reject 'invalid bundle signature'
cat > "$WORK/entitlements.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>com.apple.security.cs.disable-library-validation</key><true/>
</dict></plist>
PLIST
/usr/bin/codesign --force --sign - --options runtime --entitlements "$WORK/entitlements.plist" "$APP"
reject 'entitlements are not permitted'
echo 'AUDIT_APP_03=PASS · hardened local signature accepted; non-runtime, ad-hoc ACL, tampering and library-validation exception rejected'
