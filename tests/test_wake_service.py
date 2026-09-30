#!/usr/bin/env python3
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest import mock

sys.dont_write_bytecode = True
sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "plugins/secondopinion/scripts"))
import wake_service as service

MANAGED = json.dumps({"status": "running", "backend": "pid", "managedCodexVersion": "0.159.2",
                      "cliVersion": "0.159.2", "appServerVersion": "0.159.2"})
# Shape reported on 2026-09-29 by a server run from the unit 1.1.0-1.2.2 wrote.
UNMANAGED = json.dumps({"status": "running", "managedCodexPath": "/h/.codex/packages/app-server-daemon/current/bin/codex",
                        "managedCodexVersion": None, "socketPath": "/h/.codex/app-server-control/app-server-control.sock",
                        "cliVersion": "0.159.2", "appServerVersion": "0.156.1"})
LEGACY_UNIT = (service.LEGACY_CODEX_HEADER + "[Unit]\nDescription=Codex local app server\n\n[Service]\n"
               'ExecStart=:"/h/.nvm/versions/node/v24.7.0/bin/codex" app-server --listen unix://\n')


class ServiceTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix="secondopinion-service-")
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.store = self.root / "store"
        self.unit = self.root / "user" / service.UNIT
        self.record = self.store / ".wake-service-install.json"
        self.path_mock = mock.patch.object(service, "paths", return_value=(self.unit, self.record))
        self.path_mock.start()
        self.addCleanup(self.path_mock.stop)
        self.calls = []
        def fake(argv, check=True):
            self.calls.append(argv)
            return subprocess.CompletedProcess(argv, 0, MANAGED if argv[1:3] == ["app-server", "daemon"] else "active", "")
        self.run_mock = mock.patch.object(service, "run", side_effect=fake)
        self.run_mock.start()
        self.addCleanup(self.run_mock.stop)

    def install(self):
        return service.manage("install", self.store)

    def test_installs_owned_private_unit_and_lets_codex_own_its_server(self):
        result = self.install()
        self.assertEqual(result["automatic_worker_return"], "ready")
        self.assertEqual(result["codex_runtime"], "codex_managed")
        self.assertNotIn("warning", result)
        self.assertEqual(self.unit.stat().st_mode & 0o777, 0o600)
        self.assertEqual(self.record.stat().st_mode & 0o777, 0o600)
        self.assertTrue(any(c[1:] == ["app-server", "daemon", "start"] for c in self.calls))
        self.assertFalse(any("bootstrap" in c or "update" in c for c in self.calls))
        self.assertFalse(any("--remote-control" in c for c in self.calls))
        self.assertFalse(any(service.LEGACY_CODEX_UNIT in c for c in self.calls))
        self.assertEqual(sorted(p.name for p in self.unit.parent.iterdir()), [service.UNIT])
        self.assertIn("Restart=always", self.unit.read_text())
        self.assertNotIn("ExecStartPre", self.unit.read_text())

    def test_idempotent_install(self):
        self.install()
        before = self.unit.read_bytes()
        self.install()
        self.assertEqual(self.unit.read_bytes(), before)
        service.check_owned(self.unit, self.record)

    def test_check_is_read_only_and_does_not_start_anything(self):
        self.install()
        before = (self.unit.read_bytes(), self.record.read_bytes())
        self.calls.clear()
        self.assertEqual(service.manage("check", self.store)["automatic_worker_return"], "ready")
        self.assertEqual((self.unit.read_bytes(), self.record.read_bytes()), before)
        self.assertFalse(any("bootstrap" in c or "restart" in c or "enable" in c or "start" in c for c in self.calls))

    def test_check_uninstalled_does_not_create_store(self):
        self.assertEqual(service.manage("check", self.store)["automatic_worker_return"], "unavailable")
        self.assertFalse(self.store.exists())

    def test_uninstall_stops_only_plugin_service(self):
        self.install()
        self.calls.clear()
        result = service.manage("uninstall", self.store)
        self.assertEqual(result["automatic_worker_return"], "removed")
        self.assertFalse(self.unit.exists())
        self.assertFalse(self.record.exists())
        self.assertFalse(any("codex" in Path(c[0]).name for c in self.calls))
        self.assertIn(["systemctl", "--user", "disable", "--now", service.UNIT], self.calls)

    def test_modified_unit_is_preserved_on_update_and_uninstall(self):
        self.install()
        self.unit.write_text(self.unit.read_text() + "# owner customization\n")
        before = self.unit.read_bytes()
        for action in ("install", "uninstall", "check"):
            self.calls.clear()
            with self.assertRaises(ValueError):
                service.manage(action, self.store)
            self.assertEqual(self.unit.read_bytes(), before)
            self.assertFalse(any("restart" in c or "disable" in c for c in self.calls))

    def test_unowned_name_collision_is_preserved(self):
        self.unit.parent.mkdir()
        self.unit.write_text("unrelated unit")
        with self.assertRaises(ValueError):
            self.install()
        self.assertEqual(self.unit.read_text(), "unrelated unit")

    def test_unit_symlink_rejected(self):
        self.unit.parent.mkdir()
        self.unit.symlink_to(self.root / "other")
        with self.assertRaises(ValueError):
            self.install()

    def test_no_user_manager_preserves_foreground_installation(self):
        with mock.patch.object(service, "run", return_value=subprocess.CompletedProcess([], 1, "", "no bus")):
            self.assertEqual(self.install()["automatic_worker_return"], "unavailable")
        self.assertFalse(self.unit.exists())

    def test_isolated_home_never_contacts_real_user_manager(self):
        with mock.patch.object(service, "paths", return_value=(None, None)):
            self.assertEqual(self.install()["automatic_worker_return"], "not_provisioned")
        self.assertEqual(self.calls, [])

    def test_service_arguments_cannot_expand_percent_or_environment(self):
        unit = service.unit_text('/space a/$x/%s/"script.py', self.store, "/usr/bin/python3", "/usr/bin:/bin")
        self.assertIn('ExecStart=:"/usr/bin/python3" -B "/space a/$x/%%s/\\"script.py"', unit)
        self.assertNotIn("After=default.target", unit)
        with self.assertRaises(ValueError):
            service.quote("bad\nExecStart=/bad")

    def test_legacy_pinned_codex_unit_is_retired_before_codex_starts_its_own(self):
        legacy = self.unit.parent / service.LEGACY_CODEX_UNIT
        legacy.parent.mkdir()
        legacy.write_text(LEGACY_UNIT)
        result = self.install()
        self.assertEqual(result["legacy_codex_unit"], "retired")
        self.assertFalse(legacy.exists())
        retire = self.calls.index(["systemctl", "--user", "disable", "--now", service.LEGACY_CODEX_UNIT])
        start = next(i for i, c in enumerate(self.calls) if c[1:] == ["app-server", "daemon", "start"])
        self.assertLess(retire, start)
        self.calls.clear()
        service.manage("uninstall", self.store)
        self.assertFalse(any("codex" in Path(c[0]).name for c in self.calls))

    def test_same_named_user_codex_unit_is_preserved(self):
        foreign = self.unit.parent / service.LEGACY_CODEX_UNIT
        foreign.parent.mkdir()
        foreign.write_text("[Service]\nExecStart=/usr/local/bin/codex app-server --listen unix://\n")
        before = foreign.read_bytes()
        self.assertNotIn("legacy_codex_unit", self.install())
        self.assertEqual(foreign.read_bytes(), before)
        self.assertFalse(any(service.LEGACY_CODEX_UNIT in c for c in self.calls))

    def test_codex_start_failure_installs_nothing(self):
        def commands(argv, check=True):
            self.calls.append(argv)
            rc = 1 if argv[1:] == ["app-server", "daemon", "start"] else 0
            return subprocess.CompletedProcess(argv, rc, "", "this CLI has no complete local package")
        with mock.patch.object(service, "run", side_effect=commands):
            with self.assertRaisesRegex(RuntimeError, "no complete local package"):
                self.install()
        self.assertFalse(self.unit.exists())
        self.assertFalse(self.record.exists())

    def test_check_flags_a_server_codex_will_not_update(self):
        self.install()
        def commands(argv, check=True):
            self.calls.append(argv)
            return subprocess.CompletedProcess(argv, 0, UNMANAGED if argv[1:3] == ["app-server", "daemon"] else "active", "")
        with mock.patch.object(service, "run", side_effect=commands):
            result = service.manage("check", self.store)
        self.assertEqual(result["automatic_worker_return"], "ready")
        self.assertEqual((result["codex_runtime"], result["codex_app_server_version"]), ("unmanaged", "0.156.1"))
        self.assertIn("will not update it", result["warning"])

    def test_check_flags_leftover_legacy_unit(self):
        self.install()
        (self.unit.parent / service.LEGACY_CODEX_UNIT).write_text(LEGACY_UNIT)
        self.assertIn("rerun install.sh", service.manage("check", self.store)["warning"])

    def test_check_without_running_codex_server_explains_how_it_starts(self):
        self.install()
        def commands(argv, check=True):
            self.calls.append(argv)
            return subprocess.CompletedProcess(argv, 1 if argv[1:3] == ["app-server", "daemon"] else 0, "active", "")
        with mock.patch.object(service, "run", side_effect=commands):
            result = service.manage("check", self.store)
        self.assertEqual(result["automatic_worker_return"], "unavailable")
        self.assertIn("opening Codex starts it", result["reason"])

    def test_codex_runtime_versions(self):
        managed = json.loads(MANAGED)
        older = json.dumps(dict(managed, appServerVersion="0.158.0"))
        newer = json.dumps(dict(managed, appServerVersion="0.160.0"))
        self.assertIn("older than CLI 0.159.2", service.codex_runtime(older)["warning"])
        self.assertNotIn("warning", service.codex_runtime(newer))
        self.assertNotIn("warning", service.codex_runtime("Installing daemon...\n" + MANAGED))
        self.assertEqual(service.codex_runtime("not json"), {"codex_runtime": "unknown"})

    def test_interrupted_unit_replacement_recovers(self):
        self.install()
        original = self.unit.read_text()
        staged = json.loads(self.record.read_text())
        staged["previous_sha256"] = staged["sha256"]
        staged["sha256"] = service.sha(original + "# new generation\n")
        self.record.write_text(json.dumps(staged))
        service.check_owned(self.unit, self.record)
        self.install()
        self.assertNotIn("previous_sha256", json.loads(self.record.read_text()))


if __name__ == "__main__":
    unittest.main(verbosity=2)
