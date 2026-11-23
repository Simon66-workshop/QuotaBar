import contextlib
import hashlib
import importlib.util
import io
import json
import os
from pathlib import Path
import socket
import stat
import subprocess
import sys
import tempfile
import threading
import unittest
from unittest import mock

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT))
import api
import collector
import common

NOW = 1_795_367_800.0
MONO = 12_000.0
FAKE_PID = 8675309
FAKE_SECRET = "fake-secret-do-not-disclose"
FAKE_PATH = "/private/fake-relay/state.json"
BOOT = "12345678-1234-1234-1234-123456789abc"
OWNER = os.getuid()
OWNERS = (0, OWNER)
ACTIVE_UNIT = collector.Unit("active", FAKE_PID, MONO - 500, "a" * 32)
CONFIRMED = collector.Policy(True, True, frozenset({"reconnecting"}), True, True)
UNKNOWN = {"state": "unknown", "reason": "source_unavailable", "last_heartbeat_at": None}
TOKEN = b"A" * 43  # public synthetic canonical encodings, never real credentials
OLD_TOKEN = b"B" * 42 + b"Q"
WRONG_TOKEN = b"C" * 42 + b"g"


def feishu(age=0, **overrides):
    stamp = NOW - age
    return ({
        "pid": FAKE_PID, "timestamp": stamp, "connection_ready": True,
        "connection_event": "heartbeat_ack", "status": "blocked_not_production_ready",
        "token": FAKE_SECRET, "path": FAKE_PATH, **overrides,
    }, stamp)


def wecom(age=0, pong=0, **overrides):
    return ({
        "pid": FAKE_PID, "monotonic": MONO - age, "boottime": MONO - age,
        "state": "subscribed", "last_pong_age": pong,
        "secret": FAKE_SECRET, "path": FAKE_PATH, **overrides,
    }, NOW - age)


def connection(name, sample, unit=ACTIVE_UNIT, lease="clear", policy=CONFIRMED):
    return collector.connection(name, unit, sample, lease, NOW, MONO, policy)


def private_snapshot():
    return {
        "schema_version": 1, "observed_at": common.rfc3339(NOW), "boot_id": BOOT,
        "observed_boottime": MONO, "lease_clear_for_s": None, "feishu": connection("feishu", feishu()),
        "wecom": connection("wecom", wecom()), "certificate": collector.certificate(NOW + 200, NOW),
    }


def digest(token):
    return hashlib.sha256(token).hexdigest()


def credentials_document(rotating=False):
    return {"active_sha256": digest(TOKEN), "previous_sha256": digest(OLD_TOKEN) if rotating else None,
            "rotated_at": NOW if rotating else None,
            "previous_until": NOW + common.DAY if rotating else None}


def request(method=b"GET", path=api.PATH, authorization=b"Bearer " + TOKEN, extra=b""):
    line = method + b" " + path + b" HTTP/1.1\r\nHost: test\r\n"
    if authorization is not None:
        line += b"Authorization: " + authorization + b"\r\n"
    return line + extra + b"\r\n"


