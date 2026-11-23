import importlib.util
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import tempfile
import unittest
from unittest import mock

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))


def load(name):
    spec = importlib.util.spec_from_file_location(name, ROOT / (name + ".py"))
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


gate = load("nginx-gate")
workers = load("nginx-workers")
probe = load("tests/probe-isolated-nginx")
HTTP, HTTPS = gate.SLOTS
SITE = "/etc/nginx/sites-enabled/canonical"
OTHER = "/etc/nginx/sites-enabled/other"
WIRES = "/etc/nginx/relay-slot.conf"
SITES = "/etc/nginx/sites-enabled/*"
CANONICAL = f"""server {{
    listen 443 ssl http2;
    listen [::]:443 ssl http2;
    server_name 66workshop.cn;
    include {WIRES};
}}""".encode()
ROOT_CONFIG = f"""events {{}}
http {{
    include "{HTTP}";
    include sites-enabled/*;
}}""".encode()
SNIPPETS = {p: (ROOT / "nginx" / n).read_bytes() for p, n in gate.TEMPLATES.items()}
SNIPPETS["retired"] = (ROOT / "nginx/retired.conf").read_bytes()


class NginxGateTests(unittest.TestCase):
    def setUp(self):
        self.files = {gate.MAIN: ROOT_CONFIG, SITE: CANONICAL, WIRES: f"include '{HTTPS}';".encode(),
                      OTHER: b"server { listen 80; server_name 66workshop.cn; }"}
        self.actual = {**self.files, **{p: SNIPPETS[p] for p in gate.TEMPLATES}}
        self.approved = gate.fingerprint(self.files.items())

    def expand(self, path):
        if path == SITES:
            return [OTHER, SITE]
        target = gate.SLOTS[path]
        return [target] if target in self.actual else []

    def verify(self, mode="active"):
        gate.verify(self.actual, mode, self.approved, SNIPPETS, self.expand)

    def check_rejected_even_if_file_contents_are_reviewed(self):
        self.approved = gate.fingerprint((k, v) for k, v in self.actual.items() if k not in SNIPPETS)
        with self.assertRaises(ValueError):
            self.verify()

    def test_only_exact_feature_delta_matches_complete_baseline(self):
        self.verify()
        self.actual = dict(self.files)
        self.verify("inactive")

    def test_unrelated_pending_site_config_blocks_shared_reload(self):
        self.actual[OTHER] += b"\nserver { listen 81; }"
        with self.assertRaises(ValueError):
            self.verify()

    def test_candidate_must_match_both_templates(self):
        for data in (b"changed template", b""):
            self.actual[gate.SLOTS[HTTPS]] = data
            with self.assertRaises(ValueError):
                self.verify()

    def test_wrong_host_port_protocol_http_scope_and_inherited_body_are_refused(self):
        for site in (CANONICAL.replace(b"443 ssl", b"80 ssl"),
                     CANONICAL.replace(b"443 ssl", b"443"),
                     CANONICAL.replace(b"66workshop.cn", b"other.example"),
                     CANONICAL.replace(b"66workshop.cn", b"66workshop.cn other.example"),
                     CANONICAL.replace(b"443 ssl", b"443 ssl default_server"),
                     CANONICAL.replace(b"include", b"proxy_set_body ''; include")):
            with self.subTest(site=site):
                self.actual[SITE] = site
                self.check_rejected_even_if_file_contents_are_reviewed()
        self.actual[SITE] = CANONICAL
        self.actual[gate.MAIN] = ROOT_CONFIG.replace(b"events {}", b"events {}\ninclude " + HTTP.encode() + b";").replace(
            f'include "{HTTP}";'.encode(), b"")
        self.check_rejected_even_if_file_contents_are_reviewed()

    def test_same_dumped_file_included_through_two_servers_is_refused(self):
        self.actual[OTHER] = f"server {{ listen 443 ssl; server_name other.example; include {WIRES}; }}".encode()
        self.check_rejected_even_if_file_contents_are_reviewed()

    def test_duplicate_canonical_tls_vhost_is_refused(self):
        self.actual[OTHER] = b"server { listen 443 ssl; server_name 66WORKSHOP.CN; }"
        self.check_rejected_even_if_file_contents_are_reviewed()

    def test_slot_missing_and_slot_at_wrong_depth_are_refused_before_install(self):
        self.actual = dict(self.files)
        self.actual[WIRES] = b""
        self.approved = gate.fingerprint(self.actual.items())
        with self.assertRaises(ValueError):
            self.verify("inactive")
        self.actual[WIRES] = f"location / {{ include {HTTPS}; }}".encode()
        self.approved = gate.fingerprint(self.actual.items())
        with self.assertRaises(ValueError):
            self.verify("inactive")

    def test_dump_reader_binds_order_and_preserves_all_bytes(self):
        raw = b"".join(b"# configuration file " + p.encode() + b":\n" + c + b"\n"
                       for p, c in self.actual.items())
        self.assertEqual(gate.dump_files(raw), self.actual)
        with self.assertRaises(ValueError):
            gate.dump_files(raw + raw)
        self.assertNotEqual(gate.fingerprint(self.files.items()), gate.fingerprint(reversed(self.files.items())))

    def test_launcher_fingerprint_ignores_runtime_fields_but_not_config_overrides(self):
        prefix = b" ; argv[]=/usr/sbin/nginx -g daemon on; master_process on;"
        unit = (b"FragmentPath=/lib/systemd/system/nginx.service\n"
                b"ExecStart={ path=/usr/sbin/nginx" + prefix + b" ; ignore_errors=no ; pid=1 }\n"
                b"ExecReload={ path=/usr/sbin/nginx" + prefix + b" -s reload ; ignore_errors=no ; pid=2 }\n")
        self.assertEqual(gate.launcher_sha(unit), gate.launcher_sha(unit.replace(b"pid=2", b"pid=3")))
        self.assertNotEqual(gate.launcher_sha(unit), gate.launcher_sha(unit.replace(b"/lib/", b"/etc/")))
        with self.assertRaises(ValueError):
            gate.launcher_sha(unit.replace(b" -s reload", b" -s reload -c /other"))

    def test_approval_must_bind_all_isolation_passes_to_exact_candidate(self):
        candidate, launcher, runtime, systemd = "c" * 64, "a" * 64, "f" * 64, "d" * 64
        checks = dict.fromkeys(gate.ISOLATION_CHECKS, "PASS")
        report = {**checks, "candidate_sha256": candidate, "platform": "Ubuntu 22.04", "runtime_sha256": runtime}
        review = {"baseline_sha256": self.approved, "launcher_sha256": launcher,
                  "candidate_sha256": candidate, "runtime_sha256": runtime, "systemd_sha256": systemd}

        def approve(data, changes=None):
            raw = json.dumps(data).encode()
            approval = {**review, "isolation_report_sha256": gate.sha(raw), **(changes or {})}
            return gate.approved_baseline(json.dumps(approval).encode(), raw, candidate, launcher, runtime, systemd)

        self.assertEqual(approve(report), self.approved)
        for change in ({"platform": "macOS"}, {"candidate_sha256": "b" * 64}, {"http1_http2_body": "NOT_RUN"},
                       {"rollback_before_confirmation": False}, {"runtime_sha256": "e" * 64},
                       {"systemd_change_freeze": "NOT_RUN"}, {"unexpected": "PASS"}):
            with self.subTest(change=change), self.assertRaises(ValueError):
                approve({**report, **change})
        with self.assertRaises(ValueError):
            approve(report, {"isolation_report_sha256": "0" * 64})
        with self.assertRaises(ValueError):
            approve(report, {"systemd_sha256": "0" * 64})
        with self.assertRaises(ValueError):
            approve({k: v for k, v in report.items() if k != "systemd_change_freeze"})

    def test_documented_matrix_matches_validator_and_cli(self):
        doc = (ROOT / "tests/ISOLATED-LINUX.md").read_text()
        self.assertEqual(re.findall(r"(?m)^\| `(\w+)` \|", doc), list(gate.ISOLATION_CHECKS))
        output = subprocess.check_output([sys.executable, "-IB", str(ROOT / "nginx-gate.py"),
                                          "isolation-checks"], text=True, timeout=5)
        self.assertEqual(output.splitlines(), list(gate.ISOLATION_CHECKS))

    def test_systemd_baseline_binds_fragment_content_and_rejects_manager_drift(self):
        drift = False

        def run(command):
            if command[len(gate.SYSTEMCTL)] != "show":
                return b""
            unit = command[-1]
            reload = "yes" if drift and unit == "nginx.service" else "no"
            return (f"LoadState=loaded\nNeedDaemonReload={reload}\n"
                    f"FragmentPath=/etc/systemd/system/{unit}\nDropInPaths=\n").encode()

        def read(path):
            return b"revised" if path.endswith("/nginx.service") else b"fixture"

        self.assertNotEqual(gate.systemd_sha(run, read), gate.systemd_sha(run, lambda _: b"fixture"))
        drift = True
        with self.assertRaises(ValueError):
            gate.systemd_sha(run, read)

    def test_retired_inspection_keeps_same_baseline_and_rejects_wrong_route(self):
        original_verify = gate.verify
        original_read = Path.read_bytes

        def inspect(mode):
            raw = b"".join(b"# configuration file " + p.encode() + b":\n" + c + b"\n"
                           for p, c in self.actual.items())
            with (mock.patch.object(gate, "runtime_sha", return_value="runtime"),
                  mock.patch.object(gate, "launcher_sha", return_value="launcher"),
                  mock.patch.object(gate, "systemd_sha", return_value="systemd"),
                  mock.patch.object(gate, "capture", side_effect=[b"", raw]),
                  mock.patch.object(gate, "verify", side_effect=lambda *args: original_verify(*args, expand=self.expand)),
                  mock.patch.object(Path, "read_bytes", lambda p: self.actual[str(p)]
                                    if str(p) in self.actual else original_read(p)),
                  mock.patch("builtins.print") as output):
                gate.main(mode)
            return json.loads(output.call_args.args[0])

        # Keep this unit test independent of the exact inspect output hash.
        with mock.patch.object(gate, "candidate_sha", return_value="candidate"):
            self.actual = dict(self.files)
            inactive = inspect("inspect")
            self.actual[gate.LOCATION] = SNIPPETS["retired"]
            self.assertEqual(inspect("inspect-retired"), inactive)
            self.actual[gate.LOCATION] = SNIPPETS[gate.LOCATION]
            with self.assertRaises(ValueError):
                inspect("inspect-retired")


