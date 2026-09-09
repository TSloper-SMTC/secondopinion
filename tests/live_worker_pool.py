#!/usr/bin/env python3
"""Opt-in four-interactive-worker pool canary; no background-worker substitution.

Creates four owned PTYs and a private fixture checkout. Uses the real relay and
public worker listing, never private Claude sockets or session files. The only
trust dialog it accepts is for the checkout this harness just created.
"""
import argparse
import errno
import fcntl
import json
import os
from pathlib import Path
import pty
import re
import signal
import struct
import subprocess
import termios
import threading
import time
import uuid

from live_delegation import ANSI, CLI, Canary

DUPLICATE_AUDIT = '''import json, pathlib, subprocess, sys
cli, task_id = sys.argv[1:]
status = json.loads(subprocess.check_output([cli, "task", "status", task_id], text=True))
claim = json.loads(subprocess.check_output([cli, "task", "claim", task_id,
                                          "--session", status["worker"]], text=True))
assert claim["execute"] is False, "duplicate unexpectedly granted an execution claim"
path = pathlib.Path.cwd() / (task_id + ".duplicate-rejected.json")
path.write_text(json.dumps(claim, sort_keys=True) + "\\n")
print("Duplicate rejected; execution not repeated.")
'''


class WorkerPoolCanary(Canary):
    def __init__(self, output):
        super().__init__(output)
        self.terminals = []
        fixture = self.work / "fixture.py"
        fixture.write_text(fixture.read_text().replace("time.monotonic() + 240", "time.monotonic() + 540"))
        (self.work / "audit_duplicate.py").write_text(DUPLICATE_AUDIT)

    def worker(self, name, resume=None):
        assert resume is None, "interactive restart is not a background respawn"
        session = str(uuid.uuid4())
        master, slave = pty.openpty()
        fcntl.ioctl(slave, termios.TIOCSWINSZ, struct.pack("HHHH", 60, 180, 0, 0))
        log_path = self.output / (name + ".terminal.log")
        log = open(log_path, "wb", buffering=0)
        record = {"fd": master, "log": log, "data": bytearray(), "trusted": False}
        self.terminals.append(record)
        try:
            child = subprocess.Popen([
                "claude", "--safe-mode", "--name", name, "--session-id", session,
                "--permission-mode", "dontAsk", "--allowedTools", "Bash,Read,Write",
                "--ax-screen-reader", "--", "Read AGENTS.md in this isolated fixture checkout, "
                "then wait for an authorized delegated task. Do not start work or message other agents."
            ], cwd=self.work, env=self.env, stdin=slave, stdout=slave, stderr=slave,
                start_new_session=True)
        finally:
            os.close(slave)
        self.processes.append(child)
        record["process"] = child

        def drain():
            try:
                while True:
                    data = os.read(master, 65536)
                    if not data:
                        break
                    record["data"].extend(data)
                    log.write(data)
            except OSError as error:
                if error.errno not in (errno.EIO, errno.EBADF):
                    raise

        reader = threading.Thread(target=drain, daemon=True)
        record["reader"] = reader
        reader.start()

        def lookup():
            if child.poll() is not None:
                raise RuntimeError("interactive worker exited: " + self.terminal_text(record)[-2500:])
            screen = self.terminal_text(record)
            if "Yes, I trust this folder" in screen and not record["trusted"]:
                # No blanket prompt acceptance or bypass-permissions mode.
                if str(self.work) not in screen:
                    raise RuntimeError("trust prompt does not identify the isolated checkout")
                os.write(master, b"y\r" if "Enter y/n:" in screen else b"\r")
                record["trusted"] = True
            rows = json.loads(self.command(["claude", "agents", "--json"]))
            matches = [r for r in rows if r.get("sessionId") == session and
                       r.get("name") == name and r.get("cwd") == str(self.work)]
            return matches[0] if len(matches) == 1 else None

        row = self.until(lookup, 45)
        self.check("real interactive peer: " + name, row.get("kind") == "interactive", row)
        record["worker"] = row
        self.report["workers"].append(row)
        self.save()
        return row

    @staticmethod
    def terminal_text(record):
        return ANSI.sub("", bytes(record["data"]).decode("utf-8", errors="replace"))

    def request(self, task_id):
        if task_id not in ("blocked", "refused"):
            path = super().request(task_id)
            request = path.read_text().replace("250 seconds", "550 seconds")
            if task_id == "foreground":
                import shlex
                audit = shlex.join(["python3", str(self.work / "audit_duplicate.py"), str(CLI), task_id])
                request += ("\nDUPLICATE TEST INSTRUMENTATION: when you receive this task again, do not rerun "
                            "fixture.py. Run this reporting-only audit command once, even if you already know "
                            "you hold the claim: " + audit + ". It re-checks the claim, requires execute=false, "
                            "and records a JSON witness without executing the task. This proves the native "
                            "duplicate was processed without depending on your final response wording.\n")
            path.write_text(request)
            return path
        path = self.work / (task_id + ".request.md")
        if task_id == "blocked":
            request = """Authorized reporting-only fixture, no execution or hardware work.
After claiming this task, publish needs_attention with action-needed TEST_APPROVAL_REQUIRED
and a concise message. Do not publish complete yet, execute a script, or send peer replies.
On duplicate delivery, execute=false prohibits any new work. A reporting-only continuation
is authorized if the test-approval.release file exists in this checkout: then publish
complete using the already-existing test-approval.report file without running any executor.
This fixture checks that a blocked worker does not block other workers' result collection.
"""
        else:
            request = """Authorized reporting-only refusal fixture. Claim this task, then
publish refused with message TEST_REFUSAL_OK. Do not run any executor or write a result file.
The purpose is to verify that refusal is distinct from success and does not block other workers.
"""
        path.write_text(request)
        return path

    def run(self):
        self.report["claude_version"] = self.command(["claude", "--version"]).strip()
        suffix = uuid.uuid4().hex[:8]
        a = self.worker("so-interactive-a-" + suffix)
        b = self.worker("so-interactive-b-" + suffix)
        c = self.worker("so-interactive-c-" + suffix)
        d = self.worker("so-interactive-d-" + suffix)
        original = self.delegate("foreground", a, wait=300)
        late = self.delegate("late-pickup", b, wait=0)
        blocked = self.delegate("blocked", c, wait=180)
        refused = self.delegate("refused", d, wait=180)
        selected = ["foreground", "late-pickup", "blocked", "refused"]
        def tasks_created():
            try:
                return all(self.task("status", name) for name in selected)
            except RuntimeError as error:
                if "unknown task:" not in str(error):
                    raise
                return False
        self.until(tasks_created, 15)
        collector = self.launch("pool-collector", [CLI, "task", "wait-any", *selected,
                                                  "--consumer", "pool-coordinator", "--timeout", "240"])
        self.until(lambda: (self.work / "foreground.effect").exists())
        relay_end = self.until(lambda: self.relay_finished("foreground"))
        self.check("interactive worker busy after messenger exit", original.poll() is None and
                   not (self.work / "foreground.report").exists(), relay_end)

        self.check("third worker reports approval blocker", blocked.wait(timeout=240) == 3)
        self.check("fourth worker refuses independently", refused.wait(timeout=240) == 3)
        self.check("pool collector returns while slow workers still run", collector.wait(timeout=10) == 3 and
                   not (self.work / "foreground.report").exists() and not (self.work / "late-pickup.report").exists())
        collected = json.loads((self.output / "pool-collector.stdout").read_text())
        self.check("pool collector reports only ready outcomes", bool(collected) and
                   {task["id"] for task in collected} <= {"blocked", "refused"}, collected)
        attention = self.task("status", "blocked")
        refusal = self.task("status", "refused")
        self.check("blocker and refusal belong to correct additional workers", attention["worker"] == c["sessionId"] and
                   attention["action_needed"] == "TEST_APPROVAL_REQUIRED" and refusal["worker"] == d["sessionId"] and
                   refusal["state"] == "refused" and refusal["message"] == "TEST_REFUSAL_OK")
        for task in (attention, refusal):
            self.task("ack", task["id"], "--consumer", "pool-coordinator", "--revision", str(task["revision"]))

        # Complete the second worker before the first, independent of launch order.
        self.check("second interactive caller times out independently", late.wait(timeout=150) == 124)
        (self.work / "late-pickup.release").touch()
        later = json.loads(self.command([CLI, "task", "wait-any", *selected, "--consumer", "pool-coordinator",
                                        "--timeout", "150"], timeout=165))
        self.check("out-of-order result collected before first worker completes", len(later) == 1 and
                   later[0]["id"] == "late-pickup" and later[0]["result"] == "LIVE_LATE_PICKUP_OK" and
                   later[0]["worker"] == b["sessionId"] and not (self.work / "foreground.report").exists(), later)

        # Native delivery is accepted while the existing worker is still busy.
        duplicate = self.relaunch_message("foreground", "duplicate-while-busy")
        self.check("duplicate delivered to busy interactive peer", duplicate.wait(timeout=150) == 0)
        os.killpg(original.pid, signal.SIGKILL)
        self.check("waiting requester killed rather than cleanly timed out", original.wait(timeout=5) == -signal.SIGKILL)
        self.check("requester death does not release worker claim", not self.task(
            "claim", "foreground", "--session", a["sessionId"])["execute"])
        self.check("requester death leaves interactive worker alive", self.terminals[0]["process"].poll() is None)
        replacement = self.launch("replacement-waiter", [CLI, "task", "wait", "foreground", "--timeout", "150"])
        (self.work / "foreground.release").touch()
        self.check("replacement waiter collects interactive result", replacement.wait(timeout=165) == 0)
        answer = self.task("result", "foreground")
        self.check("result belongs to correct interactive worker", answer["result"] == "LIVE_FOREGROUND_OK" and
                   answer["worker"] == a["sessionId"], answer)
        proof_path = self.work / "foreground.duplicate-rejected.json"
        self.until(proof_path.exists, 90)
        proof = json.loads(proof_path.read_text())
        self.check("interactive worker records duplicate rejection", proof["execute"] is False and
                   proof["task"]["id"] == "foreground" and proof["task"]["worker"] == a["sessionId"], proof)
        events = self.task("events", "foreground")
        self.check("only one execution claim after requester death and duplicate", sum(
            event["kind"] == "claimed" for event in events) == 1)

        self.check("interactive effects run once", all(
            (self.work / (name + ".effect")).read_text() == "executions=1" and
            not (self.work / (name + ".duplicate")).exists()
            for name in ("foreground", "late-pickup")))

        (self.work / "test-approval.report").write_text("LIVE_APPROVED_REPORT_OK")
        (self.work / "test-approval.release").touch()
        continued = self.relaunch_message("blocked", "approval-reporting-continuation")
        self.check("blocked worker receives reporting-only approval", continued.wait(timeout=150) == 0)
        approved = json.loads(self.command([CLI, "task", "wait-any", "blocked", "--consumer", "pool-coordinator",
                                           "--timeout", "150"], timeout=165))[0]
        self.check("approved worker finishes original task without new claim", approved["result"] == "LIVE_APPROVED_REPORT_OK" and
                   sum(e["kind"] == "claimed" for e in self.task("events", "blocked")) == 1, approved)
        self.check("later completion reappears after blocker acknowledgment", "blocked" in {
            task["id"] for task in self.task("inbox", "--consumer", "pool-coordinator")})

        # A worker that refused one task remains usable for a separate authorized task.
        reuse = self.delegate("reuse", d, wait=150)
        self.check("refusing worker accepts a distinct later task", reuse.wait(timeout=285) == 0)
        reused = self.task("result", "reuse")
        self.check("refusal does not poison next task on same worker", reused["result"] == "LIVE_REUSE_OK" and
                   reused["worker"] == d["sessionId"] and self.task("status", "refused")["state"] == "refused", reused)
        self.check("reused worker executes new assignment once", (self.work / "reuse.effect").read_text() == "executions=1" and
                   not (self.work / "reuse.duplicate").exists() and
                   sum(e["kind"] == "claimed" for e in self.task("events", "reuse")) == 1)

        # A negative routing control: an absent name must not reach another peer.
        missing = self.delegate("absent", {"sessionId": str(uuid.uuid4()),
                                           "name": "so-absent-" + suffix}, wait=0)
        self.check("absent peer returns unconfirmed delivery", missing.wait(timeout=150) == 1)
        undelivered = self.task("status", "absent")
        self.check("absent peer never claims or executes", undelivered["state"] == "created" and
                   undelivered["delivery_receipt"] is None and not (self.work / "absent.effect").exists(), undelivered)

        inbox = self.task("inbox", "--consumer", "interactive-consumer-restart")
        self.check("new consumer recovers all five pool outcomes", {task["id"] for task in inbox} ==
                   {"foreground", "late-pickup", "blocked", "refused", "reuse"})
        for task in inbox:
            args = ["ack", task["id"], "--consumer", "interactive-consumer-restart", "--revision", str(task["revision"])]
            first, repeat = self.task(*args), self.task(*args)
            self.check("interactive acknowledgment is idempotent: " + task["id"],
                       first["acknowledged"] and not repeat["acknowledged"])
        self.check("acknowledged interactive inbox is empty", self.task(
            "inbox", "--consumer", "interactive-consumer-restart") == [])
        self.report["status"] = "passed"

    def close(self):
        try:
            super().close()
        finally:
            for terminal in self.terminals:
                os.close(terminal["fd"])
                if "reader" in terminal:
                    terminal["reader"].join(timeout=2)
                terminal["log"].close()
                if "process" in terminal:
                    self.report.setdefault("interactive_cleanup", []).append({
                        "pid": terminal["process"].pid, "exit_code": terminal["process"].poll()})
            self.save()


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    os.umask(0o077)
    canary = WorkerPoolCanary(args.output)
    try:
        canary.run()
    except BaseException as error:
        canary.report.update(status="failed", error=repr(error))
        raise
    finally:
        canary.close()