class StateTests(unittest.TestCase):
    def test_feishu_threshold_edges(self):
        for age, expected in ((89.9, "ready"), (90, "ready"), (90.1, "heartbeat_late"),
                              (179.9, "heartbeat_late"), (180, "heartbeat_late"), (180.1, "heartbeat_stale")):
            with self.subTest(age=age):
                self.assertEqual(connection("feishu", feishu(age))["reason"], expected)

    def test_wecom_pong_uses_mtime_and_threshold_edges(self):
        for pong, expected in ((59.9, "ready"), (60, "ready"), (60.1, "pong_late"),
                               (179.9, "pong_late"), (180, "pong_late"), (180.1, "pong_stale")):
            with self.subTest(pong=pong):
                result = connection("wecom", wecom(age=10, pong=pong - 10))
                self.assertEqual(result["reason"], expected)
                self.assertEqual(result["last_heartbeat_at"], common.rfc3339(NOW - 10))

    def test_wecom_heartbeat_threshold_edges(self):
        # At 90s the pong is already yellow; verify the higher-priority reason changes.
        for age, reason in ((89.9, "pong_late"), (90, "pong_late"), (90.1, "heartbeat_late"),
                            (179.9, "heartbeat_late"), (180, "heartbeat_late"), (180.1, "heartbeat_stale")):
            with self.subTest(age=age):
                self.assertEqual(connection("wecom", wecom(age))["reason"], reason)

    def test_unconfirmed_missing_and_unrecognized_evidence_is_not_green(self):
        for name, sample, policy in (
            ("feishu", feishu(), collector.Policy()),
            ("feishu", feishu(connection_event="not_ack"), CONFIRMED),
            ("feishu", feishu(connection_ready=1), CONFIRMED),
            ("wecom", wecom(), collector.Policy()),
            ("wecom", wecom(state=FAKE_SECRET), CONFIRMED),
            ("wecom", wecom(pong=-0.1), CONFIRMED),
            ("wecom", wecom(pong=506), CONFIRMED),
            ("wecom", wecom(pong=True), CONFIRMED),
            ("wecom", wecom(monotonic=MONO-100), CONFIRMED),
            ("wecom", wecom(monotonic=MONO+5.1), CONFIRMED),
        ):
            with self.subTest(name=name):
                self.assertEqual(connection(name, sample, policy=policy)["state"], "unknown")
        self.assertEqual(connection("feishu", (None, None)), UNKNOWN)
        self.assertEqual(connection("feishu", feishu(), None)["state"], "unknown")
        self.assertEqual(connection("feishu", feishu(connection_ready=False))["reason"], "reconnecting")
        self.assertEqual(connection("wecom", wecom(state="reconnecting"))["reason"], "reconnecting")

    def test_current_instance_and_clock_validation(self):
        denials = (
            (feishu(501), ACTIVE_UNIT),
            (feishu(pid=FAKE_PID + 1), ACTIVE_UNIT),
            (feishu(age=-5.1), ACTIVE_UNIT),
            (feishu(12)[:1] + (NOW,), ACTIVE_UNIT),
            (feishu(), collector.Unit("active", FAKE_PID, MONO + 1, "a" * 32)),
            (feishu(), collector.Unit("active", FAKE_PID, MONO-500, "")),
        )
        for sample, unit in denials:
            with self.subTest(mtime=sample[1]):
                self.assertEqual(connection("feishu", sample, unit)["state"], "unknown")
        self.assertEqual(connection("feishu", feishu(age=-5))["state"], "ok")
        self.assertEqual(connection("wecom", wecom(age=501))["state"], "unknown")

    def test_wecom_pong_must_belong_to_current_invocation(self):
        unit = collector.Unit("active", FAKE_PID, MONO - 1, "b" * 32)
        for age, pong, expected in ((0, 0.999, "ready"), (0, 1, "ready"),
                                    (0, 1.001, "source_unavailable"), (0, 5, "source_unavailable"),
                                    (0.5, 0.5, "ready"), (0.5, 0.501, "source_unavailable")):
            with self.subTest(age=age, pong=pong):
                self.assertEqual(connection("wecom", wecom(age, pong), unit)["reason"], expected)
        self.assertEqual(connection("wecom", wecom(pong=5, state="reconnecting"), unit)["state"], "unknown")

    def test_feishu_timestamp_and_mtime_have_independent_future_bounds(self):
        for ts, mtime, expected in ((4, 8, "unknown"), (6, 4, "unknown"), (5, 5, "ok"),
                                    (4, 5.001, "unknown"), (4, 5, "ok"), (-10, -4, "unknown")):
            with self.subTest(ts=ts, mtime=mtime):
                self.assertEqual(connection("feishu", (feishu(-ts)[0], NOW + mtime))["state"], expected)

    def test_unit_precedence_and_lease(self):
        for state in ("inactive", "failed"):
            with self.subTest(state=state):
                unit = collector.Unit(state, 0, 0, "")
                self.assertEqual(connection("feishu", (None, None), unit, "unknown")["reason"], "unit_down")
                self.assertEqual(connection("feishu", (None, None), unit, "stopped")["reason"], "paused_by_lease")
        for state in ("activating", "deactivating", "reloading"):
            self.assertEqual(connection("wecom", (None, None), collector.Unit(state, 0, 0, ""))["reason"],
                             "transitioning")
        self.assertEqual(connection("feishu", feishu(), lease="stopped")["reason"], "lease_conflict")
        self.assertEqual(connection("feishu", feishu(181), lease="stopped")["reason"], "heartbeat_stale")
        self.assertEqual(connection("feishu", feishu(), lease="unknown")["reason"], "source_unavailable")

    def test_lease_expiry_and_ambiguity(self):
        def lease(expires, stopped=True, state="LEASE"):
            return ({"state": state, "expires_at": expires, "ecs_stopped": stopped, "path": FAKE_PATH}, NOW)
        for sample, result in ((lease(NOW + 1), "stopped"), (lease(NOW), "clear"),
                               (lease(NOW-1), "clear"), (lease(common.rfc3339(NOW+1), False), "clear"),
                               (lease(NOW+1, "true"), "unknown"), (lease(NOW+1, state="OTHER"), "unknown"),
                               (lease("n/a"), "unknown"), ((None, None), "clear"), ((None, -1), "unknown")):
            with self.subTest(expected=result):
                self.assertEqual(collector.lease_status(sample, NOW, CONFIRMED), (result, None))
        strict = collector.Policy(absent_lease_clear=True)
        for sample, result in (
            (lease(NOW + 1, False), ("clear", 1)),
            (lease(NOW + 1), ("stopped", None)),
            (lease(NOW, False), ("unknown", None)),
            ((None, None), ("clear", None)),
        ):
            with self.subTest(expected=result):
                self.assertEqual(collector.lease_status(sample, NOW, strict), result)
        self.assertEqual(collector.lease_status((None, None), NOW, collector.Policy()), ("unknown", None))

    def test_unit_instance_changed_during_collect(self):
        replacement = collector.Unit("active", FAKE_PID, ACTIVE_UNIT.started, "b" * 32)
        with (mock.patch.object(collector, "boot_id", return_value=BOOT),
              mock.patch.object(collector, "boot_clock", return_value=MONO),
              mock.patch.object(collector, "read_policy", return_value=CONFIRMED),
              mock.patch.object(collector.pwd, "getpwnam", return_value=mock.Mock(pw_uid=1234)),
              mock.patch.object(collector.grp, "getgrnam", return_value=mock.Mock(gr_gid=1234)),
              mock.patch.object(collector, "leaf_expiry", side_effect=OSError(FAKE_PATH)),
              mock.patch.object(collector, "load_units", side_effect=[
                  {collector.FEISHU_UNIT: ACTIVE_UNIT}, {collector.FEISHU_UNIT: replacement}]),
              mock.patch.object(collector, "source", side_effect=[feishu(), wecom(), (None, None)]),
              mock.patch.object(collector.time, "time", return_value=NOW),
              mock.patch.object(collector.time, "monotonic", return_value=MONO),
              mock.patch.object(collector, "atomic_write") as write):
            collector.collect()
        blob = write.call_args.args[1]
        doc = json.loads(blob)
        self.assertEqual(doc["feishu"]["state"], "unknown")
        self.assertEqual(doc["certificate"]["state"], "unknown")
        for junk in (str(FAKE_PID), FAKE_SECRET, FAKE_PATH):
            self.assertNotIn(junk.encode(), blob)

    def test_unit_show_does_not_lose_known_down_when_other_unit_missing(self):
        fixture = (
            b"Id=relay-feishu.service\nLoadState=loaded\nActiveState=failed\nMainPID=0\n"
            b"ExecMainStartTimestampMonotonic=\nInvocationID=\n\n"
            b"Id=relay-wecom.service\nLoadState=not-found\nActiveState=inactive\n"
        )
        with mock.patch.object(collector.subprocess, "run",
                               return_value=subprocess.CompletedProcess([], 1, fixture)) as run:
            units = collector.load_units()
        self.assertEqual(units, {collector.FEISHU_UNIT: collector.Unit("failed", 0, 0, "")})
        self.assertIn("show", run.call_args.args[0])


