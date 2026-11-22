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
HTTP="$BASE/nginx/http/limits.conf"
VHOST="$BASE/nginx/https/location.conf"

die() { printf '%s\n' "$*" >&2; exit 1; }
say() { printf '%s\n' "$*"; }
absent() { [[ ! -e "$1" && ! -L "$1" ]]; }
regular_match() { [[ -f "$1" && ! -L "$1" ]] && cmp -s -- "$1" "$2"; }
nginx_check() { nginx -t >/dev/null 2>&1; }
nginx_reload() { systemctl reload nginx.service >/dev/null 2>&1; }

begin_apply() {
    [[ $(uname -s) == Linux && $(id -u) == 0 ]] || die "--apply requires Linux root."
    [[ -d "$CONFIG" && ! -L "$CONFIG" && $(stat -c '%u %g %a' "$CONFIG") == '0 0 700' ]] ||
        die "Prepare the dedicated root:root 0700 credential directory first."
    [[ ! -L "$CONFIG/deploy.lock" ]] || die "Unexpected lock entry."
    exec 9>>"$CONFIG/deploy.lock"
    flock -n 9 || die "Another status deploy or rollback is running."
}

snippets_visible() {
    # Keep the rest of the shared nginx configuration out of command output.
    # This proves files were loaded, not which vhost(s) included them.
    nginx -T 2>/dev/null | awk -v a="# configuration file $HTTP:" -v b="# configuration file $VHOST:" '
        $0 == a { x++ }
        $0 == b { y++ }
        END { exit !(x == 1 && y == 1) }
    '
}
