#!/bin/bash
set -euo pipefail
HERE=$(cd -- "$(dirname -- "$0")" && pwd -P)
source "$HERE/deploy-common.sh"

[[ $# -le 1 ]] || die "Usage: rollback.sh [--dry-run|--apply]"
case "${1:---dry-run}" in
    --dry-run)
        say "DRY RUN: no files, nginx or units changed."
        say "Disable only this feature's nginx snippets; nginx -t, then graceful reload."
        say "If the check or reload fails, restore snippets and do not stop status units."
        say "After reload, stop/disable only the new status units; remove their files and digest."
        say "Preserve the dedicated identity, source policy and inert shared-vhost include slots."
        exit 0 ;;
    --apply) ;;
    *) die "Usage: rollback.sh [--dry-run|--apply]" ;;
esac

begin_apply
[[ -d "$BASE" && ! -L "$BASE" && $(stat -c '%u %g %a' "$BASE") == '0 0 755' ]] ||
    die "No owned status installation tree."
for unit in "${UNITS[@]}"; do
    absent "$UNIT_DIR/$unit" || regular_match "$UNIT_DIR/$unit" "$BASE/templates/$unit" ||
        die "A status unit was modified; review it before rollback."
done
absent "$TMPFILES" || regular_match "$TMPFILES" "$BASE/templates/quotabar-status.conf" ||
    die "The tmpfiles definition was modified; review it before rollback."
absent "$HTTP" || regular_match "$HTTP" "$BASE/templates/limits.conf" || die "HTTP snippet changed."
absent "$VHOST" || regular_match "$VHOST" "$BASE/templates/location.conf" || die "HTTPS snippet changed."
for file in "$BASE"/rollback-{limits,location}.conf; do
    absent "$file" || die "Interrupted rollback; inspect staged fragments before continuing."
done

restore_snippets() {
    if [[ -f "$BASE/rollback-limits.conf" ]]; then mv -- "$BASE/rollback-limits.conf" "$HTTP"; fi
    if [[ -f "$BASE/rollback-location.conf" ]]; then mv -- "$BASE/rollback-location.conf" "$VHOST"; fi
}
# Staging is reversible until nginx has accepted and reloaded the new config.
trap 'restore_snippets' EXIT
if [[ -f "$VHOST" ]]; then mv -- "$VHOST" "$BASE/rollback-location.conf"; fi
if [[ -f "$HTTP" ]]; then mv -- "$HTTP" "$BASE/rollback-limits.conf"; fi
nginx_check || die "nginx -t failed; restoring snippets without reload."
nginx_reload || die "nginx reload failed; restoring snippets; status units left alone."
trap - EXIT

for unit in "$TIMER" "$API"; do
    if [[ -f "$UNIT_DIR/$unit" ]]; then
        systemctl stop "$unit"
        systemctl disable "$unit"
    fi
done
if [[ -f "$UNIT_DIR/$COLLECTOR" ]]; then systemctl stop "$COLLECTOR"; fi
for unit in "${UNITS[@]}"; do rm -f -- "$UNIT_DIR/$unit"; done
rm -f -- "$TMPFILES"
systemctl daemon-reload

if [[ -S "$RUN/api/status.sock" ]]; then rm -- "$RUN/api/status.sock"; fi
rm -f -- "$RUN/snapshot.json" "$RUN"/.snapshot.json.*
if [[ -d "$RUN/api" ]]; then rmdir -- "$RUN/api"; fi
if [[ -d "$RUN" ]]; then rmdir -- "$RUN"; fi
rm -f -- "$CONFIG/verify.json"
for file in "${PY_FILES[@]}"; do rm -f -- "$BASE/$file"; done
for file in "${UNITS[@]}" quotabar-status.conf limits.conf location.conf; do
    rm -f -- "$BASE/templates/$file"
done
rm -f -- "$BASE"/{rollback,staged}-{limits,location}.conf
for dir in "$BASE/templates" "$BASE/nginx/http" "$BASE/nginx/https" "$BASE/nginx" "$BASE"; do
    if [[ -d "$dir" ]]; then rmdir -- "$dir"; fi
done
say "Status endpoint removed from nginx configuration. Independently verify the site and the URL."