class ReadAndContractTests(unittest.TestCase):
    def setUp(self):
        temp = tempfile.TemporaryDirectory(prefix="qb-status-", dir=Path(tempfile.gettempdir()).resolve())
        self.addCleanup(temp.cleanup)
        self.folder = Path(temp.name)
        self.target = self.folder / "input.json"

    def read(self):
        return collector.source(self.target, owners=(OWNER,), parent_owners=OWNERS, missing_ok=True)

    def test_file_missing_truncated_bad_oversized_and_duplicate(self):
        self.assertEqual(self.read(), (None, None))
        cases = (b'{"x":', b'\xff\xfe', b'[]', b'{"x":NaN}', b'{"x":1,"x":2}',
                 b"[" * 5000, b" " * (common.SOURCE_LIMIT + 1))
        for invalid in cases:
            with self.subTest(length=len(invalid)):
                self.target.write_bytes(invalid)
                self.assertEqual(self.read(), (None, -1))

    def test_fstat_mtime_ignores_embedded_time(self):
        data, _ = wecom(age=12, pong=47)
        del data["secret"]
        self.target.write_text(json.dumps(data), encoding="ascii")
        os.utime(self.target, (NOW - 12, NOW - 12))
        sample = self.read()
        self.assertAlmostEqual(sample[1], NOW - 12)
        self.assertEqual(connection("wecom", sample)["reason"], "ready")
        os.utime(self.target, (NOW - 14, NOW - 14))
        self.assertEqual(connection("wecom", self.read())["reason"], "pong_late")

    def test_symlinks_hardlinks_writable_directory_and_fifo_are_rejected(self):
        sibling = self.folder / "sibling.json"
        sibling.write_text("{}", encoding="ascii")
        self.target.symlink_to(sibling)
        self.assertEqual(self.read(), (None, -1))
        self.target.unlink()
        os.link(sibling, self.target)
        self.assertEqual(self.read(), (None, -1))
        self.target.unlink()
        os.mkfifo(self.target, 0o600)
        self.assertEqual(self.read(), (None, -1))
        self.target.unlink()
        self.target.write_text("{}", encoding="ascii")
        alias = self.folder / "alias"
        alias.symlink_to(self.folder, target_is_directory=True)
        doc, _ = collector.source(alias / self.target.name, owners=OWNERS)
        self.assertIsNone(doc)
        self.folder.chmod(0o777)
        try:
            self.assertEqual(self.read(), (None, -1))
        finally:
            self.folder.chmod(0o700)

    def test_atomic_replace_preserves_open_old_inode_and_mode(self):
        common.atomic_write(self.target, b'{"old":1}', 0o640, owners=OWNERS)
        with self.target.open("rb") as old:
            common.atomic_write(self.target, b'{"new":1}', 0o640, owners=OWNERS)
            self.assertEqual(old.read(), b'{"old":1}')
        self.assertEqual(self.target.read_bytes(), b'{"new":1}')
        self.assertEqual(stat.S_IMODE(self.target.stat().st_mode), 0o640)
        self.assertEqual(list(self.folder.iterdir()), [self.target])

    def test_sticky_writable_ancestor_refuses_private_descendant(self):
        sticky = self.folder / "sticky"
        sticky.mkdir()
        trusted_leaf = sticky / "private"
        trusted_leaf.mkdir(mode=0o700)
        target = trusted_leaf / "input.json"
        target.write_text("{}", encoding="ascii")
        self.assertEqual(common.read_regular(target, 32, owners=OWNERS)[0], b"{}")
        sticky.chmod(0o1777)
        try:
            with self.assertRaisesRegex(ValueError, "untrusted directory"):
                common.read_regular(target, 32, owners=OWNERS)
        finally:
            sticky.chmod(0o700)

    def test_public_whitelist_and_injected_data_rejection(self):
        doc = private_snapshot()
        public = common.project_snapshot(doc, BOOT, MONO+1.9)
        self.assertEqual(set(public), {"schema_version", "observed_at", "snapshot_age_s",
                                       "feishu", "wecom", "certificate"})
        for field in ("feishu", "wecom"):
            self.assertEqual(set(public[field]), {"state", "reason", "last_heartbeat_at"})
        self.assertEqual(set(public["certificate"]), {"state", "expires_at", "days_remaining"})
        self.assertEqual(public["snapshot_age_s"], 1)
        blob = json.dumps(public)
        for value in (FAKE_SECRET, FAKE_PATH, str(FAKE_PID), BOOT, "blocked_not_production_ready"):
            self.assertNotIn(value, blob)
        for section, key, val in ((None, "internal", FAKE_PATH), ("feishu", "reason", FAKE_SECRET),
                                  ("wecom", "pid", FAKE_PID), ("certificate", "days_remaining", True),
                                  ("certificate", "expires_at", FAKE_PATH)):
            with self.subTest(key=key):
                altered = private_snapshot()
                target = altered if section is None else altered[section]
                target[key] = val
                with self.assertRaises(ValueError):
                    common.project_snapshot(altered, BOOT, MONO)

    def test_snapshot_freshness_edges_and_boot_id(self):
        for age, floored in ((0, 0), (74.9, 74), (75, 75)):
            self.assertEqual(common.project_snapshot(private_snapshot(), BOOT, MONO+age)["snapshot_age_s"],
                             floored)
        for age in (-0.1, 75.001):
            with self.assertRaises(ValueError):
                common.project_snapshot(private_snapshot(), BOOT, MONO+age)
        with self.assertRaises(ValueError):
            common.project_snapshot(private_snapshot(), "a" * 36, MONO)

    def test_disk_snapshot_through_api_uses_mode_and_monotonic_freshness(self):
        creds = api.Credentials.from_document(credentials_document())
        doc = private_snapshot()
        doc["wecom"] = {**UNKNOWN, "effective_pong_age_s": None}
        original_reader = common.read_regular

        def fixture_reader(path, size, *, mode):
            return original_reader(path, size, owners=(OWNER,), parent_owners=OWNERS, mode=mode)

        with (mock.patch.object(api, "SNAPSHOT", self.target),
              mock.patch.object(api, "read_regular", side_effect=fixture_reader),
              mock.patch.object(api, "boot_id", return_value=BOOT),
              mock.patch.object(api, "boot_clock", return_value=MONO + 75) as clock):
            def call():
                return api.dispatch(request()[:-4], b"", creds, api.snapshot, NOW)

            self.assertTrue(call().startswith(b"HTTP/1.1 503 "))
            common.atomic_write(self.target, json.dumps(doc).encode(), 0o640, owners=OWNERS)
            self.assertTrue(call().startswith(b"HTTP/1.1 200 "))
            self.assertEqual(json.loads(call().split(b"\r\n\r\n")[1])["wecom"], UNKNOWN)
            clock.return_value += 0.01
            self.assertTrue(call().startswith(b"HTTP/1.1 503 "))
            clock.return_value = MONO
            self.target.chmod(0o644)
            self.assertTrue(call().startswith(b"HTTP/1.1 503 "))

    def test_generator_writes_only_digest_and_hands_off_over_pipe(self):
        spec = importlib.util.spec_from_file_location("generate_token", ROOT / "generate-token.py")
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        output = io.StringIO()
        writer = self.folder / "writer"
        provisioned = self.folder / "new"
        provisioned.mkdir(mode=0o700)
        # Synthetic child actually receives an anonymous pipe, checks its
        # digest in memory and leaves no file. No mocking of production writes.
        writer.write_text(f"""#!{sys.executable}
import hashlib, json, os, stat, sys
from pathlib import Path
assert len(sys.argv) == 1
assert stat.S_ISFIFO(os.fstat(0).st_mode)
assert os.path.samestat(os.fstat(1), os.stat(os.devnull))
assert os.path.samestat(os.fstat(2), os.stat(os.devnull))
candidate = sys.stdin.buffer.read()
assert len(candidate) == 43
assert all(candidate not in value for value in os.environb.values())
doc = json.loads((Path(__file__).parent / 'new/verify.json').read_bytes())
assert hashlib.sha256(candidate).hexdigest() == doc['active_sha256']
""", encoding="ascii")
        writer.chmod(0o700)
        with (contextlib.redirect_stdout(output), contextlib.redirect_stderr(output),
              mock.patch.object(module.time, "time", return_value=NOW),
              mock.patch.object(module.secrets, "token_urlsafe", return_value=TOKEN.decode("ascii"))):
            module.generate(provisioned, writer)
            with self.assertRaises(FileExistsError):
                module.generate(provisioned, self.folder / "nonexistent")
            previous = self.folder / "previous.json"
            previous_doc = credentials_document(True) | {
                "active_sha256": digest(OLD_TOKEN), "previous_sha256": digest(WRONG_TOKEN),
            }
            common.atomic_write(previous, json.dumps(previous_doc).encode(), 0o600, owners=OWNERS)
            rotation = self.folder / "rotation"
            rotation.mkdir(mode=0o700)
            rotation_writer = self.folder / "rotation-writer"
            rotation_writer.write_text(writer.read_text().replace("new/verify.json", "rotation/verify.json"))
            rotation_writer.chmod(0o700)
            module.generate(rotation, rotation_writer, previous, 24)
            rejected = self.folder / "rejected"
            rejected.mkdir(mode=0o700)
            with self.assertRaises(subprocess.CalledProcessError):
                module.generate(rejected, Path("/usr/bin/false"))
        self.assertTrue(not output.getvalue(), "generator produced output")
        for directory, rolling in ((provisioned, False), (rotation, True)):
            path = directory / "verify.json"
            self.assertEqual(set(directory.iterdir()), {path})
            self.assertEqual(stat.S_IMODE(path.stat().st_mode), 0o600)
            credential = path.read_bytes()
            self.assertTrue(TOKEN not in credential and OLD_TOKEN not in credential,
                            "credential document contains a raw token")
            creds = api.Credentials.from_document(json.loads(credential))
            self.assertTrue(creds.allows(b"Bearer " + TOKEN, NOW))
            self.assertEqual(creds.allows(b"Bearer " + OLD_TOKEN, NOW), rolling)
            self.assertFalse(creds.allows(b"Bearer " + OLD_TOKEN, NOW + common.DAY))
            self.assertFalse(creds.allows(b"Bearer " + WRONG_TOKEN, NOW))
        self.assertEqual(list(rejected.iterdir()), [])


