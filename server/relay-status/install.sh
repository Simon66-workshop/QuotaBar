#!/bin/bash
set -euo pipefail
HERE=$(cd -- "$(dirname -- "$0")" && pwd -P)
source "$HERE/deploy-common.sh"

[[ $# -le 1 ]] || die "Usage: install.sh [--dry-run|--apply]"
case "${1:---dry-run}" in
    --dry-run)
        say "DRY RUN: no files, users, nginx or units changed."
        say "After approval: validate current nginx, credentials, account and empty include slots."
        say "Install the isolated collector, timer, API and tmpfiles; start only these new status units."
        say "Verify snapshot and socket; activate only the dedicated 443 location and http limits."
        say "Verify both includes and nginx -t, then gracefully reload nginx."
        exit 0 ;;
    --apply) ;;
    *) die "Usage: install.sh [--dry-run|--apply]" ;;
esac

[[ $(uname -s) == Linux && $(id -u) == 0 ]] || die "--apply requires Linux root."
nginx_check || die "Initial nginx -t failed; nothing installed or reloaded."
begin_apply
for exe in /usr/bin/python3 /usr/bin/systemctl /usr/bin/openssl; do
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
for path in "$BASE" "$RUN" "$TMPFILES"; do
    absent "$path" || die "An install target already exists; do not overwrite it."
done
for unit in "${UNITS[@]}"; do
    absent "$UNIT_DIR/$unit" || die "A status unit target already exists."
    state=$(systemctl show --property=LoadState --value "$unit" 2>/dev/null || :)
    [[ "$state" == not-found ]] || die "A status unit name is already in use."
done

# Reserve the private installation tree before copying anything into it.
mkdir -m 0755 -- "$BASE"
reload_attempted=no
install_exit() {
    local rc=$?
    if (( rc != 0 )); then
        if [[ "$reload_attempted" == no ]]; then
            # Do not leave failed fragments eligible for a future shared reload.
            if [[ -f "$VHOST" ]]; then mv -- "$VHOST" "$BASE/staged-location.conf"; fi
            if [[ -f "$HTTP" ]]; then mv -- "$HTTP" "$BASE/staged-limits.conf"; fi
            say "Install incomplete; nginx was not reloaded. Review and use rollback.sh --apply."
        else
            say "Reload outcome unknown; keep the status service available and use verified rollback."
        fi
    fi
}
trap install_exit EXIT
install -d -m 0755 "$BASE/templates" "$BASE/nginx/http" "$BASE/nginx/https"
for file in "${PY_FILES[@]}"; do
    install -m 0644 "$HERE/$file" "$BASE/$file"
done
for file in "${UNITS[@]}" quotabar-status.conf; do
    install -m 0644 "$HERE/systemd/$file" "$BASE/templates/$file"
done
for file in limits.conf location.conf; do
    install -m 0644 "$HERE/nginx/$file" "$BASE/templates/$file"
done
for unit in "${UNITS[@]}"; do
    install -m 0644 "$BASE/templates/$unit" "$UNIT_DIR/$unit"
done
install -m 0644 "$BASE/templates/quotabar-status.conf" "$TMPFILES"
systemd-tmpfiles --create "$TMPFILES"
[[ $(stat -c '%U %G %a' "$RUN/api") == 'quotabar-status www-data 2750' ]] ||
    die "Unexpected Unix socket directory ownership or mode."
systemctl daemon-reload
systemctl start "$COLLECTOR"
[[ $(stat -c '%U %G %a' "$RUN/snapshot.json") == 'root quotabar-status 640' ]] ||
    die "Unexpected snapshot ownership or mode."
systemctl enable --now "$API" "$TIMER"
for ((i=0; i<25; i++)); do
    [[ -S "$RUN/api/status.sock" ]] && break
    sleep 0.2
done
[[ -S "$RUN/api/status.sock" && $(stat -c '%U %G %a' "$RUN/api/status.sock") == 'quotabar-status www-data 660' ]] ||
    die "API did not create the expected Unix socket."
install -m 0644 "$BASE/templates/limits.conf" "$BASE/staged-limits.conf"
install -m 0644 "$BASE/templates/location.conf" "$BASE/staged-location.conf"
mv -- "$BASE/staged-limits.conf" "$HTTP"
mv -- "$BASE/staged-location.conf" "$VHOST"
nginx_check && snippets_visible || die "nginx configuration or dedicated include slots failed validation."
reload_attempted=yes
nginx_reload || die "nginx reload failed; confirm live configuration before further changes."
say "Status components installed; verify nginx TLS, routing, privacy and response gates separately."
