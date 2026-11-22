"""Compare the complete nginx -T dump to an operator-reviewed, inert baseline."""
import glob
import hashlib
import ipaddress
import json
import os
from pathlib import Path
import re
import subprocess
import sys

HERE = Path(__file__).resolve().parent
if __name__ == "__main__":
    sys.path.insert(0, str(HERE))  # python -I omits the script directory

from common import CONFIG, decode_object, exact, read_regular

MAIN = "/etc/nginx/nginx.conf"
BASE = "/opt/quotabar-relay-status"
HOST = "66workshop.cn"
LOCATION = f"{BASE}/nginx/https/location.conf"
SLOTS = {
    f"{BASE}/nginx/http/*.conf": f"{BASE}/nginx/http/limits.conf",
    f"{BASE}/nginx/https/*.conf": LOCATION,
}
TEMPLATES = dict(zip(SLOTS.values(), ("limits.conf", "location.conf")))
REVIEW = CONFIG / "nginx-review.json"
MARKER = re.compile(rb"(?m)^# configuration file (/[^\r\n]+):\n")
HEX = re.compile(r"[0-9a-f]{64}")


def require(condition):
    if not condition:
        raise ValueError("unapproved configuration or unsupported include topology")


def sha(data):
    return hashlib.sha256(data).hexdigest()


def dump_files(raw):
    markers = list(MARKER.finditer(raw))
    require(markers and markers[0].start() == 0)
    files = {}
    for i, marker in enumerate(markers):
        name = os.fsdecode(marker[1])
        end = markers[i + 1].start() if i + 1 < len(markers) else len(raw)
        content = raw[marker.end():end]
        require(name not in files and content.endswith(b"\n"))
        files[name] = content[:-1]  # nginx appends one LF after each raw file
    require(next(iter(files)) == MAIN)
    return files


def fingerprint(items):
    # Length-prefix both name and content; ordering is significant.
    h = hashlib.sha256()
    for name, content in items:
        for value in (os.fsencode(name), content):
            h.update(len(value).to_bytes(8, "big"))
            h.update(value)
    return h.hexdigest()


def candidate_sha():
    paths = sorted(
        p for p in HERE.rglob("*") if p.is_file() and not any(
            part.startswith(".") or part == "__pycache__" for part in p.relative_to(HERE).parts)
        and p.name != "TEST-EVIDENCE.txt"
    )
    return fingerprint((str(p.relative_to(HERE)), p.read_bytes()) for p in paths)


def tokens(raw):
    """Tokenize nginx's quoted/escaped arguments; reject unhandled syntax."""
    s = os.fsdecode(raw)
    i = 0
    require("\0" not in s)
    while i < len(s):
        c = s[i]
        if c in " \t\r\n":
            i += 1
            continue
        if c == "#":
            end = s.find("\n", i)
            i = len(s) if end < 0 else end + 1
            continue
        if c in "{};":
            yield c, True
            i += 1
            continue
        quote = c if c in "'\"" else ""
        if quote:
            i += 1
        out = []
        while i < len(s):
            c = s[i]
            if quote and c == quote:
                i += 1
                require(i == len(s) or s[i] in " \t\r\n;{)#")
                break
            if not quote and c in " \t\r\n;{":
                break
            if c == "\\":
                i += 1
                require(i < len(s) and s[i] not in "\r\n")
                c = s[i]
                out.append({"t": "\t", "r": "\r", "n": "\n"}.get(
                    c, c if c in "'\"\\" else "\\" + c))
            elif not quote and c == "$" and s[i:i+2] == "${":
                end = s.find("}", i+2)
                require(end >= 0 and re.fullmatch(r"\w+", s[i+2:end], re.ASCII))
                out.append(s[i:end+1])
                i = end
            else:
                require(quote or c not in "'\"}")
                out.append(c)
            i += 1
        else:
            require(not quote)
        yield "".join(out), False


