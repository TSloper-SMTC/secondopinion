#!/usr/bin/env python3
"""Qualify ordinary Codex's automatic connection to an already-running server.

Host-only opt-in canary. Refuses an existing default socket; starts/stops only
its own server and conversation. Does not install a service or change config.
"""
import argparse
import os
from pathlib import Path
import sys

sys.dont_write_bytecode = True
from live_codex_wakeup_saved import SavedWakeCanary


class DefaultCanary(SavedWakeCanary):
    def run(self, native_worker=False):
        self.socket = Path(os.environ.get("CODEX_HOME", str(Path.home() / ".codex"))) / "app-server-control/app-server-control.sock"
        if self.socket.exists() or self.socket.is_symlink():
            raise RuntimeError("default control socket already exists; refusing to disturb it")
        self.start_server()
        self.setup_thread()
        self.attach_tui("ordinary-codex", local_default=True)
        start = len(self.active_tui["data"])
        self.output_test()
        self.visible("RECEIVED " + self.token + " IDLE_TOOL_OUTPUT_OK",
                     "ordinary CLI automatically receives result without --remote", start)
        self.check("ordinary launch has no configuration or endpoint arguments",
                   self.report["tui_launches"][0]["argv"] ==
                   ["codex", "resume", "--no-alt-screen", self.thread_id])
        self.report["status"] = "passed"


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    os.umask(0o077)
    canary = DefaultCanary(args.output)
    try:
        canary.run()
    except BaseException as error:
        canary.report.update(status="failed", error=repr(error))
        raise
    finally:
        canary.close()
