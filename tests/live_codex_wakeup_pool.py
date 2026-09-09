#!/usr/bin/env python3
"""Opt-in four-real-worker -> idle saved Codex/TUI completion canary.

Uses the same public temporary-messenger approach as the coworker. A watcher per
task is prototype instrumentation, not an installed service or delivery guarantee.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import shlex
import sys
import time

sys.dont_write_bytecode = True
from live_delegation import CLI
from live_codex_wakeup_saved import SavedWakeCanary


FIXTURE = '''import pathlib, sys, time
root = pathlib.Path(__file__).resolve().parent
task = sys.argv[1]
assert task in ("pool-a", "pool-b", "pool-c", "pool-d")
effect = root / (task + ".effect")
if effect.exists():
    (root / (task + ".duplicate")).write_text("duplicate execution")
    raise SystemExit(9)
with effect.open("x") as stream:
    stream.write("executions=1")
deadline = time.monotonic() + 360
while not (root / (task + ".release")).exists():
    if time.monotonic() >= deadline:
        raise SystemExit(8)
    time.sleep(0.2)
(root / (task + ".report")).write_text((root / (task + ".expected")).read_text())
print("fixture complete, executed once")
'''


class NativePoolWakeCanary(SavedWakeCanary):
    def request(self, task_id):
        path = self.work / (task_id + ".request.md")
        command = shlex.join(["python3", str(self.work / "pool_fixture.py"), task_id])
        path.write_text("Authorized isolated notification test. Only this fixture checkout and mailbox may change. "
            "No hardware or unrelated sessions. Follow the provided mailbox claim protocol first. If execute=true, "
            "publish running, then execute exactly once: " + command + ". Allow up to 370 seconds for the harness "
            "release; do not bypass it, create the release file yourself, or repeat execution. When the command "
            "finishes, publish complete with report file " + str(self.work / (task_id + ".report")) +
            ". Do not invent or substitute report content. On duplicate delivery execute=false means never rerun. "
            "Use only the durable task mailbox for reporting, not messages to the temporary messenger.\n")
        return path

    def run(self, native_worker=True):
        self.report["harness_sha256"]["live_codex_wakeup_pool.py"] = hashlib.sha256(
            Path(__file__).read_bytes()).hexdigest()
        self.report["claude_version"] = self.command(["claude", "--version"]).strip()
        self.start_server()
        self.setup_thread()
        turn_id = self.start_text("For the following completion notifications, acknowledge every result actually "
            "received, one RECEIVED <remembered token> <result> line for each. Never infer or invent missing "
            "results. Do not poll or call tools. Reply READY <remembered token> now, then finish this turn.")
        self.completed(turn_id)
        self.idle("coordinator finishes instructions before native workers start")
        self.attach_tui("codex-native-pool-tui")
        (self.work / "pool_fixture.py").write_text(FIXTURE)
        labels = ["pool-" + letter for letter in "abcd"]
        expected = {label: "NATIVE_" + label.upper().replace("-", "_") + "_" + os.urandom(5).hex()
                    for label in labels}
        workers = {label: self.worker("so-wake-" + label + "-" + self.token[:8]) for label in labels}
        for label in labels:
            (self.work / (label + ".expected")).write_text(expected[label])
        callers = {label: self.delegate(label, workers[label], wait=0) for label in labels}
        self.until(lambda: all((self.work / (label + ".effect")).exists() for label in labels), 210)
        self.until(lambda: all(self.relay_finished(label) for label in labels), 180)
        for label in labels:
            self.check(label + " messenger exits before completion", callers[label].wait(timeout=20) == 124 and
                       not (self.work / (label + ".report")).exists(), self.relay_finished(label))
        self.check("all four real interactive workers remain alive", all(
            terminal["process"].poll() is None for terminal in self.terminals))
        self.idle("Codex idle after all four temporary messengers have exited")
        event_start = len(self.rpc.messages)
        terminal_start = len(self.active_tui["data"])
        watchers = {label: self.launch(label + "-watcher", [sys.executable, "-B",
            str(Path(__file__).parent / "live_codex_wakeup.py"), "--watch", "--socket", str(self.socket),
            "--thread", self.thread_id, "--task", label]) for label in labels}
        # Release all four executors without serializing their completion reports.
        for label in labels:
            (self.work / (label + ".release")).touch()
        self.report["pool_release_monotonic"] = time.monotonic()
        self.save()
        turn_ids = set()
        for label in labels:
            self.check(label + " watcher delivers native completion", watchers[label].wait(timeout=200) == 0)
            response = json.loads((self.output / (label + "-watcher.stdout")).read_text())
            turn_ids.add(response["turn"]["id"])
        for turn_id in turn_ids:
            self.completed(turn_id, event_start)
        self.report["completion_turn_ids"] = sorted(turn_ids)
        actual_text = "\n".join(self.text(turn_id) for turn_id in turn_ids)
        self.idle("native worker pool leaves Codex idle after processing")
        outputs = [json.loads(m["params"]["item"]["output"]) for m in self.rpc.messages[event_start:]
                   if m.get("method") == "item/completed" and
                   m["params"]["item"].get("type") == "functionCallOutput"]
        self.check("exactly four native result notifications recorded", len(outputs) == 4 and
                   {item["id"] for item in outputs} == set(labels), outputs)
        for label in labels:
            text = "RECEIVED " + self.token + " " + expected[label]
            self.check(label + " exact result consumed with original context", text in actual_text, actual_text)
            self.visible(text, label + " completion visible without terminal input", terminal_start)
            result = self.task("result", label)
            self.check(label + " bound to correct native worker", result["worker"] == workers[label]["sessionId"] and
                       result["result"] == expected[label])
            self.check(label + " fixture executed once", (self.work / (label + ".effect")).read_text() ==
                       "executions=1" and not (self.work / (label + ".duplicate")).exists())
            self.task("ack", label, "--consumer", "native-wake-pool", "--revision", str(result["revision"]))
        self.check("all consumed native results acknowledged", self.task("inbox", "--consumer", "native-wake-pool") == [])
        self.report["status"] = "passed"


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    os.umask(0o077)
    canary = NativePoolWakeCanary(args.output)
    try:
        canary.run()
    except BaseException as error:
        canary.report.update(status="failed", error=repr(error))
        raise
    finally:
        canary.close()
