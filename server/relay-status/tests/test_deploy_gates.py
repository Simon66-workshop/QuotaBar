import importlib.util
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))


def load(name):
    spec = importlib.util.spec_from_file_location(name, ROOT / (name + ".py"))
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


gate = load("nginx-gate")
workers = load("nginx-workers")
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


class NginxGateTests(unittest.TestCase):
    def setUp(self):
        self.files = {gate.MAIN: ROOT_CONFIG, SITE: CANONICAL, WIRES: f"include '{HTTPS}';".encode(),
                      OTHER: b"server { listen 80; server_name 66workshop.cn; }"}
        self.actual = {**self.files, **SNIPPETS}
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
        candidate, launcher, runtime = "c" * 64, "a" * 64, "f" * 64
        checks = dict.fromkeys(("load_credential", "socket_identities", "http1_http2_body", "rate_per_ip_global",
                                "install_interrupt", "rollback_before_confirmation", "rollback_live_and_cleanup"), "PASS")
        report = {**checks, "candidate_sha256": candidate, "platform": "Ubuntu 22.04", "runtime_sha256": runtime}
        review = {"baseline_sha256": self.approved, "launcher_sha256": launcher,
                  "candidate_sha256": candidate, "runtime_sha256": runtime}

        def approve(data, changes=None):
            raw = json.dumps(data).encode()
            approval = {**review, "isolation_report_sha256": gate.sha(raw), **(changes or {})}
            return gate.approved_baseline(json.dumps(approval).encode(), raw, candidate, launcher, runtime)

        self.assertEqual(approve(report), self.approved)
        for change in ({"platform": "macOS"}, {"candidate_sha256": "b" * 64}, {"http1_http2_body": "NOT_RUN"},
                       {"rollback_before_confirmation": False}, {"runtime_sha256": "e" * 64}):
            with self.subTest(change=change), self.assertRaises(ValueError):
                approve({**report, **change})
        with self.assertRaises(ValueError):
            approve(report, {"isolation_report_sha256": "0" * 64})


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
        script = (ROOT / "rollback.sh").read_text()
        removed = script.index('rm -f -- "$CONFIG/verify.json"')
        self.assertLess(script.index('nginx_gate inactive', script.index('absent "$HTTP" && absent "$VHOST"')), removed)
        self.assertLess(script.index('nginx_workers verify'), script.index('systemctl stop "$unit"'))
        self.assertLess(script.index('nginx_workers verify'), removed)


if __name__ == "__main__":
    unittest.main()
