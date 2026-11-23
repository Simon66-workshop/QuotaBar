#!/bin/bash
# Exercise the production rebuild branch on a disposable fake home, then
# compile/sign/verify a real candidate without installing or running it.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/quotabar-launcher-check.XXXXXX")"
trap 'rm -rf -- "$WORK"' EXIT
LAUNCHER="$ROOT/Start QuotaBar.command"
mkdir -p "$WORK"/{lifecycle,compiler,default-sdk,fallback-sdk,override-sdk}

cat > "$WORK/lifecycle/blocked" <<'STUB'
#!/bin/bash
printf '%s\n' "${0##*/}" >> "$QUOTABAR_TEST_TRACE"
exit 99
STUB
for tool in pkill open xattr xcode-select; do
  ln -s blocked "$WORK/lifecycle/$tool"
done
cat > "$WORK/lifecycle/osascript" <<'STUB'
#!/bin/bash
if [[ "$QUOTABAR_TEST_NORMAL" = 1 && "$2" == *'正在编译 QuotaBar'* ]]; then
  exit 0
fi
printf 'osascript\n' >> "$QUOTABAR_TEST_TRACE"
exit 99
STUB
cat > "$WORK/compiler/xcrun" <<'STUB'
#!/bin/bash
case "$2" in
  macosx) echo "$QUOTABAR_TEST_WORK/default-sdk" ;;
  macosx26.5) echo "$QUOTABAR_TEST_WORK/fallback-sdk" ;;
  *) exit 98 ;;
esac
STUB
cat > "$WORK/compiler/swiftc" <<'STUB'
#!/bin/bash
mode="$1"
while [[ $# -gt 1 && "$1" != -sdk ]]; do shift; done
[[ "$1" = -sdk ]] || exit 98
sdk="${2##*/}"
case "$mode" in
  -typecheck)
    printf 'probe %s\n' "$sdk" >> "$QUOTABAR_TEST_TRACE"
    [[ "$sdk" != default-sdk && "$QUOTABAR_TEST_REJECT" != 1 ]] ;;
  -parse-as-library)
    printf 'compile %s\n' "$sdk" >> "$QUOTABAR_TEST_TRACE"
    exit 42 ;;
  *) exit 98 ;;
esac
STUB
chmod +x "$WORK"/lifecycle/{blocked,osascript} "$WORK"/compiler/{xcrun,swiftc}

OLD="$WORK/home/Applications/QuotaBar.app"
mkdir -p "$OLD/Contents/MacOS" "$OLD/Contents/Resources"
printf 'old executable fixture\n' > "$OLD/Contents/MacOS/QuotaBar"
chmod +x "$OLD/Contents/MacOS/QuotaBar"
printf 'old plist fixture\n' > "$OLD/Contents/Info.plist"
printf 'old stamp fixture\n' > "$OLD/Contents/Resources/.sourcesha"
cp -R "$OLD" "$WORK/original.app"

expect_failure() {
  local message="$1" expected_trace="$2" sdk="$3" reject="$4" output
  : > "$WORK/trace"
  if output="$(HOME="$WORK/home" QUOTABAR_SDK="$sdk" QUOTABAR_TEST_REJECT="$reject" \
      QUOTABAR_TEST_NORMAL=1 QUOTABAR_TEST_WORK="$WORK" QUOTABAR_TEST_TRACE="$WORK/trace" \
      PATH="$WORK/lifecycle:$WORK/compiler:/usr/bin:/bin:/usr/sbin:/sbin" bash "$LAUNCHER" </dev/null 2>&1)"; then
    echo 'Expected the launcher to fail before replacement.' >&2
    exit 1
  fi
  if ! grep -Fq "$message" <<< "$output"; then
    printf 'Missing expected launcher diagnostic: %s\n%s\n' "$message" "$output" >&2
    exit 1
  fi
  printf '%s\n' "$expected_trace" > "$WORK/expected-trace"
  diff -u "$WORK/expected-trace" "$WORK/trace"
  diff -r "$WORK/original.app" "$OLD"
  [[ -x "$OLD/Contents/MacOS/QuotaBar" ]]
  [[ -z "$(find "$WORK/home/Applications" -maxdepth 1 -name '.quotabar-build.*' -print)" ]]
}

expect_failure 'QuotaBar compilation failed.' \
  $'probe default-sdk\nprobe fallback-sdk\ncompile fallback-sdk' '' 0
expect_failure 'QuotaBar compilation failed.' \
  $'probe override-sdk\ncompile override-sdk' "$WORK/override-sdk" 0
expect_failure 'QUOTABAR_SDK is not usable' 'probe override-sdk' "$WORK/override-sdk" 1
expect_failure 'No compatible macOS SDK passed' \
  $'probe default-sdk\nprobe fallback-sdk' '' 1
echo 'APP_02_FAILURE_PATH=PASS · old bundle unchanged; no stop, quarantine change, or launch'

: > "$WORK/trace"
HOME="$WORK/home" QUOTABAR_TEST_NORMAL=0 QUOTABAR_TEST_TRACE="$WORK/trace" \
  PATH="$WORK/lifecycle:/usr/bin:/bin:/usr/sbin:/sbin" \
  bash "$LAUNCHER" --check-build
[[ ! -s "$WORK/trace" ]]
diff -r "$WORK/original.app" "$OLD"