class RetirementProbeTests(unittest.TestCase):
    @staticmethod
    def reply(args, *, code=410, header=b"Cache-Control: no-store\r\n", body=b'{"error":"status_retired"}'):
        ver = "2" if "--http2" in args else "1.1"
        if args[-1].endswith("/"):
            code, header, body = 200, b"", b"quotabar-lab-site"
        raw = f"HTTP/{ver} {code}\r\n".encode() + header + b"\r\n" + body + f"\n{ver} {code}".encode()
        return subprocess.CompletedProcess(args, 0, raw, b"")

    def test_each_tls_exchange_is_separate_and_has_no_authorization(self):
        with (mock.patch.object(probe, "curl", side_effect=self.reply) as tls,
              mock.patch.object(probe, "status_on_socket") as direct,
              mock.patch("builtins.print")):
            probe.retired(backend_live=True)
        self.assertEqual([(call.args[0][0], call.args[0][-1].endswith("/")) for call in tls.call_args_list],
                         [("--http1.1", True), ("--http1.1", False), ("--http2", True), ("--http2", False)])
        for call in tls.call_args_list:
            self.assertNotIn("-H", call.args[0])
        direct.assert_called_once_with("www-data", 200)

    def test_wrong_status_body_or_cache_header_does_not_pass(self):
        for override in ({"code": 404}, {"body": b"wrong"}, {"header": b""}):
            with (self.subTest(override=override),
                  mock.patch.object(probe, "curl", side_effect=lambda args: self.reply(args, **override)),
                  mock.patch.object(probe, "status_on_socket") as direct, self.assertRaises(ValueError)):
                probe.retired(backend_live=True)
            direct.assert_not_called()

    def test_after_cleanup_socket_must_be_absent(self):
        with (mock.patch.object(probe, "curl", side_effect=self.reply),
              mock.patch.object(probe, "status_on_socket") as direct, mock.patch("builtins.print"),
              mock.patch.object(probe.os.path, "lexists", side_effect=[True, False])):
            with self.assertRaises(ValueError):
                probe.retired(backend_live=False)
            probe.retired(backend_live=False)
        direct.assert_not_called()


