#!/usr/bin/env python3
"""Installed-service acceptance: owned tasks/workers, ordinary TUI, real restarts.

Requires an already installed candidate. It never stops the shared Codex server.
Bridge fault injection is refused if unrelated enabled notification routes exist.
Fixture results remain acknowledged in the production mailbox for audit.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import signal
import subprocess
import sys
import time

sys.dont_write_bytecode = True
from live_codex_wakeup_pool import NativePoolWakeCanary, FIXTURE
from live_delegation import CLI
sys.path.insert(0, str(CLI.parent.parent / "scripts"))
from codex_wakeup import Wakeup, default_socket


class InstalledCanary(NativePoolWakeCanary):
    def service_pid(self):
        result = self.command(["systemctl", "--user", "show", "secondopinion-wakeup.service", "-p", "MainPID", "--value"])
        return int(result.strip())

    def service_restart(self, label):
        wake = Wakeup(self.store)
        try:
            foreign = wake.db.execute("SELECT thread FROM wake_routes WHERE enabled=1 AND thread!=?", (self.thread_id,)).fetchall()
            if foreign:
                raise RuntimeError("unrelated notification routes exist; refusing global service fault injection")
        finally:
            wake.db.close()
        previous = self.service_pid()
        command = Path("/proc") / str(previous) / "cmdline"
        self.check(label + " exact bridge process verified", previous > 1 and
                   b"codex_wakeup.py" in command.read_bytes() and b"--store" in command.read_bytes())
        os.kill(previous, signal.SIGKILL)
        def recovered():
            current = self.service_pid()
            if not current or current == previous:
                return None
            wake = Wakeup(self.store)
            try:
                return current if wake.service_running() else None
            finally:
                wake.db.close()
        current = self.until(recovered, 20)
        self.check(label + " automatically restarted by installed supervisor", current != previous,
                   {"previous_pid": previous, "recovered_pid": current})

    def notification_status(self):
        return json.loads(self.command([CLI, "wake", "status", "codex-" + self.thread_id]))

    def run(self, native_worker=True):
        self.store = Path.home() / ".secondopinion"
        self.env["SECONDOPINION_DIR"] = str(self.store)
        self.env.pop("CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS", None)
        self.socket = Path(default_socket())
        self.rpc = self.connect("installed-coordinator")
        self.report["scope"] = "actual installed services, real native workers, ordinary Codex TUI"
        self.report["harness_sha256"][Path(__file__).name] = hashlib.sha256(Path(__file__).read_bytes()).hexdigest()
        self.report["implementation_sha256"] = {p.name: hashlib.sha256(p.read_bytes()).hexdigest()
            for p in (CLI, *(CLI.parent.parent / "scripts" / name for name in
                ("task_mailbox.py", "codex_wakeup.py", "codex_rpc.py", "wake_service.py", "worker_directory.py")))}
        self.report["codex_version"] = self.command(["codex", "--version"]).strip()
        self.report["claude_version"] = self.command(["claude", "--version"]).strip()
        self.setup_thread()
        self.env["CODEX_THREAD_ID"] = self.thread_id
        self.attach_tui("installed-ordinary-codex", local_default=True)
        (self.work / "pool_fixture.py").write_text(FIXTURE)
        labels = ["pool-" + c for c in "abcd"]
        tasks = {label: "installed-" + self.token[:12] + "-" + label for label in labels}
        self.report["task_ids"] = tasks
        expected = {label: "INSTALLED_" + label.upper().replace("-", "_") + "_" + os.urandom(5).hex()
                    for label in labels}
        workers = {label: self.worker("so-installed-" + label + "-" + self.token[:8]) for label in labels}
        for label in labels:
            (self.work / (label + ".expected")).write_text(expected[label])
        callers = {label: self.launch(label, [CLI, "delegate", "--async", "--id", tasks[label],
            "--worker-name", workers[label]["name"],
            "--file", self.request(label), "--delivery-timeout", "120"]) for label in labels}
        self.until(lambda: all((self.work / (label + ".effect")).exists() for label in labels), 210)
        for label in labels:
            self.check(label + " messenger exited before completion", callers[label].wait(timeout=140) == 0 and
                       not (self.work / (label + ".report")).exists())
            receipt = json.loads((self.output / (label + ".stdout")).read_text())
            self.check(label + " installed return route is automatic", receipt["notification"] == "automatic")
        self.check("exact four tasks bound without registration commands",
                   self.notification_status()["tasks"] == sorted(tasks.values()))
        self.idle("ordinary installed Codex waits idle")
        self.service_restart("pre-completion crash")
        event_start = len(self.rpc.messages)
        terminal_start = len(self.active_tui["data"])
        for label in labels:
            (self.work / (label + ".release")).touch()
        def recorded():
            events = self.notification_status()["notifications"]
            return events if len(events) == 4 and all(e["state"] == "recorded" for e in events) else None
        events = self.until(recorded, 210)
        self.check("actual installed service recorded all worker outcomes", True, events)
        turn_ids = {e["turn"] for e in events}
        for turn in turn_ids:
            self.completed(turn, event_start)
        text = "\n".join(self.text(turn) for turn in turn_ids)
        for label in labels:
            answer = "RECEIVED " + self.token + " " + expected[label]
            self.check(label + " consumed with original conversation context", answer in text, text)
            self.visible(answer, label + " visible in ordinary terminal automatically", terminal_start)
            task = self.task("result", tasks[label])
            self.check(label + " exact native binding and result", task["worker"] == workers[label]["sessionId"] and
                       task["requester"] == self.thread_id and task["result"] == expected[label])
            self.check(label + " single execution", (self.work / (label + ".effect")).read_text() ==
                       "executions=1" and not (self.work / (label + ".duplicate")).exists())
            self.task("ack", tasks[label], "--consumer", self.thread_id, "--revision", str(task["revision"]))
        self.check("all consumed results acknowledged explicitly", self.task("inbox", "--consumer", self.thread_id) == [])
        self.service_restart("post-delivery crash")
        time.sleep(3)
        self.check("supervised restart does not replay consumed notifications",
                   all(e["attempts"] == 1 and e["state"] == "consumed" for e in self.notification_status()["notifications"]))
        outputs = [m for m in self.rpc.messages[event_start:] if m.get("method") == "item/completed" and
                   m["params"]["item"].get("type") == "functionCallOutput"]
        self.check("exactly four tool-output notifications in conversation", len(outputs) == 4)
        self.idle("installed conversation ends idle")
        # A genuine ordinary ask on the same installed CLI, not a worker relay.
        request = self.work / "normal-ask.md"
        marker = "NORMAL_ASK_" + self.token
        request.write_text("Read-only smoke test. Do not run tools or contact other agents. "
                           "Your entire answer must be exactly " + marker + ".\n")
        normal = self.launch("normal-ask", [CLI, "ask", "--topic", "normal-smoke-" + self.token[:12],
            "--file", request, "--timeout", "120", "--grace", "0"])
        self.check("ordinary foreground ask completes successfully", normal.wait(timeout=140) == 0)
        answer = (self.output / "normal-ask.stdout").read_text()
        self.check("ordinary ask returns real Claude answer", marker in answer, answer)
        self.check("ordinary ask did not create worker notifications", len(self.notification_status()["notifications"]) == 4)
        self.report["status"] = "passed"

    def close(self):
        try:
            if self.thread_id:
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
    canary = InstalledCanary(args.output)
    try:
        canary.run()
    except BaseException as error:
        canary.report.update(status="failed", error=repr(error))
        raise
    finally:
        canary.close()
