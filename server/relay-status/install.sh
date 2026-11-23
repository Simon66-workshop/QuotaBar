#!/bin/bash
set -euo pipefail
HERE=$(cd -- "$(dirname -- "$0")" && pwd -P)
source "$HERE/deploy-common.sh"

[[ $# -le 1 ]] || die "Usage: install.sh [--dry-run|--apply]"
case "${1:---dry-run}" in
    --dry-run)
        say "DRY RUN: no environment preflight; no files, users, nginx or units changed."
        say "After approval: validate current nginx, credentials, account and empty or fully retired include slots."
        say "Install the isolated collector, timer, API and tmpfiles; start only these new status units."
        say "Verify snapshot and socket; activate only the dedicated 443 location and http limits."
        say "Require the shared change freeze, approved nginx/systemd baselines and candidate-bound isolation report."
        say "Check the complete candidate in a private mount namespace before one atomic activation."
        exit 0 ;;
    --apply) ;;
    *) die "Usage: install.sh [--dry-run|--apply]" ;;
esac

[[ $(uname -s) == Linux && $(id -u) == 0 ]] || die "--apply requires Linux root."
begin_apply
mode=inactive
if ! absent "$BASE"; then
    fully_retired_tree || die "Only an exact, fully cleaned retirement tree can be reinstalled."
    mode=retired
fi
nginx_gate "$mode" || die "Initial nginx review gate failed; nothing installed or reloaded."
for exe in /usr/bin/python3 /usr/bin/systemctl /usr/bin/openssl /usr/bin/unshare /usr/bin/mount; do
    [[ -x "$exe" ]] || die "Required existing system executable is missing."
done
[[ -f "$CONFIG/verify.json" && ! -L "$CONFIG/verify.json" &&
   $(stat -c '%u %g %a %h' "$CONFIG/verify.json") == '0 0 600 1' ]] ||
    die "Prepare the root:root 0600 SHA-256 credential first."
if ! absent "$CONFIG/source-policy.json"; then
    [[ -f "$CONFIG/source-policy.json" && ! -L "$CONFIG/source-policy.json" &&
       $(stat -c '%u %g %a %h' "$CONFIG/source-policy.json") == '0 0 600 1' ]] ||
        die "Unexpected source-policy.json ownership or mode."
fi
/usr/bin/python3 -IB - "$HERE" <<'PY' || die "Invalid SHA-256 credential."
import sys
sys.path.insert(0, sys.argv[1])
from api import Credentials
from common import CONFIG, decode_object, read_regular
try:
    Credentials.from_document(decode_object(read_regular(CONFIG / "verify.json", 1024, mode=0o600)[0]))
except (OSError, ValueError, RecursionError):
    sys.exit(1)
PY
[[ $(id -u quotabar-status) != 0 && $(id -gn quotabar-status) == quotabar-status &&
   $(id -Gn quotabar-status) == quotabar-status ]] ||
    die "Pre-provision the dedicated non-root status identity with no supplementary groups."
getent group www-data >/dev/null || die "Verify the documented nginx worker group."
for path in "$RUN" "$TMPFILES"; do
    absent "$path" || die "An install target already exists; do not overwrite it."
done
for unit in "${UNITS[@]}"; do
    absent "$UNIT_DIR/$unit" || die "A status unit target already exists."
    state=$(systemctl show --property=LoadState --value "$unit" 2>/dev/null || :)
    [[ "$state" == not-found ]] || die "A status unit name is already in use."
done

# Reserve the private installation tree before copying anything into it.
if [[ "$mode" == inactive ]]; then mkdir -m 0755 -- "$BASE"; fi
stage=
install_exit() {
    local rc=$?
    discard_nginx_stage
    if (( rc != 0 )); then
        say "Install incomplete; check live workers and use the two-phase rollback. Do not remove the backend first."
    fi
}
trap install_exit EXIT
install -d -m 0755 "$BASE/templates"
if [[ "$mode" == inactive ]]; then install -d -m 0755 "$NGINX_TREE"; fi
for file in "${PY_FILES[@]}"; do
    install -m 0644 "$HERE/$file" "$BASE/$file"
done
for file in "${UNITS[@]}" quotabar-status.conf; do
    install -m 0644 "$HERE/systemd/$file" "$BASE/templates/$file"
done
for file in limits.conf location.conf retired.conf; do
    install -m 0644 "$HERE/nginx/$file" "$BASE/templates/$file"
done
for unit in "${UNITS[@]}"; do
    install -m 0644 "$BASE/templates/$unit" "$UNIT_DIR/$unit"
done
install -m 0644 "$BASE/templates/quotabar-status.conf" "$TMPFILES"
systemd-tmpfiles --create "$TMPFILES"
[[ $(stat -c '%U %G %a' "$RUN/api") == 'quotabar-status www-data 2750' ]] ||
    die "Unexpected Unix socket directory ownership or mode."
systemd_reload
systemctl start "$COLLECTOR"
[[ $(stat -c '%U %G %a' "$RUN/snapshot.json") == 'root quotabar-status 640' ]] ||
    die "Unexpected snapshot ownership or mode."
systemctl start "$API" "$TIMER"
for ((i=0; i<25; i++)); do
    [[ -S "$RUN/api/status.sock" ]] && break
    sleep 0.2
done
[[ -S "$RUN/api/status.sock" && $(stat -c '%U %G %a' "$RUN/api/status.sock") == 'quotabar-status www-data 660' ]] ||
    die "API did not create the expected Unix socket."
/usr/bin/python3 -IB - "$RUN/api/status.sock" <<'PY' || die "New API failed the local unauthenticated socket probe."
import socket
import sys
with socket.socket(socket.AF_UNIX) as conn:
    conn.settimeout(2)
    conn.connect(sys.argv[1])
    conn.sendall(b"GET /api/relay-status/v1 HTTP/1.1\r\nHost: localhost\r\n\r\n")
    with conn.makefile("rb") as response:
        sys.exit(0 if response.readline(128).startswith(b"HTTP/1.1 401 ") else 1)
PY
systemctl enable --no-reload "$API" "$TIMER"
new_nginx_stage
install -m 0644 "$BASE/templates/limits.conf" "$stage/http/limits.conf"
install -m 0644 "$BASE/templates/location.conf" "$stage/https/location.conf"
nginx_gate_staged "$stage" active || die "Complete isolated nginx candidate failed; no activation."
activate_nginx "$mode" "$stage" || die "Atomic nginx publication failed; no reload."
nginx_gate active || die "Activated files no longer match approved config; no reload."
nginx_reload || die "nginx reload failed; confirm live configuration before further changes."
say "Status components installed; verify nginx TLS, routing, privacy and response gates separately."
