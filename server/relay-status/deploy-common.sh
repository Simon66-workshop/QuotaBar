# Sourced by install.sh and rollback.sh. Never source operator configuration.
export PATH=/usr/sbin:/usr/bin:/sbin:/bin
export LC_ALL=C
umask 077
BASE=/opt/quotabar-relay-status
CONFIG=/etc/quotabar-relay-status
RUN=/run/quotabar-relay-status
UNIT_DIR=/etc/systemd/system
TMPFILES=/etc/tmpfiles.d/quotabar-status.conf
API=quotabar-status-api.service
COLLECTOR=quotabar-status-collector.service
TIMER=quotabar-status-collector.timer
UNITS=("$API" "$COLLECTOR" "$TIMER")
PY_FILES=(api.py collector.py common.py run-api.py run-collector.py)
NGINX_TREE="$BASE/nginx"
HTTP="$NGINX_TREE/http/limits.conf"
VHOST="$NGINX_TREE/https/location.conf"
HOST_FREEZE=/run/host-config-change.lock

die() { printf '%s\n' "$*" >&2; exit 1; }
say() { printf '%s\n' "$*"; }
absent() { [[ ! -e "$1" && ! -L "$1" ]]; }
regular_match() { [[ -f "$1" && ! -L "$1" ]] && cmp -s -- "$1" "$2"; }
nginx_gate() { /usr/bin/python3 -IB "$HERE/nginx-gate.py" "$1"; }
# Overlay the staged tree only for the validator, at the actual include
# paths, so nginx -T checks the whole candidate without exposing it to a
# separate nginx reload. unshare sets private propagation before mount.
nginx_gate_staged() {
    /usr/bin/unshare --mount --propagation private -- /bin/bash -ec '
        /usr/bin/mount --bind "$1" "$2"
        exec /usr/bin/python3 -IB "$3/nginx-gate.py" "$4"
    ' -- "$1" "$NGINX_TREE" "$HERE" "$2"
}
new_nginx_stage() {
    stage=$(mktemp -d "$BASE/.nginx-candidate.XXXXXX")
    chmod 0755 "$stage"
    install -d -m 0755 "$stage/http" "$stage/https"
}
discard_nginx_stage() {
    if [[ -n ${stage:-} && -d "$stage" ]]; then
        rm -f -- "$stage/http/limits.conf" "$stage/https/location.conf"
        rmdir -- "$stage/http" "$stage/https" "$stage"
    fi
}
publish_nginx() {
    # Unlike mv, rename cannot fall back to non-atomic copying.
    /usr/bin/python3 -IB -c 'import os, sys; os.rename(*sys.argv[1:])' "$1" "$2"
}
# Unlike the retired nginx gate (which also allows draining workers' limits),
# reinstall requires exactly the files left by completed backend cleanup.
fully_retired_tree() (
    local dir
    for dir in "$BASE" "$NGINX_TREE" "$NGINX_TREE/http" "$NGINX_TREE/https"; do
        [[ -d "$dir" && ! -L "$dir" && $(stat -c '%u %g %a' "$dir") == '0 0 755' ]] || return 1
    done
    shopt -s dotglob nullglob
    set -- "$BASE"/*
    [[ $# == 1 && "$1" == "$NGINX_TREE" ]] || return 1
    set -- "$NGINX_TREE"/*
    [[ $# == 2 ]] || return 1
    set -- "$NGINX_TREE/http"/*
    [[ $# == 0 ]] || return 1
    set -- "$NGINX_TREE/https"/*
    [[ $# == 1 && "$1" == "$VHOST" ]] &&
        regular_match "$VHOST" "$HERE/nginx/retired.conf" &&
        [[ $(stat -c '%u %g %a %h' "$VHOST") == '0 0 644 1' ]]
)
activate_nginx() {
    if [[ "$1" == retired ]]; then
        # Limits have no effect on the 410. The route rename is the final
        # switch; even a failure between the two never exposes the fallback.
        publish_nginx "$2/http/limits.conf" "$HTTP" || return
        publish_nginx "$2/https/location.conf" "$VHOST"
    else
        publish_nginx "$2" "$NGINX_TREE"
    fi
}
systemd_reload() {
    nginx_gate systemd || die "Production systemd baseline has drift; no daemon-reload."
    /usr/bin/systemctl daemon-reload
    nginx_gate systemd || die "Production systemd baseline changed; stop and review."
}
nginx_reload() {
    nginx_gate systemd || die "Production systemd baseline has drift; no shared nginx reload."
    /usr/bin/systemctl reload nginx.service >/dev/null 2>&1
}

begin_apply() {
    [[ $(uname -s) == Linux && $(id -u) == 0 ]] || die "--apply requires Linux root."
    [[ -d "$CONFIG" && ! -L "$CONFIG" && $(stat -c '%u %g %a' "$CONFIG") == '0 0 700' ]] ||
        die "Prepare the dedicated root:root 0700 credential directory first."
    # This is the shared host lock, not a substitute for an approved freeze
    # covering other writers (including automation that does not flock).
    [[ -f "$HOST_FREEZE" && ! -L "$HOST_FREEZE" &&
       $(stat -c '%u %g %a %h' "$HOST_FREEZE") == '0 0 600 1' ]] ||
        die "Require the pre-provisioned shared host configuration freeze lock."
    exec 8<>"$HOST_FREEZE"
    flock -n 8 || die "Shared nginx/systemd change window is busy."
    [[ ! -L "$CONFIG/deploy.lock" ]] || die "Unexpected lock entry."
    exec 9>>"$CONFIG/deploy.lock"
    flock -n 9 || die "Another status deploy or rollback is running."
}

nginx_workers() { /usr/bin/python3 -IB "$HERE/nginx-workers.py" "$@"; }