class RollbackWitnessTests(unittest.TestCase):
    def test_entrypoints_load_sibling_module_in_python_isolated_mode(self):
        for script, label in (("nginx-gate.py", b"nginx gate:"), ("nginx-workers.py", b"nginx workers:")):
            result = subprocess.run([sys.executable, "-IB", str(ROOT / script), "invalid"],
                                    capture_output=True, timeout=5)
            self.assertEqual(result.returncode, 1)
            self.assertTrue(result.stderr.startswith(label), result.stderr)

    def test_old_generation_or_changed_master_never_allows_backend_cleanup(self):
        before = {"master": "7:10", "workers": ["8:11", "9:12"]}
        for state in (("7:10", {"8:11"}), ("7:10", {"9:12", "11:15"}),
                      ("7:10", set()), ("7:20", {"8:21"})):
            with self.subTest(state=state), self.assertRaises(ValueError):
                workers.validate(before, state)
        workers.validate(before, ("7:10", {"8:21", "12:22"}))

    def test_linux_generation_uses_start_ticks_not_only_pid(self):
        with tempfile.TemporaryDirectory() as temp:
            fake = Path(temp) / "123"
            fake.mkdir()
            st = fake / "stat"
            st.write_text("123 (name with ) paren) " + " ".join(map(str, range(20))))
            self.assertEqual(workers.generation(fake), "123:19")

    def test_backend_gate_precedes_any_stop_or_credential_removal(self):
        for denied in ("retired", "missing", "witness", ""):
            with self.subTest(denied=denied), tempfile.TemporaryDirectory() as temp:
                lab = Path(temp)
                for name in ("base/templates", "base/nginx/https", "base/nginx/http", "config", "units"):
                    (lab / name).mkdir(parents=True, exist_ok=True)
                (lab / "rollback.sh").write_bytes((ROOT / "rollback.sh").read_bytes())
                (lab / "deploy-common.sh").write_text(r"""
source "$COMMON"
BASE="$LAB/base" CONFIG="$LAB/config" RUN="$LAB/run" UNIT_DIR="$LAB/units"
TMPFILES="$LAB/tmpfiles" HTTP="$BASE/nginx/http/limits.conf" VHOST="$BASE/nginx/https/location.conf"
begin_apply() { :; }
stat() {
    if [[ "$2" == '%u %g %a' ]]; then echo '0 0 755'; else echo '0 0 600 1'; fi
}
nginx_gate() { echo "gate $1" >>"$LAB/calls"; [[ "$DENIED" != "$1" ]] && cmp -s "$VHOST" "$TOMBSTONE"; }
nginx_workers() { echo "workers $1" >>"$LAB/calls"; [[ "$DENIED" != witness ]]; }
systemctl() { echo "systemctl $*" >>"$LAB/calls"; }
systemd_reload() { echo "daemon-reload" >>"$LAB/calls"; }
""")
                unit = lab / "units/quotabar-status-api.service"
                credential = lab / "config/verify.json"
                pending = lab / "base/rollback-awaiting-live.json"
                for path in (lab / "base/templates" / unit.name, unit, credential):
                    path.touch()
                if denied != "missing":
                    pending.touch()
                route = lab / "base/nginx/https/location.conf"
                route.write_bytes(SNIPPETS["retired"])
                result = subprocess.run(
                    ["/bin/bash", str(lab / "rollback.sh"), "--remove-backend", "--confirmed-live", "a" * 32],
                    env={**os.environ, "COMMON": str(ROOT / "deploy-common.sh"), "LAB": temp, "DENIED": denied,
                         "TOMBSTONE": str(ROOT / "nginx/retired.conf")},
                    capture_output=True, timeout=5)
                self.assertEqual(result.returncode == 0, not denied, result.stderr)
                self.assertEqual(credential.exists(), bool(denied))
                self.assertEqual(unit.exists(), bool(denied))
                self.assertEqual(route.read_bytes(), SNIPPETS["retired"])
                expected = ["gate retired"]
                if denied not in ("retired", "missing"):
                    expected.append("workers verify")
                if not denied:
                    expected += ["systemctl stop " + unit.name,
                                 "systemctl disable --no-reload " + unit.name, "daemon-reload"]
                self.assertEqual((lab / "calls").read_text().splitlines(), expected)


