#!/bin/bash
set -euo pipefail
HERE=$(cd -- "$(dirname -- "$0")" && pwd -P)
source "$HERE/deploy-common.sh"

usage="Usage: rollback.sh [--dry-run|--remove-route|--remove-backend --confirmed-live RECEIPT]"
case "${1:---dry-run}" in
    --dry-run)
        [[ $# -le 1 ]] || die "$usage"
        say "DRY RUN: no environment preflight; no files, nginx or units changed."
        say "Phase 1 (--remove-route): verify approved baselines, atomically retire the proxy with a quiet exact 410, and request reload."
        say "Independently verify old workers exited, website health and the exact no-store 410 without Authorization; verify the backend is still healthy."
        say "Phase 2 (--remove-backend --confirmed-live RECEIPT): recheck baselines and worker turnover, then remove the status backend."
        say "Keep the exact retirement route so lingering clients cannot pass credentials to the site's fallback."
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
pending="$BASE/rollback-awaiting-live.json"

if [[ "$1" == --remove-route ]]; then
    if regular_match "$VHOST" "$HERE/nginx/retired.conf"; then
        mode=retired
    elif regular_match "$VHOST" "$HERE/nginx/location.conf"; then
        mode=active
    else
        absent "$VHOST" || die "HTTPS snippet changed."
        mode=inactive
    fi
    nginx_gate "$mode" || die "Approved nginx/systemd baseline did not match; no route changes."
    checkfile=$(mktemp -d "$BASE/.rollback.XXXXXX")
    stage=
    route_exit() {
        discard_nginx_stage
        rm -f -- "$checkfile/witness"
        rmdir -- "$checkfile"
    }
    trap route_exit EXIT
    # Invalidate any earlier receipt before making a new change. If
    # interrupted, rerun phase 1; never restore a live proxy on error.
    rm -f -- "$pending"
    nginx_workers record "$checkfile/witness" || die "Could not record running nginx workers; no reload."
    if [[ "$mode" != retired ]]; then
        if absent "$NGINX_TREE"; then mkdir -m 0755 -- "$NGINX_TREE"; fi
        new_nginx_stage
        if [[ "$mode" == active ]]; then
            install -m 0644 "$HERE/nginx/limits.conf" "$stage/http/limits.conf"
        fi
        install -m 0644 "$HERE/nginx/retired.conf" "$stage/https/location.conf"
        nginx_gate_staged "$stage" retired || die "Retirement configuration failed; no activation."
        if [[ "$mode" == active ]]; then
            publish_nginx "$stage/https/location.conf" "$VHOST"
        else
            publish_nginx "$stage" "$NGINX_TREE"
            stage=
        fi
    fi
    nginx_gate retired || die "Retired files no longer match approved config; no reload."
    nginx_reload || die "Reload outcome unknown; keep the backend and verify nginx before retrying."
    mv -- "$checkfile/witness" "$pending"
    say "Reload requested; status backend and credential remain intact behind the retirement route."
    receipt=$(nginx_workers receipt "$pending")
    say "Only after independent LIVE checks pass, use --remove-backend --confirmed-live $receipt."
    exit 0
fi

nginx_gate retired || die "Require the approved exact retirement route; no backend changes."
[[ -f "$pending" && ! -L "$pending" && $(stat -c '%u %g %a %h' "$pending") == '0 0 600 1' ]] ||
    die "Phase 1 has no valid receipt; no backend changes."
nginx_workers verify "$pending" "$3" || die "Live confirmation required; no backend changes."

for unit in "$TIMER" "$API"; do
    if [[ -f "$UNIT_DIR/$unit" ]]; then
        systemctl stop "$unit"
        systemctl disable --no-reload "$unit"
    fi
done
if [[ -f "$UNIT_DIR/$COLLECTOR" ]]; then systemctl stop "$COLLECTOR"; fi
for unit in "${UNITS[@]}"; do rm -f -- "$UNIT_DIR/$unit"; done
rm -f -- "$TMPFILES"
systemd_reload

if [[ -S "$RUN/api/status.sock" ]]; then rm -- "$RUN/api/status.sock"; fi
rm -f -- "$RUN/snapshot.json" "$RUN"/.snapshot.json.*
if [[ -d "$RUN/api" ]]; then rmdir -- "$RUN/api"; fi
if [[ -d "$RUN" ]]; then rmdir -- "$RUN"; fi
rm -f -- "$CONFIG/verify.json"
for file in "${PY_FILES[@]}"; do rm -f -- "$BASE/$file"; done
for file in "${UNITS[@]}" quotabar-status.conf limits.conf location.conf retired.conf; do
    rm -f -- "$BASE/templates/$file"
done
rm -f -- "$HTTP"
if [[ -d "$BASE/templates" ]]; then rmdir -- "$BASE/templates"; fi
rm -- "$pending"
say "Dedicated status backend and credentials removed. The quiet exact 410 remains on disk and live."
