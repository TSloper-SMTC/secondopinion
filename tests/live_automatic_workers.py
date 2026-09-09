#!/usr/bin/env python3
"""Production async delegation: normal TUI, four real workers, service recovery.

Unlike the PoC, all notifications use the plugin's own durable delivery code.
The fixture provisions its owned server/service as installation would; no
manual route registration or per-task watcher is used. Existing sockets refused.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import signal
import sys
import time

sys.dont_write_bytecode = True
from live_codex_wakeup_pool import NativePoolWakeCanary, FIXTURE
from live_delegation import CLI
sys.path.insert(0, str(CLI.parent.parent / "scripts"))
from codex_wakeup import Wakeup, default_socket


class AutomaticCanary(NativePoolWakeCanary):
    def start_service(self, label):
        self.bridge = self.launch(label, [CLI, "wake", "serve", "--timeout", "600"])
        def ready():
            if self.bridge.poll() is not None:
                raise RuntimeError((self.output / (label + ".stderr")).read_text())
            wake = Wakeup(self.store)
            try:
                return wake.service_running()
            finally:
                wake.db.close()
        self.until(ready, 15)
        self.check(label + " service owns its singleton lease", True)

    def notifications(self):
        return json.loads(self.command([CLI, "wake", "status", "codex-" + self.thread_id]))

    def delegate(self, task_id, worker, wait=0):
        return self.launch(task_id, [CLI, "delegate", "--async", "--id", task_id,
            "--worker", worker["sessionId"], "--worker-name", worker["name"],
            "--file", self.request(task_id), "--delivery-timeout", "120"])

    def run(self, native_worker=True):
        self.socket = Path(default_socket())
        if self.socket.exists() or self.socket.is_symlink():
            raise RuntimeError("default socket exists; refusing to disturb existing server")
        self.report["scope"] = "production async delegation; fixture-owned server/service; normal TUI"
        self.report["harness_sha256"][Path(__file__).name] = hashlib.sha256(Path(__file__).read_bytes()).hexdigest()
        self.report["implementation_sha256"] = {p.name: hashlib.sha256(p.read_bytes()).hexdigest()
            for p in (CLI, CLI.parent.parent / "scripts/task_mailbox.py",
                      CLI.parent.parent / "scripts/codex_wakeup.py", CLI.parent.parent / "scripts/codex_rpc.py")}
        self.start_server()
        self.setup_thread()
        self.env["CODEX_THREAD_ID"] = self.thread_id
        self.attach_tui("ordinary-codex", local_default=True)
        self.start_service("bridge-first")
        # The colleague should not have to export a feature variable when
        # starting workers. Only the plugin's internal relay sets its own flag.
        self.env.pop("CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS", None)
        self.report["worker_startup_experimental_teams_env"] = "absent"
        (self.work / "pool_fixture.py").write_text(FIXTURE)
        labels = ["pool-" + c for c in "abcd"]
        expected = {label: "AUTO_" + label.upper().replace("-", "_") + "_" + os.urandom(5).hex()
                    for label in labels}
        workers = {label: self.worker("so-auto-" + label + "-" + self.token[:8]) for label in labels}
        for label in labels:
            (self.work / (label + ".expected")).write_text(expected[label])
        callers = {label: self.delegate(label, workers[label]) for label in labels}
        self.until(lambda: all((self.work / (label + ".effect")).exists() for label in labels), 210)
        for label in labels:
            self.check(label + " async relay returns before worker completion", callers[label].wait(timeout=140) == 0 and
                       not (self.work / (label + ".report")).exists())
            receipt = json.loads((self.output / (label + ".stdout")).read_text())
            self.check(label + " route registered automatically", receipt["notification"] == "automatic" and
                       receipt["registration"] == "codex-" + self.thread_id)
        self.check("all four assignments bound to one coordinator automatically", self.notifications()["tasks"] == labels)
        self.idle("ordinary Codex idle while independent workers run")
        event_start = len(self.rpc.messages)
        terminal_start = len(self.active_tui["data"])
        os.killpg(self.bridge.pid, signal.SIGKILL)
        self.bridge.wait(timeout=5)
        self.check("test service crash is reaped", self.bridge.poll() is not None)
        for label in labels:
            (self.work / (label + ".release")).touch()
        self.until(lambda: all(self.task("status", label)["state"] == "complete" for label in labels), 210)
        self.idle("completed results survive service outage while Codex stays idle")
        self.start_service("bridge-recovered")
        def delivered():
            events = self.notifications()["notifications"]
            return events if len(events) == 4 and all(e["state"] == "recorded" for e in events) else None
        events = self.until(delivered, 120)
        self.check("recovered service delivers all four durable notifications", True, events)
        turn_ids = {event["turn"] for event in events}
        for turn in turn_ids:
            self.completed(turn, event_start)
        actual = "\n".join(self.text(turn) for turn in turn_ids)
        self.idle("automatic result turns finish idle")
        for label in labels:
            text = "RECEIVED " + self.token + " " + expected[label]
            self.check(label + " actual model consumes exact result with original context", text in actual, actual)
            self.visible(text, label + " result visible without user input", terminal_start)
            task = self.task("result", label)
            self.check(label + " immutable result and native worker binding", task["result"] == expected[label] and
                       task["worker"] == workers[label]["sessionId"] and task["requester"] == self.thread_id)
            self.check(label + " execution occurred once", (self.work / (label + ".effect")).read_text() ==
                       "executions=1" and not (self.work / (label + ".duplicate")).exists())
        self.check("notification delivery did not silently acknowledge consumption",
                   len(self.task("inbox", "--consumer", self.thread_id)) == 4)
        for label in labels:
            task = self.task("result", label)
            self.task("ack", label, "--consumer", self.thread_id, "--revision", str(task["revision"]))
        self.check("explicit consumption acknowledgments retained", self.task("inbox", "--consumer", self.thread_id) == [])
        os.killpg(self.bridge.pid, signal.SIGKILL)
        self.bridge.wait(timeout=5)
        self.start_service("bridge-post-delivery")
        time.sleep(3)
        self.check("post-delivery restart does not replay notifications",
                   [e["attempts"] for e in self.notifications()["notifications"]] == [1] * 4)
        outputs = [m for m in self.rpc.messages[event_start:] if m.get("method") == "item/completed" and
                   m["params"]["item"].get("type") == "functionCallOutput"]
        self.check("exactly four outputs in actual Codex conversation", len(outputs) == 4)
        self.report["status"] = "passed"


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    os.umask(0o077)
    canary = AutomaticCanary(args.output)
    try:
        canary.run()
    except BaseException as error:
        canary.report.update(status="failed", error=repr(error))
        raise
    finally:
        canary.close()