class CertificateTests(unittest.TestCase):
    def test_certificate_threshold_and_full_days(self):
        for delta, state, days in ((14*common.DAY+1, "ok", 14), (14*common.DAY, "expiring", 14),
                                   (14*common.DAY-1, "expiring", 13), (1, "expiring", 0),
                                   (0, "expired", 0), (-1, "expired", -1)):
            with self.subTest(delta=delta):
                cert = collector.certificate(NOW+delta, NOW)
                self.assertEqual((cert["state"], cert["days_remaining"]), (state, days))
                doc = private_snapshot()
                doc["certificate"] = cert
                self.assertEqual(common.project_snapshot(doc, BOOT, MONO)["certificate"], cert)
        self.assertEqual(collector.certificate(None, NOW),
                         {"state": "unknown", "expires_at": None, "days_remaining": None})

    def test_leaf_probe_pins_loopback_and_sni_and_uses_public_der_only(self):
        context = mock.MagicMock()
        context.wrap_socket.return_value.__enter__.return_value.getpeercert.return_value = b"public-der"
        tcp = mock.MagicMock()
        with (mock.patch.object(collector.ssl, "SSLContext", return_value=context),
              mock.patch.object(collector.socket, "create_connection", return_value=tcp) as connect,
              mock.patch.object(collector.subprocess, "run",
                                return_value=subprocess.CompletedProcess([], 0,
                                      b"notAfter=Nov 22 20:00:00 2026 GMT\n")) as openssl):
            self.assertEqual(collector.leaf_expiry(), common.parse_date("2026-11-22T20:00:00Z"))
        connect.assert_called_once_with(("127.0.0.1", 443), timeout=0.75)
        self.assertEqual(context.wrap_socket.call_args.kwargs, {"server_hostname": "66workshop.cn"})
        self.assertEqual(openssl.call_args.args[0], ["/usr/bin/openssl", "x509", "-noout", "-enddate"])
        self.assertTrue(openssl.call_args.kwargs["input"].startswith(b"-----BEGIN CERTIFICATE-----"))


