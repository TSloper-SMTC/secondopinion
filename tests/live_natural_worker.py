#!/usr/bin/env python3
"""Forward acceptance of the installed skill: a real Codex delegates by name.

The controller never issues delegate/register/watch on Codex's behalf. It only
starts its owned fixture sessions, supplies the user task, and releases a gate.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import sys
import time

sys.dont_write_bytecode = True
from live_codex_wakeup_saved import SavedWakeCanary
from live_delegation import CLI
sys.path.insert(0, str(CLI.parent.parent / "scripts"))
from codex_wakeup import default_socket


class NaturalCanary(SavedWakeCanary):
    def run(self, native_worker=True):
        self.store = Path.home() / ".secondopinion"
        self.env["SECONDOPINION_DIR"] = str(self.store)
        self.env.pop("CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS", None)
        self.socket = Path(default_socket())
        self.rpc = self.connect("natural-coordinator")
        self.report["harness_sha256"][Path(__file__).name] = hashlib.sha256(Path(__file__).read_bytes()).hexdigest()
        self.report["implementation_sha256"] = {p.name: hashlib.sha256(p.read_bytes()).hexdigest()
            for p in (CLI, *(CLI.parent.parent / "scripts" / name for name in
                ("task_mailbox.py", "codex_wakeup.py", "codex_rpc.py", "wake_service.py", "worker_directory.py")))}
        self.report["codex_version"] = self.command(["codex", "--version"]).strip()
        self.report["claude_version"] = self.command(["claude", "--version"]).strip()
        self.report["scope"] = "installed skill selected by real Codex; controller does not delegate or configure return"
        (self.work / "AGENTS.md").write_text("Isolated reporting-only acceptance fixture. "
            "Only this checkout and task/exchange records for this fixture in " + str(self.store) +
            " may change. No hardware, other projects, permission changes, memory updates, "
            "unrelated conversations, commits or network configuration changes.\n")
        result = self.rpc.call("thread/start", {"cwd": str(self.work), "ephemeral": False,
            "sandbox": "workspace-write", "approvalPolicy": "never"})
        self.thread_id = result["thread"]["id"]
        self.env["CODEX_THREAD_ID"] = self.thread_id
        self.report["thread_id"] = self.thread_id
        self.report["model"] = result.get("model")
        ready = self.start_text("Remember context token " + self.token + ". Reply exactly READY <token>.")
        self.completed(ready)
        self.attach_tui("natural-ordinary-codex", local_default=True)
        worker = self.worker("so-natural-" + self.token[:8])
        self.report["worker"] = worker
        task_id = "natural-" + self.token[:16]
        self.report["task_id"] = task_id
        marker = "NATURAL_RESULT_" + self.token
        (self.work / "natural.expected").write_text(marker)
        (self.work / "natural_fixture.py").write_text(
            "from pathlib import Path\nimport time\nroot=Path(__file__).resolve().parent\n"
            "with (root/'natural.effect').open('x') as f: f.write('executions=1')\n"
            "deadline=time.monotonic()+300\n"
            "while not (root/'natural.release').exists():\n"
            "    if time.monotonic()>deadline: raise SystemExit(8)\n"
            "    time.sleep(.2)\n"
            "(root/'natural.report').write_text((root/'natural.expected').read_text())\n")
        turn = self.start_text("Use the installed secondopinion plugin's existing-worker workflow. "
            "Delegate an authorized reporting-only task to my existing Claude worker named " + worker["name"] +
            " in this checkout. Use task ID " + task_id + ". The worker must claim the task, run python3 " +
            str(self.work / "natural_fixture.py") + " exactly once, then publish complete with " +
            str(self.work / "natural.report") + ". The script intentionally waits for my external test gate; "
            "do not release it yourself. Do not run the worker's task yourself or start replacement workers. "
            "Arrange the plugin's automatic result return. Once delivery is accepted, reply exactly DELEGATED "
            "and END this turn so Codex is idle before the worker finishes. When the result arrives later, "
            "consume it, acknowledge its exact task revision for this conversation, and reply "
            "CONSUMED <remembered context token> <worker result>. No user action will occur between delivery "
            "and completion. Do not invent missing capabilities or report a relay receipt as completion.")
        self.report["active_turn"] = turn
        self.save()
        self.completed(turn, timeout=240)
        first = self.text(turn)
        self.check("real Codex independently delegates through installed skill", "DELEGATED" in first, first)
        self.until(lambda: (self.work / "natural.effect").exists(), 180)
        task = self.task("status", task_id)
        self.check("Codex discovered the correct named worker UUID", task["worker"] == worker["sessionId"] and
                   task["requester"] == self.thread_id)
        route = json.loads(self.command([CLI, "wake", "status", "codex-" + self.thread_id]))
        self.check("Codex's own delegation registered automatic return", route["tasks"] == [task_id] and route["service_running"])
        self.idle("real Codex has ended its turn before worker completes")
        event_start = len(self.rpc.messages)
        terminal_start = len(self.active_tui["data"])
        (self.work / "natural.release").touch()
        def consumed():
            task = self.task("status", task_id)
            if task["state"] != "complete":
                return False
            return self.task("inbox", "--consumer", self.thread_id) == []
        self.until(consumed, 240)
        self.idle("real Codex consumed and acknowledged the automatic result")
        answer = "CONSUMED " + self.token + " " + marker
        self.visible(answer, "automatic result consumed visibly without controller acknowledgment", terminal_start, timeout=30)
        self.check("named worker executed once", (self.work / "natural.effect").read_text() == "executions=1")
        self.report["status"] = "passed"

    def close(self):
        try:
            if self.thread_id:
                if self.report.get("status") != "passed" and self.report.get("active_turn"):
                    try:
                        self.rpc.call("turn/interrupt", {"threadId": self.thread_id, "turnId": self.report["active_turn"]})
                    except Exception:
                        pass
                try:
                    self.command([CLI, "wake", "disable", "codex-" + self.thread_id])
                    self.report["test_route_disabled"] = "codex-" + self.thread_id
                except Exception as error:
                    self.report["route_cleanup_error"] = repr(error)
        finally:
            super().close()


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    os.umask(0o077)
    canary = NaturalCanary(args.output)
    try:
        canary.run()
    except BaseException as error:
        canary.report.update(status="failed", error=repr(error))
        raise
    finally:
        canary.close()