def parse(raw):
    root = []
    scopes = [root]
    args = []
    for value, syntax in tokens(raw):
        if not syntax:
            args.append(value)
        elif value == "}":
            require(not args and len(scopes) > 1)
            scopes.pop()
        else:
            require(args)
            body = [] if value == "{" else None
            scopes[-1].append((tuple(args), body))
            args = []
            if body is not None:
                scopes.append(body)
    require(len(scopes) == 1 and not args)
    return root


def listen_port(value):
    if value.isascii() and value.isdigit():
        return int(value)
    match = re.fullmatch(r"(\[[^\]]+\]|[^:]+)(?::([0-9]+))?", value)
    require(match is not None)
    address = match[1]
    if address != "*":
        ipaddress.ip_address(address.strip("[]"))
    return int(match[2]) if match[2] else 80


def scope_check(files, mode, expand=glob.glob):
    visited = set()
    slots = {key: [] for key in SLOTS}

    def walk(nodes, scope, output, chain):
        for args, body in nodes:
            if chain[-1] != LOCATION:
                require(not (args[0] == "location" and "/api/relay-status/v1" in args[1:])
                        and not any("/run/quotabar-relay-status/api/status.sock" in arg
                                    for arg in args[1:]))
            if args[0] == "include":
                require(body is None and len(args) == 2)
                pattern = os.path.join(os.path.dirname(MAIN), args[1])
                require(os.path.normpath(pattern) == pattern and "$" not in pattern
                        and "\\" not in pattern)
                paths = sorted(expand(pattern), key=os.fsencode) if glob.has_magic(pattern) else [pattern]
                if pattern in slots:
                    slots[pattern].append(scope)
                    require(paths == ([SLOTS[pattern]] if mode == "active" else []))
                else:
                    require(not any(p in TEMPLATES for p in paths))
                for path in paths:
                    require(path in files and path not in chain)
                    visited.add(path)
                    walk(parse(files[path]), scope, output, (*chain, path))
            else:
                children = None if body is None else []
                output.append((args, children))
                if body is not None:
                    walk(body, (*scope, (args, children)), children, chain)

    seen = []
    visited.add(MAIN)
    walk(parse(files[MAIN]), (), seen, (MAIN,))
    require(visited == files.keys())
    http_slot, https_slot = slots.values()
    require(len(http_slot) == len(https_slot) == 1)
    http, https = http_slot[0], https_slot[0]
    require(len(http) == 1 and http[0][0] == ("http",) and len(https) == 2
            and https[0] is http[0] and https[1][0] == ("server",))
    server = https[1][1]
    # An inherited replacement body would erase the buffered client body.
    require(not any(a[0] == "proxy_set_body" for scope in (http[0][1], server) for a, _ in scope))
    names = [args[1:] for args, body in server if args[0] == "server_name" and body is None]
    require(names == [(HOST,)])
    listens = [args[1:] for args, body in server if args[0] == "listen" and body is None]
    require(listens and all(len(args) >= 2 and listen_port(args[0]) == 443
                            and "ssl" in args[1:] and not {"default", "default_server", "quic"}.intersection(args[1:])
                            for args in listens))
    for args, other in http[0][1]:
        if args == ("server",) and other is not server and other is not None:
            if any(a[0] == "server_name" and HOST in (s.lower().rstrip(".") for s in a[1:]) for a, _ in other):
                require(not any(a[0] == "listen" and (not a[1].startswith("unix:"))
                                and listen_port(a[1]) == 443 for a, _ in other))


def verify(files, mode, approved, snippets, expand=glob.glob):
    actual = {path: files[path] for path in TEMPLATES if path in files}
    require(actual == (snippets if mode == "active" else {}))
    baseline = ((path, data) for path, data in files.items() if path not in TEMPLATES)
    require(fingerprint(baseline) == approved)
    scope_check(files, mode, expand)


def capture(command):
    return subprocess.run(command, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
                          check=True, timeout=20).stdout