class APITests(unittest.TestCase):
    def setUp(self):
        self.creds = api.Credentials.from_document(credentials_document())
        self.project = lambda: common.project_snapshot_response(private_snapshot(), BOOT, MONO)

    def send(self, req, snapshot=None, trailing=b""):
        return api.dispatch(req.removesuffix(b"\r\n\r\n"), trailing, self.creds, snapshot or self.project, NOW)

    def assert_response(self, reply, code, payload=None):
        header, body = reply.split(b"\r\n\r\n", 1)
        self.assertTrue(header.startswith(f"HTTP/1.1 {code} ".encode("ascii")))
        self.assertIn(b"\r\nCache-Control: no-store\r\n", header)
        self.assertIn(b"\r\nContent-Type: application/json\r\n", header)
        self.assertEqual(b"\r\nQuotaBar-Green-For-Ms: " in header, code == 200)
        for leak in (FAKE_PATH.encode(), FAKE_SECRET.encode(), str(FAKE_PID).encode(), TOKEN, OLD_TOKEN):
            self.assertNotIn(leak, reply)
        if payload is not None:
            self.assertEqual(json.loads(body), payload)
        return header, body

    def test_tokens_and_constant_two_comparisons(self):
        rotating = api.Credentials.from_document(credentials_document(True))
        for token, now, accepted in ((TOKEN, NOW, True), (OLD_TOKEN, NOW, True),
                                     (OLD_TOKEN, NOW+common.DAY-0.1, True),
                                     (OLD_TOKEN, NOW+common.DAY, False), (OLD_TOKEN, NOW-0.1, False),
                                     (WRONG_TOKEN, NOW, False)):
            with self.subTest(accepted=accepted), mock.patch.object(
                    api.hmac, "compare_digest", wraps=api.hmac.compare_digest) as compare:
                self.assertEqual(rotating.allows(b"bearer "+token, now), accepted)
                self.assertEqual(compare.call_count, 2)
                self.assertTrue(all(len(arg) == 32 for call in compare.call_args_list for arg in call.args))
        with mock.patch.object(api.hmac, "compare_digest", wraps=api.hmac.compare_digest) as compare:
            self.assertTrue(self.creds.allows(b"Bearer "+TOKEN, NOW))
            self.assertEqual(compare.call_count, 2)
        self.assertFalse(self.creds.allows(b"Bearer "+OLD_TOKEN, NOW))
        self.assertFalse(rotating.allows(b"Bearer "+b"A"*42+b"B", NOW))

    def test_invalid_credentials(self):
        for overrides in ({"active_sha256": FAKE_SECRET}, {"previous_sha256": digest(TOKEN)},
                          {"previous_until": NOW+common.DAY+1}, {"rotated_at": True},
                          {"previous_sha256": None}, {"unknown_field": False}):
            doc = credentials_document(True) | overrides
            with self.subTest(fields=list(overrides)), self.assertRaises(ValueError):
                api.Credentials.from_document(doc)

    def test_http_400_and_405(self):
        for req, trailing in ((request(path=api.PATH+b"?token="+TOKEN), b""),
                              (request(extra=b"Content-Length: 1\r\n"), b""),
                              (request(extra=b"Transfer-Encoding: chunked\r\n"), b""),
                              (request(extra=b"Content-Length: 0\r\nContent-Length: 0\r\n"), b""),
                              (request(extra=b" folded: nope\r\n"), b""),
                              (request(), b"body")):
            self.assert_response(self.send(req, trailing=trailing), 400, {"error": "bad_request"})
        for method in (b"POST", b"PUT", b"DELETE", b"OPTIONS", b"HEAD", b"TRACE"):
            header, body = self.assert_response(self.send(request(method)), 405)
            self.assertIn(b"\r\nAllow: GET", header)
            self.assertEqual(body, b"" if method == b"HEAD" else b'{"error":"method_not_allowed"}\n')

    def test_http_401_and_200(self):
        forbidden_reads = mock.Mock(side_effect=AssertionError("must not read snapshot"))
        for auth, extra in ((None, b""), (b"Basic invalid", b""),
                            (b"Bearer "+WRONG_TOKEN, b""),
                            (b"Bearer "+TOKEN, b"Authorization: Bearer "+TOKEN+b"\r\n")):
            header, _ = self.assert_response(
                self.send(request(authorization=auth, extra=extra), snapshot=forbidden_reads),
                401, {"error": "unauthorized"})
            self.assertIn(b"\r\nWWW-Authenticate: Bearer", header)
        forbidden_reads.assert_not_called()
        self.assert_response(self.send(request()), 200, self.project()[0])

    def test_aggregate_green_header_uses_unrounded_lease_and_pong_cutoffs(self):
        for heartbeat, pong, lease, age, expected in (
            (0, 0, None, 0, 60000),
            (85, 0, None, 0, 5000),  # Feishu heartbeat is the earliest cutoff.
            (0, 55, None, 0, 5000),  # Earlier than the public WeCom sample.
            (0, 55, None, 4.125, 875),
            (0, 55, None, 5, 0),     # Still ready at the strict pong boundary.
            (0, 55, None, 5.125, 69875),  # Only Feishu is still green.
            (0, 0, 10.1259, 0, 10125),
            (0, 0, 10.1259, 4.25, 5875),
            (0, 0, 10.1259, 10.125, 0),  # Positive sub-ms lifetime floors to zero.
            (0, 0, 10, 10, 0),
        ):
            with self.subTest(heartbeat=heartbeat, pong=pong, lease=lease, age=age):
                doc = private_snapshot()
                doc["feishu"] = connection("feishu", feishu(age=heartbeat))
                doc["wecom"] = connection("wecom", wecom(age=0, pong=pong))
                doc["lease_clear_for_s"] = lease
                read = lambda: common.project_snapshot_response(doc, BOOT, MONO + age)
                header, body = self.assert_response(self.send(request(), snapshot=read), 200)
                self.assertIn(f"QuotaBar-Green-For-Ms: {expected}".encode("ascii"), header.split(b"\r\n"))
                self.assertEqual(json.loads(body), common.project_snapshot(doc, BOOT, MONO + age))
                self.assertNotIn(b"lease_clear_for_s", body)
                self.assertNotIn(b"effective_pong_age_s", body)

    def test_green_header_covers_each_ready_row_in_mixed_responses(self):
        for feishu_down, age, expected, reasons in (
            (True, 0, 5000, ("unit_down", "ready")),
            (True, 4.125, 875, ("unit_down", "ready")),
            (True, 5, 0, ("unit_down", "ready")),
            (True, 20, 0, ("unit_down", "pong_late")),
            (False, 0, 5000, ("ready", "reconnecting")),
            (False, 5.125, 0, ("heartbeat_late", "reconnecting")),
        ):
            with self.subTest(feishu_down=feishu_down, age=age):
                doc = private_snapshot()
                if feishu_down:
                    doc["feishu"] = {"state": "down", "reason": "unit_down", "last_heartbeat_at": common.rfc3339(NOW)}
                    doc["wecom"] = connection("wecom", wecom(pong=55))
                else:
                    doc["feishu"] = connection("feishu", feishu(age=85))
                    doc["wecom"] = connection("wecom", wecom(state="reconnecting"))
                read = lambda: common.project_snapshot_response(doc, BOOT, MONO + age)
                header, body = self.assert_response(self.send(request(), snapshot=read), 200)
                self.assertIn(f"QuotaBar-Green-For-Ms: {expected}".encode("ascii"), header.split(b"\r\n"))
                public = json.loads(body)
                self.assertEqual(tuple(public[name]["reason"] for name in ("feishu", "wecom")), reasons)

    def test_http_503_missing_bad_or_stale_snapshot(self):
        def stale():
            return common.project_snapshot_response(private_snapshot(), BOOT, MONO+75.001)
        for read in (stale, mock.Mock(side_effect=FileNotFoundError(FAKE_PATH)),
                     lambda: common.decode_object(b"{invalid")):
            self.assert_response(self.send(request(), snapshot=read), 503,
                                 {"error": "service_unavailable"})

    def test_api_rejects_missing_or_malformed_private_lease_cutoff(self):
        for cutoff in (None, True, 0, -1, "10", float("inf")):
            with self.subTest(cutoff=cutoff):
                doc = private_snapshot()
                if cutoff is None:
                    del doc["lease_clear_for_s"]
                else:
                    doc["lease_clear_for_s"] = cutoff
                read = lambda: common.project_snapshot_response(doc, BOOT, MONO)
                self.assert_response(self.send(request(), snapshot=read), 503,
                                     {"error": "service_unavailable"})

    def test_api_rejects_green_incompatible_with_observation(self):
        for name, cases in (
            ("feishu", ((89.9, 200), (90, 200), (91, 503), (181, 503), (-5, 200), (-6, 503))),
            ("wecom", ((59.9, 200), (60, 200), (61, 503), (89.9, 503), (90, 503), (181, 503),
                       (-5, 200), (-6, 503))),
        ):
            for age, code in cases:
                with self.subTest(name=name, age=age):
                    doc = private_snapshot()
                    doc[name]["last_heartbeat_at"] = common.rfc3339(NOW - age)
                    if name == "wecom":
                        doc[name]["effective_pong_age_s"] = min(60, max(0, age))
                    def read():
                        return common.project_snapshot_response(doc, BOOT, MONO)
                    self.assert_response(self.send(request(), snapshot=read), code)
        # Equal serialized age is valid regardless of observation fraction.
        doc = private_snapshot()
        doc["observed_at"] = common.rfc3339(NOW + 0.999)
        doc["feishu"]["last_heartbeat_at"] = common.rfc3339(NOW - 90 + 0.999)
        self.assertEqual(common.project_snapshot(doc, BOOT, MONO)["feishu"]["state"], "ok")

    def test_api_downgrades_each_green_at_its_response_time_deadline(self):
        doc = private_snapshot()
        doc["feishu"] = connection("feishu", feishu(age=85))
        doc["wecom"] = connection("wecom", wecom(age=45, pong=10))
        original = json.dumps(doc)
        for delay, feishu_state, wecom_state in (
            (0, "ready", "ready"), (5, "ready", "ready"),
            (5.125, "heartbeat_late", "pong_late"),
            (25, "heartbeat_late", "pong_late"), (45, "heartbeat_late", "pong_late"),
            (45.125, "heartbeat_late", "heartbeat_late"), (75, "heartbeat_late", "heartbeat_late"),
        ):
            with self.subTest(delay=delay):
                def read():
                    return common.project_snapshot_response(doc, BOOT, MONO + delay)

                _, body = self.assert_response(self.send(request(), snapshot=read), 200)
                public = json.loads(body)
                self.assertEqual(public["snapshot_age_s"], int(delay))
                for name, reason in (("feishu", feishu_state), ("wecom", wecom_state)):
                    self.assertEqual(public[name], {
                        "state": "ok" if reason == "ready" else "degraded", "reason": reason,
                        "last_heartbeat_at": doc[name]["last_heartbeat_at"],
                    })
        self.assertEqual(json.dumps(doc), original)
        stale = lambda: common.project_snapshot_response(doc, BOOT, MONO + 75.125)
        self.assert_response(self.send(request(), snapshot=stale), 503, {"error": "service_unavailable"})

        # The earlier pong deadline does not alter the Feishu projection.
        doc["feishu"] = connection("feishu", feishu(age=80))
        read = lambda: common.project_snapshot_response(doc, BOOT, MONO + 6)
        _, body = self.assert_response(self.send(request(), snapshot=read), 200)
        public = json.loads(body)
        self.assertEqual((public["feishu"]["reason"], public["wecom"]["reason"]), ("ready", "pong_late"))

        # An expired lease only removes green; current-instance yellow takes priority.
        doc["lease_clear_for_s"] = 6
        _, body = self.assert_response(self.send(request(), snapshot=read), 200)
        public = json.loads(body)
        self.assertEqual((public["feishu"]["reason"], public["wecom"]["reason"]),
                         ("source_unavailable", "pong_late"))

    def test_api_expires_lease_dependent_green_without_recollecting(self):
        # Use a fractional observation time so deriving the deadline from
        # the public, whole-second observed_at would be detectably wrong.
        observed = NOW + 0.25
        units = dict.fromkeys(collector.UNITS, ACTIVE_UNIT)
        for expired_clear, expiry in (
            (False, observed + 10), (False, common.rfc3339(NOW + 11)),
            (True, observed + 10),
        ):
            with self.subTest(expired_clear=expired_clear, expiry=expiry):
                lease = ({"state": "LEASE", "ecs_stopped": False, "expires_at": expiry}, NOW)
                policy = collector.Policy(True, True, expired_lease_clear=expired_clear)
                with (mock.patch.object(collector, "boot_id", return_value=BOOT),
                      mock.patch.object(collector, "boot_clock", return_value=MONO),
                      mock.patch.object(collector, "read_policy", return_value=policy),
                      mock.patch.object(collector.pwd, "getpwnam", return_value=mock.Mock(pw_uid=1234)),
                      mock.patch.object(collector.grp, "getgrnam", return_value=mock.Mock(gr_gid=1234)),
                      mock.patch.object(collector, "leaf_expiry", return_value=None),
                      mock.patch.object(collector, "load_units", return_value=units),
                      mock.patch.object(collector, "source", side_effect=[feishu(), wecom(), lease]),
                      mock.patch.object(collector.time, "time", return_value=observed),
                      mock.patch.object(collector.time, "monotonic", return_value=MONO),
                      mock.patch.object(collector, "atomic_write") as write):
                    collector.collect()
                blob = write.call_args.args[1]
                doc = common.decode_object(blob)
                deadline = (common.parse_date(expiry) if isinstance(expiry, str) else expiry) - observed
                for delay in (0, deadline - 0.125, deadline, deadline + 0.125, 25):
                    with self.subTest(delay=delay):
                        def read():
                            return common.project_snapshot_response(doc, BOOT, MONO + delay)

                        _, body = self.assert_response(self.send(request(), snapshot=read), 200)
                        public = json.loads(body)
                        self.assertEqual(set(public), {"schema_version", "observed_at", "snapshot_age_s",
                                                       "feishu", "wecom", "certificate"})
                        expected = ("unknown", "source_unavailable") if (
                            not expired_clear and delay >= deadline) else ("ok", "ready")
                        for name in ("feishu", "wecom"):
                            self.assertEqual(public[name], {
                                "state": expected[0], "reason": expected[1],
                                "last_heartbeat_at": common.rfc3339(NOW),
                            })
                self.assertEqual(doc, common.decode_object(blob))

    def test_api_turns_yellow_heartbeat_and_pong_red_in_a_fresh_snapshot(self):
        doc = private_snapshot()
        doc["feishu"] = connection("feishu", feishu(age=170))
        doc["wecom"] = connection("wecom", wecom(age=10, pong=160))
        original = json.dumps(doc)
        for delay, state, heartbeat_reason, pong_reason in (
            (0, "degraded", "heartbeat_late", "pong_late"),
            (10, "degraded", "heartbeat_late", "pong_late"),
            (10.125, "down", "heartbeat_stale", "pong_stale"),
            (25, "down", "heartbeat_stale", "pong_stale"),
        ):
            with self.subTest(delay=delay):
                def read():
                    return common.project_snapshot_response(doc, BOOT, MONO + delay)

                _, body = self.assert_response(self.send(request(), snapshot=read), 200)
                public = json.loads(body)
                self.assertEqual(public["snapshot_age_s"], int(delay))
                for name, reason in (("feishu", heartbeat_reason), ("wecom", pong_reason)):
                    with self.subTest(channel=name):
                        self.assertEqual(public[name], {
                            "state": state, "reason": reason,
                            "last_heartbeat_at": doc[name]["last_heartbeat_at"],
                        })
        self.assertEqual(json.dumps(doc), original)

    def test_response_time_staleness_respects_evidence_precedence(self):
        stopped = collector.Unit("inactive", 0, 0, "")
        transitioning = collector.Unit("activating", 0, 0, "")
        for name, status, before, after in (
            ("wecom", connection("wecom", wecom(age=170)), "heartbeat_late", "heartbeat_stale"),
            ("wecom", connection("wecom", wecom(pong=170, state="reconnecting")),
             "reconnecting", "pong_stale"),
            ("feishu", connection("feishu", feishu(age=170), unit=stopped), "unit_down", "unit_down"),
            ("feishu", connection("feishu", feishu(age=170), unit=stopped, lease="stopped"),
             "paused_by_lease", "paused_by_lease"),
            ("feishu", connection("feishu", feishu(age=170), unit=transitioning),
             "transitioning", "transitioning"),
            ("feishu", connection("feishu", feishu(age=170), unit=None),
             "source_unavailable", "source_unavailable"),
        ):
            with self.subTest(name=name, reason=before):
                self.assertEqual(status["reason"], before)
                doc = private_snapshot()
                doc["lease_clear_for_s"] = 10
                doc[name] = status
                result = common.project_snapshot(doc, BOOT, MONO + 25)[name]
                self.assertEqual(result["reason"], after)
                self.assertEqual(result["state"], "down" if after.endswith("_stale") else status["state"])

    def test_fixed_429_contract_and_nginx_mapping(self):
        header, _ = self.assert_response(api.response(429), 429, {"error": "rate_limited"})
        self.assertIn(b"\r\nRetry-After: 30", header)
        limits = (ROOT / "nginx/limits.conf").read_text()
        location = (ROOT / "nginx/location.conf").read_text()
        for required in ("$binary_remote_addr zone=quotabar_status_ip:1m rate=12r/m",
                         "$server_name zone=quotabar_status_all:1m rate=60r/m"):
            self.assertIn(required, limits)
        for required in ("location = /api/relay-status/v1", "burst=4 nodelay", "burst=10 nodelay",
                         "limit_req_status 429", "Retry-After 30 always", "error_page 502 504",
                         "return 503", "access_log off"):
            self.assertIn(required, location)
        self.assertNotIn("X-Forwarded-For", location)

    def test_unix_socket_roundtrip_and_header_limit_without_tcp(self):
        tmp = Path(tempfile.gettempdir()).resolve()
        with tempfile.TemporaryDirectory(prefix="qb-", dir=tmp) as directory:
            path = Path(directory) / "s"
            previous = os.umask(0o117)
            try:
                server = api.Server(path, self.creds, self.project)
            finally:
                os.umask(previous)
            with server:
                self.assertEqual(stat.S_IMODE(path.stat().st_mode), 0o660)
                thread = threading.Thread(target=server.serve_forever, kwargs={"poll_interval": 0.01})
                thread.start()
                try:
                    for raw, code, body in ((request(), 200, self.project()[0]),
                                            (request(authorization=None), 401, {"error": "unauthorized"}),
                                            (b"G" * api.HEADER_LIMIT, 400, {"error": "bad_request"})):
                        with socket.socket(socket.AF_UNIX) as sock:
                            sock.settimeout(2)
                            sock.connect(str(path))
                            sock.sendall(raw)
                            with sock.makefile("rb") as stream:
                                self.assert_response(stream.read(), code, body)
                finally:
                    server.shutdown()
                    thread.join(timeout=2)


if __name__ == "__main__":
    unittest.main()
