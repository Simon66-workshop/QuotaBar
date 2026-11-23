"""Run against the disposable Ubuntu integration fixture, never against ECS."""
import os
from pathlib import Path
import re
import subprocess
import sys
import time

HOST = "66workshop.cn"
ROUTE = "/api/relay-status/v1"
SOCKET = "/run/quotabar-relay-status/api/status.sock"
CERT = "/etc/nginx/quotabar-lab.crt"
MARKER = Path("/etc/quotabar-relay-status/ISOLATED-TEST-VM")
AUTH = "Authorization: Bearer " + "A" * 43


def check(condition, label):
    if not condition:
        raise ValueError(label)


def curl(args):
    env = {"PATH": "/usr/bin:/bin", "LC_ALL": "C"}
    return subprocess.run(["/usr/bin/curl", "-q", "-sS", "--noproxy", "*", "--max-time", "3", *args],
                          capture_output=True, env=env, timeout=4)


def request(ver, source, expect, *extra, path=ROUTE, trace=False, auth=True):
    result = curl([
        f"--http{ver}", "--cacert", CERT, "--resolve", HOST + ":443:127.0.0.1",
        "--interface", f"127.0.0.{source}", "--dump-header", "-",
        *(["-H", AUTH] if auth else []), *extra,
        *(["--trace-ascii", "/dev/stderr"] if trace else []),
        "--write-out", "\n%{http_version} %{http_code}", "https://" + HOST + path,
    ])
    outcome = result.stdout.rsplit(b"\n", 1)[-1]
    check(result.returncode == 0 and outcome == f"{ver} {expect}".encode(), f"expected HTTP/{ver} {expect}")
    if expect in (200, 400, 401, 405, 410, 429, 503) and path == ROUTE:
        headers = result.stdout.partition(b"\r\n\r\n")[0].lower().splitlines()
        check(b"cache-control: no-store" in headers, "missing Cache-Control no-store")
    return result


def status_on_socket(identity, expected, *, uid_denied=False):
    raw = r"""
import errno, socket, sys
s = socket.socket(socket.AF_UNIX)
s.settimeout(2)
try:
    s.connect(sys.argv[1])
except PermissionError as exc:
    sys.exit(0 if sys.argv[2] == 'denied' and exc.errno == errno.EACCES else 1)
if sys.argv[2] == 'denied':
    sys.exit(1)
s.sendall(('GET /api/relay-status/v1 HTTP/1.1\r\nHost: fixture\r\nAuthorization: Bearer '
           + 'A'*43 + '\r\n\r\n').encode())
with s.makefile('rb') as reply:
    sys.exit(0 if reply.readline().split()[1] == sys.argv[2].encode() else 1)
"""
    result = subprocess.run(["/usr/sbin/runuser", "-u", identity, "--", "/usr/bin/python3", "-IB",
                             "-c", raw, SOCKET, "denied" if uid_denied else str(expected)],
                            capture_output=True, timeout=5)
    check(result.returncode == 0, f"unexpected result for {identity} Unix access")


def active():
    status_on_socket("www-data", 200)
    status_on_socket("nobody", None, uid_denied=True)
    request("1.1", 2, 200)
    request("1.1", 3, 400, "--request", "GET", "--data-binary", "X")
    request("1.1", 3, 400, "--request", "GET", "-H", "Transfer-Encoding: chunked", "--data-binary", "X")
    request("2", 4, 200)
    request("2", 4, 400, "--request", "GET", "--data-binary", "X")
    for data in ("X", "XX"):
        reply = request("2", 5, 400, "--request", "GET", "-H", "Content-Length:",
                        "--data-binary", data, trace=True)
        trace = reply.stderr.lower()
        check(b"=> send data" in trace and b"content-length:" not in
              trace.split(b"=> send data", 1)[0], "HTTP/2 trace did not show lengthless DATA")
    request("2", 6, 401, auth=False)
    reply = request("2", 6, 405, "--request", "POST")
    check(b"\nallow: get" in reply.stdout.lower(), "missing Allow header")
    time.sleep(12)
    for _ in range(5):
        request("1.1", 7, 200)
    reply = request("1.1", 7, 429)
    check(b"\nretry-after: 30" in reply.stdout.lower(), "missing per-IP Retry-After")
    request("1.1", 8, 200)
    time.sleep(12)
    for source in range(10, 21):
        request("1.1", source, 200)
    reply = request("1.1", 21, 429)
    check(b"\nretry-after: 30" in reply.stdout.lower(), "missing aggregate Retry-After")
    print("PASS: isolated systemd credential through authenticated 200; www-data/nobody; HTTP/1.1 and lengthless HTTP/2; both rate limits")


def retired(*, backend_live):
    for ver in ("1.1", "2"):
        # Each request invokes a separate curl process, with no auth header.
        check(b"quotabar-lab-site" in request(ver, 2, 200, path="/", auth=False).stdout, "site marker missing")
        reply = request(ver, 2, 410, auth=False)
        body = reply.stdout.partition(b"\r\n\r\n")[2].rsplit(b"\n", 1)[0]
        check(body == b'{"error":"status_retired"}', "unexpected retirement response body")
    if backend_live:
        status_on_socket("www-data", 200)
    else:
        check(not os.path.lexists(SOCKET), "retired API socket remains")
    print("PASS: site healthy; exact unauthenticated 410 with no-store; backend "
          + ("still available" if backend_live else "socket removed"))


if __name__ == "__main__":
    try:
        check(os.geteuid() == 0 and sys.platform == "linux" and MARKER.read_text().strip() == "DISPOSABLE",
              "requires a marked disposable Ubuntu VM")
        check(re.search(r'(?m)^VERSION_ID="22\.04"$', Path("/etc/os-release").read_text()), "requires Ubuntu 22.04")
        check(len(sys.argv) == 2 and sys.argv[1] in {"active", "retired", "retired-clean"},
              "usage: active|retired|retired-clean")
        if sys.argv[1] == "active":
            active()
        else:
            retired(backend_live=sys.argv[1] == "retired")
    except (OSError, ValueError, subprocess.SubprocessError) as err:
        sys.exit("isolated nginx test failed: " + (str(err) if isinstance(err, ValueError) else type(err).__name__))
