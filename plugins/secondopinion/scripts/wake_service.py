#!/usr/bin/env python3
"""Installer lifecycle for the local worker-result bridge (Linux user systemd).

Codex owns its app server: `codex app-server daemon start` reuses a running one
or launches Codex's managed server, which Codex keeps updated. Removing this
plugin stops only secondopinion's bridge.
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

UNIT = "secondopinion-wakeup.service"
# Written by 1.1.0-1.2.2. It pinned the Codex binary found at install time, and
# Codex never updates a server it did not start, so new Codex releases (and the
# models the backend offers only to them) stayed hidden. Install retires it.
LEGACY_CODEX_UNIT = "codex-local-app-server.service"
LEGACY_CODEX_HEADER = "# Shared Codex runtime provisioned by secondopinion; retained on plugin removal.\n"
UNMANAGED_WARNING = ("the running Codex app server was not started by Codex, so Codex will not update it and "
                     "newer models stay hidden; stop whatever runs it, then run `codex app-server daemon start`")


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


def legacy_codex_unit(unit_dir):
    legacy = unit_dir / LEGACY_CODEX_UNIT
    if legacy.is_symlink() or not legacy.is_file():
        return None
    return legacy if legacy.read_text().startswith(LEGACY_CODEX_HEADER) else None


def retire_legacy_codex_unit(unit_dir):
    # Only the exact unit this installer wrote; a same-named user unit is left alone.
    legacy = legacy_codex_unit(unit_dir)
    if legacy is None:
        return False
    run(["systemctl", "--user", "disable", "--now", LEGACY_CODEX_UNIT])
    legacy.unlink()
    run(["systemctl", "--user", "daemon-reload"])
    return True


def version_key(value):
    try:
        return tuple(int(part) for part in str(value).split("-")[0].split("."))
    except ValueError:
        return None


def codex_runtime(output):
    """Summarize `codex app-server daemon start|version` JSON; flag a server Codex will not update."""
    try:
        info = json.loads(output.strip().splitlines()[-1])
    except (ValueError, IndexError):
        return {"codex_runtime": "unknown"}
    report = {"codex_runtime": "codex_managed" if info.get("backend") else "unmanaged",
              "codex_cli_version": info.get("cliVersion"), "codex_app_server_version": info.get("appServerVersion")}
    cli, server = version_key(info.get("cliVersion")), version_key(info.get("appServerVersion"))
    if not info.get("backend"):
        report["warning"] = UNMANAGED_WARNING
    elif cli and server and server < cli:
        # Codex's updater normally closes this within its hourly check.
        report["warning"] = ("Codex app server " + str(info.get("appServerVersion")) + " is older than CLI " +
                             str(info.get("cliVersion")) + "; if this persists, run `codex app-server daemon update`")
    return report


def ensure_codex(codex):
    # Never pin a Codex binary or supervise Codex here: that is what hid updates.
    result = run([codex, "app-server", "daemon", "start"], False)
    if result.returncode:
        raise RuntimeError("Codex could not start its local app server: " + (result.stderr or result.stdout).strip()[:1200])
    return codex_runtime(result.stdout)


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
        runtime = {}
        if healthy:
            check_owned(unit, record)
            version = run(["codex", "app-server", "daemon", "version"], False)
            healthy = version.returncode == 0
            runtime = codex_runtime(version.stdout) if healthy else {
                "reason": "no Codex app server is running; opening Codex starts it"}
        if legacy_codex_unit(unit.parent):
            runtime["warning"] = ("legacy " + LEGACY_CODEX_UNIT + " pins an old Codex binary and blocks Codex "
                                  "updates; rerun install.sh to retire it")
        return dict({"automatic_worker_return": "ready" if healthy else "unavailable"}, **runtime)
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
    # Codex's own server lifecycle only; no CLI update, remote-control switch,
    # credential copying, shell wrapper, or permission override.
    retired = retire_legacy_codex_unit(unit.parent)
    runtime = ensure_codex(codex)
    if retired:
        runtime["legacy_codex_unit"] = "retired"
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
    return dict({"automatic_worker_return": "ready", "unit": UNIT}, **runtime)


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