class DeployShellTests(unittest.TestCase):
    def shell(self, code, *args):
        return subprocess.run(["/bin/bash", "-euc", 'source "$COMMON"\n' + code, "test", *map(str, args)],
                              env={**os.environ, "COMMON": str(ROOT / "deploy-common.sh"), "HERE": str(ROOT)},
                              capture_output=True, text=True, timeout=5)

    def test_systemd_freeze_gate_blocks_shared_reload_commands(self):
        for verb, command in (("systemd_reload", "daemon-reload"), ("nginx_reload", "reload nginx.service")):
            for drift in ("drift", "approved"):
                with self.subTest(verb=verb, drift=drift), tempfile.TemporaryDirectory() as temp:
                    calls = Path(temp) / "calls"
                    result = self.shell(r"""
# Store outer arguments so the stubbed commands never reach host systemctl.
DRIFT=$2 CALLS=$3
nginx_gate() { echo "gate $1" >> "$CALLS"; [[ "$DRIFT" == approved ]]; }
function /usr/bin/systemctl() { echo "$*" >> "$CALLS"; }
"$1"
""", verb, drift, calls)
                    expected = ["gate systemd"]
                    if drift == "approved":
                        expected.append(command)
                        if verb == "systemd_reload":
                            expected.append("gate systemd")
                    self.assertEqual(result.returncode == 0, drift == "approved", result.stderr)
                    self.assertEqual(calls.read_text().splitlines(), expected)

    def test_retired_tree_rejects_leftovers_and_wrong_route(self):
        code = r"""
BASE=$1 NGINX_TREE=$1/nginx VHOST=$1/nginx/https/location.conf
stat() {
    if [[ "$2" == '%u %g %a' ]]; then echo '0 0 755'; else echo '0 0 644 1'; fi
}
fully_retired_tree
"""
        with tempfile.TemporaryDirectory() as temp:
            base = Path(temp)
            (base / "nginx/http").mkdir(parents=True)
            (base / "nginx/https").mkdir()
            route = base / "nginx/https/location.conf"
            route.write_bytes(SNIPPETS["retired"])
            self.assertEqual(self.shell(code, base).returncode, 0)
            for leftover in ("rollback-awaiting-live.json", ".nginx-candidate", "nginx/http/limits.conf",
                             "nginx/https/unexpected"):
                with self.subTest(leftover=leftover):
                    entry = base / leftover
                    entry.touch()
                    self.assertNotEqual(self.shell(code, base).returncode, 0)
                    entry.unlink()
            route.write_bytes(SNIPPETS[gate.LOCATION])
            self.assertNotEqual(self.shell(code, base).returncode, 0)
            route.unlink()
            route.symlink_to(ROOT / "nginx/retired.conf")
            self.assertNotEqual(self.shell(code, base).returncode, 0)

    def test_atomic_route_publication_keeps_410_if_final_rename_fails(self):
        code = r"""
NGINX_TREE=$1 HTTP=$1/http/limits.conf VHOST=$1/https/location.conf
activate_nginx retired "$2"
"""
        for missing in ("http/limits.conf", "https/location.conf", ""):
            with self.subTest(missing=missing), tempfile.TemporaryDirectory() as temp:
                live, stage = (Path(temp) / name for name in ("live", "stage"))
                for tree in (live, stage):
                    for slot in ("http", "https"):
                        (tree / slot).mkdir(parents=True)
                route = live / "https/location.conf"
                route.write_bytes(SNIPPETS["retired"])
                for relpath, snippet in (("http/limits.conf", gate.LIMITS), ("https/location.conf", gate.LOCATION)):
                    if relpath != missing:
                        (stage / relpath).write_bytes(SNIPPETS[snippet])
                result = self.shell(code, live, stage)
                self.assertEqual(result.returncode == 0, not missing, result.stderr)
                self.assertEqual(route.read_bytes(), SNIPPETS["retired" if missing else gate.LOCATION])
                self.assertEqual((live / "http/limits.conf").exists(), missing != "http/limits.conf")


if __name__ == "__main__":
    unittest.main()
