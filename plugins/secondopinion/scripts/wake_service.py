#!/usr/bin/env python3
"""Installer lifecycle for the local worker-result bridge (Linux user systemd).

Codex's public app-server runs in a separate user service (or an existing
daemon is reused). Removing this plugin stops only secondopinion's bridge.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import pwd
import shutil
import subprocess
import sys
import tempfile
import time

UNIT = "secondopinion-wakeup.service"
CODEX_UNIT = "codex-local-app-server.service"


def run(argv, check=True):
    result = subprocess.run(argv, text=True, capture_output=True, timeout=120)
    if check and result.returncode:
        raise RuntimeError(" ".join(argv[:4]) + ": " + (result.stderr or result.stdout).strip()[:1200])
    return result


def quote(value):
    if any(ord(c) < 32 for c in str(value)):
        raise ValueError("service paths/environment must not contain control characters")
    return '"' + str(value).replace("\\", "\\\\").replace('"', '\\"').replace("%", "%%") + '"'


def unit_text(script, store, python, path):
    return ("# Managed by secondopinion; local notification delivery only.\n"
            "[Unit]\nDescription=Secondopinion worker result notifications\n"
            "\n[Service]\nType=simple\n"
            "ExecStart=:" + quote(python) + " -B " + quote(script) + " --store " + quote(store) + " serve\n"
            "Environment=" + quote("PATH=" + path) + "\n"
            "Restart=always\nRestartSec=3\nTimeoutStopSec=10\nUMask=0077\n"
            "NoNewPrivileges=yes\n\n[Install]\nWantedBy=default.target\n")


def codex_unit_text(codex, path):
    return ("# Shared Codex runtime provisioned by secondopinion; retained on plugin removal.\n"
            "[Unit]\nDescription=Codex local app server\n\n[Service]\nType=simple\n"
            "ExecStart=:" + quote(codex) + " app-server --listen unix://\n"
            "Environment=" + quote("PATH=" + path) + "\n"
            "Restart=always\nRestartSec=3\nTimeoutStopSec=30\nUMask=0077\n"
            "\n[Install]\nWantedBy=default.target\n")


def ensure_codex(unit_dir, codex, path):
    # Reuse an existing public server. Never stop/restart it or change its policy.
    probe = [codex, "app-server", "daemon", "version"]
    if run(probe, False).returncode == 0:
        return "existing"
    runtime_unit = unit_dir / CODEX_UNIT
    text = codex_unit_text(codex, path)
    if runtime_unit.is_symlink() or (runtime_unit.exists() and runtime_unit.read_text() != text):
        raise ValueError("existing Codex runtime unit differs; preserved without overwriting")
    unit_dir.mkdir(parents=True, exist_ok=True)
    if not runtime_unit.exists():
        atomic_text(runtime_unit, text)
    run(["systemctl", "--user", "daemon-reload"])
    run(["systemctl", "--user", "enable", "--now", CODEX_UNIT])
    for _ in range(30):
        if run(probe, False).returncode == 0:
            return CODEX_UNIT
        time.sleep(0.5)
    raise RuntimeError("local Codex server did not become ready; inspect " + CODEX_UNIT)


def sha(text):
    return hashlib.sha256(text.encode()).hexdigest()


def atomic_text(path, text):
    fd, temporary = tempfile.mkstemp(prefix=path.name + ".", suffix=".tmp", dir=path.parent)
    try:
        with os.fdopen(fd, "w") as stream:
            stream.write(text)
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(temporary, path)
        directory = os.open(path.parent, os.O_RDONLY | os.O_DIRECTORY)
        try:
            os.fsync(directory)
        finally:
            os.close(directory)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)


def paths(store):
    # A test/alternate HOME must never talk to the real user's systemd manager.
    user_home = Path(pwd.getpwuid(os.getuid()).pw_dir).resolve()
    if Path.home().resolve() != user_home:
        return None, None
    if Path(os.environ.get("CODEX_HOME", str(user_home / ".codex"))).resolve() != user_home / ".codex":
        return None, None
    return user_home / ".config/systemd/user" / UNIT, Path(store) / ".wake-service-install.json"


def check_owned(unit, record):
    if unit.is_symlink() or record.is_symlink():
        raise ValueError("refusing symlinked wakeup service installation files")
    if not unit.exists():
        return
    if not record.exists():
        raise ValueError("wakeup service name is already used by an unowned unit")
    meta = json.loads(record.read_text())
    if meta.get("unit") != str(unit) or sha(unit.read_text()) not in (meta.get("sha256"), meta.get("previous_sha256")):
        raise ValueError("wakeup unit was modified outside the installer; preserved without overwriting")


def manage(action, store):
    store = Path(store).resolve()
    unit, record = paths(store)
    if unit is None:
        return {"automatic_worker_return": "not_provisioned", "reason": "isolated/alternate home; foreground workflows remain available"}
    if action == "uninstall" and not record.exists():
        return {"automatic_worker_return": "not_installed"}
    if not shutil.which("systemctl") or run(["systemctl", "--user", "show-environment"], False).returncode:
        if action == "uninstall" and record.exists():
            raise RuntimeError("cannot stop the installed worker-return service: user systemd is unavailable")
        return {"automatic_worker_return": "unavailable", "reason": "user systemd unavailable; foreground workflows remain available"}
    if action == "check":
        healthy = (record.exists() and unit.exists() and
                   run(["systemctl", "--user", "is-enabled", UNIT], False).returncode == 0 and
                   run(["systemctl", "--user", "is-active", UNIT], False).returncode == 0)
        if healthy:
            check_owned(unit, record)
            healthy = run(["codex", "app-server", "daemon", "version"], False).returncode == 0
        return {"automatic_worker_return": "ready" if healthy else "unavailable"}
    check_owned(unit, record)
    if action == "uninstall":
        run(["systemctl", "--user", "disable", "--now", UNIT])
        if unit.exists():
            unit.unlink()
        record.unlink()
        run(["systemctl", "--user", "daemon-reload"])
        return {"automatic_worker_return": "removed", "shared_codex_daemon": "retained; managed by Codex, not this plugin"}
    codex = shutil.which("codex")
    python = shutil.which("python3")
    if not codex or not python:
        raise RuntimeError("automatic worker return requires codex and python3")
    text = unit_text(Path(__file__).with_name("codex_wakeup.py"), store, python, os.environ.get("PATH", "/usr/bin:/bin"))
    # Public runtime only; no standalone installation, CLI update, remote-control
    # switch, credential copying, shell wrapper, or permission override.
    runtime = ensure_codex(unit.parent, codex, os.environ.get("PATH", "/usr/bin:/bin"))
    store.mkdir(mode=0o700, parents=True, exist_ok=True)
    unit.parent.mkdir(parents=True, exist_ok=True)
    # Journal both allowed generations before replacement. A crash between the
    # two atomic files is recoverable on reinstall without accepting user edits.
    metadata = {"unit": str(unit), "sha256": sha(text)}
    staged = dict(metadata, previous_sha256=sha(unit.read_text()) if unit.exists() else None)
    atomic_text(record, json.dumps(staged) + "\n")
    atomic_text(unit, text)
    atomic_text(record, json.dumps(metadata) + "\n")
    run(["systemctl", "--user", "daemon-reload"])
    run(["systemctl", "--user", "enable", "--now", UNIT])
    run(["systemctl", "--user", "restart", UNIT])
    run(["systemctl", "--user", "is-active", UNIT])
    return {"automatic_worker_return": "ready", "unit": UNIT, "codex_runtime": runtime}


def main():
    os.umask(0o077)
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("action", choices=("install", "check", "uninstall"))
    parser.add_argument("--store", required=True)
    args = parser.parse_args()
    try:
        result = manage(args.action, args.store)
        print(json.dumps(result))
        return 0
    except (OSError, ValueError, RuntimeError, subprocess.TimeoutExpired) as error:
        print("ERROR: worker return setup: " + str(error), file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