def launcher_sha(unit):
    # -T must examine the config actually used by both systemd commands,
    # not an unrelated default config while ExecStart/Reload uses -c/-p/-g.
    for prop, suffix in ((b"ExecStart", b""), (b"ExecReload", b" -s reload")):
        argv = b"/usr/sbin/nginx -g daemon on; master_process on;" + suffix
        require(re.search(rb"(?m)^" + prop + rb"=\{ path=/usr/sbin/nginx ; argv\[\]="
                          + re.escape(argv) + rb" ; [^\n]*\}$", unit)
                and unit.count(b"argv[]=") == 2)
    return sha(b"\n".join(line.split(b" ; ignore_errors=", 1)[0] for line in unit.splitlines()))


def runtime_sha():
    os_release = Path("/etc/os-release").read_bytes()
    require(re.search(rb'(?m)^ID=ubuntu$', os_release)
            and re.search(rb'(?m)^VERSION_ID="22\.04"$', os_release))
    owner = capture(["/usr/bin/dpkg-query", "-S", "/usr/sbin/nginx"])
    match = re.fullmatch(rb"([a-z0-9+.-]+): /usr/sbin/nginx\n", owner)
    require(match is not None)
    packages = capture(["/usr/bin/dpkg-query", "-W", "-f=${Package}=${Version}:${Architecture}\n",
                        match[1].decode("ascii"), "systemd", "python3", "python3.10-minimal",
                        "libpython3.10-stdlib"])
    return sha(packages)


def approved_baseline(review_raw, report, candidate, launcher, runtime):
    review = decode_object(review_raw)
    require(exact(review, "baseline_sha256 launcher_sha256 candidate_sha256 runtime_sha256 isolation_report_sha256")
            and all(type(v) is str and HEX.fullmatch(v) for v in review.values())
            and review["launcher_sha256"] == launcher and review["candidate_sha256"] == candidate
            and review["runtime_sha256"] == runtime)
    results = decode_object(report)
    checks = ("load_credential", "socket_identities", "http1_http2_body", "rate_per_ip_global",
              "install_interrupt", "rollback_before_confirmation", "rollback_live_and_cleanup")
    require(sha(report) == review["isolation_report_sha256"]
            and exact(results, "candidate_sha256 runtime_sha256 platform " + " ".join(checks))
            and results["platform"] == "Ubuntu 22.04"
            and results["candidate_sha256"] == candidate and results["runtime_sha256"] == runtime
            and all(results[key] == "PASS" for key in checks))
    return review["baseline_sha256"]


def main(mode):
    require(mode in {"inspect", "inactive", "active"})
    candidate = candidate_sha()
    runtime = runtime_sha()
    launcher = launcher_sha(capture(["/usr/bin/systemctl", "show", "nginx.service",
                                     "--property=FragmentPath,DropInPaths,ExecStart,ExecReload"]))
    raw = capture(["/usr/sbin/nginx", "-T", "-c", MAIN, "-g", "daemon on; master_process on;"])
    files = dump_files(raw)
    # Also reject spoofed dump delimiters or files edited while generating it.
    require(all(Path(path).read_bytes() == content for path, content in files.items()))
    if mode == "inspect":
        baseline = fingerprint(files.items())
        verify(files, "inactive", baseline, {})
        print(json.dumps({"baseline_sha256": baseline, "launcher_sha256": launcher,
                          "candidate_sha256": candidate, "runtime_sha256": runtime}, indent=2))
        return
    review_raw, _ = read_regular(REVIEW, 2048, mode=0o600, root_only_parents=True)
    report, _ = read_regular(CONFIG / "isolation-pass.json", 8192, mode=0o600, root_only_parents=True)
    baseline = approved_baseline(review_raw, report, candidate, launcher, runtime)
    snippets = {p: (HERE / "nginx" / n).read_bytes() for p, n in TEMPLATES.items()}
    verify(files, mode, baseline, snippets)


if __name__ == "__main__":
    try:
        require(len(sys.argv) == 2)
        main(sys.argv[1])
    except (OSError, ValueError, RuntimeError, subprocess.SubprocessError):
        sys.exit("nginx gate: configuration, include context or approval mismatch; no reload authorized")
