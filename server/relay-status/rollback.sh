#!/bin/bash
set -euo pipefail
HERE=$(cd -- "$(dirname -- "$0")" && pwd -P)
source "$HERE/deploy-common.sh"

usage="Usage: rollback.sh [--dry-run|--remove-route|--remove-backend --confirmed-live RECEIPT]"
case "${1:---dry-run}" in
    --dry-run)
        [[ $# -le 1 ]] || die "$usage"
        say "DRY RUN: no files, nginx or units changed."
        say "Phase 1 (--remove-route): verify the approved baseline, withdraw only this route and request reload."
        say "Independently verify new nginx workers, website health and that the old URL no longer reaches the upstream."
        say "Phase 2 (--remove-backend --confirmed-live RECEIPT): recheck baseline and worker turnover, then remove the status backend."
        say "Preserve the dedicated identity, source policy and inert shared-vhost include slots."
        exit 0 ;;
    --remove-route) [[ $# == 1 ]] || die "$usage" ;;
    --remove-backend) [[ $# == 3 && "$2" == --confirmed-live && "$3" =~ ^[0-9a-f]{32}$ ]] || die "$usage" ;;
    *) die "$usage" ;;
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
absent "$HTTP" || regular_match "$HTTP" "$HERE/nginx/limits.conf" || die "HTTP snippet changed."
absent "$VHOST" || regular_match "$VHOST" "$HERE/nginx/location.conf" || die "HTTPS snippet changed."
pending="$BASE/rollback-awaiting-live.json"
saved_limits="$BASE/rollback-limits.conf"
saved_location="$BASE/rollback-location.conf"
absent "$saved_limits" || { absent "$HTTP" && regular_match "$saved_limits" "$HERE/nginx/limits.conf"; } ||
    die "Unexpected staged HTTP fragment."
absent "$saved_location" || { absent "$VHOST" && regular_match "$saved_location" "$HERE/nginx/location.conf"; } ||
    die "Unexpected staged HTTPS fragment."

if [[ "$1" == --remove-route ]]; then
    checkfile=$(mktemp -d "$BASE/.rollback.XXXXXX")
    moved_location=no moved_limits=no reload_attempted=no
    route_exit() {
        if [[ "$reload_attempted" == no ]]; then
            if [[ "$moved_limits" == yes ]]; then mv -- "$saved_limits" "$HTTP"; fi
            if [[ "$moved_location" == yes ]]; then mv -- "$saved_location" "$VHOST"; fi
        fi
        rm -f -- "$checkfile/witness"
        rmdir -- "$checkfile"
    }
    trap route_exit EXIT
    rm -f -- "$pending"
    if ! absent "$VHOST"; then mv -- "$VHOST" "$saved_location"; moved_location=yes; fi
    if ! absent "$HTTP"; then mv -- "$HTTP" "$saved_limits"; moved_limits=yes; fi
    nginx_workers record "$checkfile/witness" || die "Could not record running nginx workers; no reload."
    nginx_gate inactive || die "Approved nginx baseline did not match; no reload."
    reload_attempted=yes
    nginx_reload || die "Reload outcome unknown; keep the backend and verify nginx before retrying."
    mv -- "$checkfile/witness" "$pending"
    say "Reload requested; status backend and credential remain intact."
    receipt=$(nginx_workers receipt "$pending")
    say "Only after independent LIVE checks pass, use --remove-backend --confirmed-live $receipt."
    exit 0
fi

absent "$HTTP" && absent "$VHOST" || die "Remove the route first; no backend changes."
nginx_gate inactive || die "Approved nginx baseline did not match; no backend changes."
[[ -f "$pending" && ! -L "$pending" && $(stat -c '%u %g %a %h' "$pending") == '0 0 600 1' ]] ||
    die "Phase 1 has no valid receipt; no backend changes."
nginx_workers verify "$pending" "$3" || die "Live confirmation required; no backend changes."

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
rm -- "$pending"
for dir in "$BASE/templates" "$BASE/nginx/http" "$BASE/nginx/https" "$BASE/nginx" "$BASE"; do
    if [[ -d "$dir" ]]; then rmdir -- "$dir"; fi
done
say "Confirmed route withdrawal; dedicated status backend removed."
