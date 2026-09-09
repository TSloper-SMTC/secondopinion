#!/usr/bin/env python3
"""Opt-in native Claude canary. Run on the host, not inside a PID sandbox.

Uses real Claude requests and starts/stops only its two uniquely named workers.
All inputs, marker effects, results and diagnostics stay under --output.
No hardware or existing project files are exercised. Not part of tests/run.sh.
"""
import argparse
import datetime
import hashlib
import json
import os
from pathlib import Path
import re
import shlex
import subprocess
import sys
import time
import uuid

ROOT = Path(__file__).resolve().parents[1]
CLI = ROOT / "plugins/secondopinion/bin/secondopinion"
ANSI = re.compile(r"\x1b\[[0-?]*[ -/]*[@-~]|\x1b.")

EXECUTOR = '''import pathlib, sys, time
root = pathlib.Path(__file__).resolve().parent
task = sys.argv[1]
assert task in ("foreground", "late-pickup", "restart", "reuse")
marker = root / (task + ".effect")
# A second attempted execution is itself a failing observable, not silently hidden.
if marker.exists():
    (root / (task + ".duplicate")).write_text("DUPLICATE EXECUTION")
    sys.exit(9)
with marker.open("x") as out:
    out.write("executions=1")
if task not in ("restart", "reuse"):
    deadline = time.monotonic() + 240
    while not (root / (task + ".release")).exists():
        if time.monotonic() >= deadline:
            sys.exit(8)
        time.sleep(0.25)
(root / (task + ".report")).write_text("LIVE_" + task.upper().replace("-", "_") + "_OK")
print("fixture finished; executions=1")
'''


def now():
    return datetime.datetime.now(datetime.timezone.utc).isoformat()


def duplicate_witness(log, task_id):
    # Ignore earlier execute=false from a different task (notably restart).
    # Confirm the result in the public log segment for THIS delivered message.
    marker = f"Delegated task {task_id};"
    segment = log.rsplit(marker, 1)[1] if marker in log else ""
    return (re.search(r"execute[^\n]{0,60}false", segment, re.I) is not None and
            "LIVE_" + task_id.upper().replace("-", "_") + "_OK" in segment)


class Canary:
    def __init__(self, output):
        self.output = output.resolve()
        self.output.mkdir(parents=True, mode=0o700, exist_ok=False)
        self.work = self.output / "workspace"
        self.work.mkdir()
        self.store = self.output / "store"
        self.env = {k: v for k, v in os.environ.items() if not k.startswith(("SECONDOPINION_", "AGENT_MAILBOX_"))}
        self.env.update(SECONDOPINION_DIR=str(self.store), CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS="1",
                        SECONDOPINION_PROGRESS_SECS="30")
        self.env.pop("CODEX_THREAD_ID", None)
        self.workers, self.processes, self.handles = [], [], []
        self.report = {"started_utc": now(), "checks": [], "workers": [], "status": "running"}
        self.report["source_sha256"] = {
            str(p.relative_to(ROOT)): hashlib.sha256(p.read_bytes()).hexdigest()
            for p in (CLI, CLI.parent.parent / "scripts/task_mailbox.py")}
        (self.work / "fixture.py").write_text(EXECUTOR)
        # Keep the relay's recorded checkout within the isolated fixture.
        self.command(["git", "init", "-q", "-b", "main", str(self.work)])
        (self.work / "AGENTS.md").write_text(
            "Isolated secondopinion test workspace. Only this workspace and its sibling store are writable. "
            "No hardware, unrelated workers, or other projects. Follow the assigned fixture task exactly.\n")

    def command(self, argv, expected=0, timeout=30):
        result = subprocess.run(list(map(str, argv)), cwd=self.work, env=self.env,
                                text=True, capture_output=True, timeout=timeout)
        if result.returncode != expected:
            raise RuntimeError(f"{argv[:3]} exited {result.returncode}, expected {expected}: {result.stderr[-2000:]} {result.stdout[-1500:]}")
        return result.stdout

    def task(self, *args, expected=0):
        return json.loads(self.command([CLI, "task", *args], expected))

    def check(self, name, condition, evidence=None):
        record = {"name": name, "pass": bool(condition), "utc": now(), "evidence": evidence}
        self.report["checks"].append(record)
        self.save()
        print(("PASS " if condition else "FAIL ") + name, flush=True)
        if not condition:
            raise AssertionError(name)

    def save(self):
        (self.output / "summary.json").write_text(json.dumps(self.report, indent=2) + "\n")

    def until(self, predicate, timeout=180):
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            result = predicate()
            if result:
                return result
            time.sleep(0.5)
        raise TimeoutError("native canary condition did not arrive before its deadline")

    def worker(self, name, resume=None):
        if resume:
            # --bg --resume can allocate a different native UUID. Use the public
            # background-session restart operation, and verify identity afterward.
            launched_id = resume[:8]
            args = ["claude", "respawn", launched_id]
        else:
            args = ["claude", "--bg", "--safe-mode", "--name", name,
                    "--permission-mode", "dontAsk", "--allowedTools", "Bash,Read,Write", "--"]
        launch = self.command(args)
        if not resume:
            match = re.search(r"backgrounded\s*·\s*([0-9a-f]{8})\b", ANSI.sub("", launch))
            if not match:
                raise RuntimeError("cannot identify test worker from public launch output: " + launch)
            launched_id = match.group(1)
        # Register cleanup immediately, even if discovery or identity checks fail.
        self.workers.append(launched_id)
        self.report.setdefault("launches", []).append(launch)
        self.save()
        def lookup():
            rows = json.loads(self.command(["claude", "agents", "--json", "--all"]))
            matches = [r for r in rows if r.get("id") == launched_id and
                       r.get("name") == name and r.get("cwd") == str(self.work) and
                       r.get("state") != "stopped"]
            return matches[0] if len(matches) == 1 else None
        row = self.until(lookup, 20)
        self.report["workers"].append(row)
        self.save()
        if resume:
            self.check("native resume preserves worker UUID", row["sessionId"] == resume, row)
        return row

    def request(self, task_id):
        effect = shlex.join(["python3", str(self.work / "fixture.py"), task_id])
        report = str(self.work / (task_id + ".report"))
        request = f"""Authorized isolated integration fixture {task_id}.
Only this fixture workspace and mailbox may be modified. No hardware or other agents.
First follow the mailbox claim protocol. If execute=true, publish running and execute
exactly this command once: {effect}
The script may wait for a test harness release file; allow up to 250 seconds for its
Bash call, and do not bypass the gate or rerun the command. Then publish complete
using the exact report file {report}. Never substitute your own report text.
On duplicate delivery (execute=false), do not run the script again. Inspect status;
if terminal, leave it unchanged and report that execute=false prevented a rerun.
"""
        if task_id == "restart":
            request += f"""
RESTART EXCEPTION FOR REPORTING ONLY: after the first successful script execution,
publish needs_attention with action-needed RESTART_REQUIRED, then end the turn.
Do NOT publish complete until {self.work / 'restart.release'} exists.
The harness will stop and resume this same worker session and deliver this same task.
After resumption, execute=false prohibits rerunning the fixture script. If the task is
still needs_attention and both restart.effect (executions=1) and restart.release exist,
reconcile those files, then publish complete using the existing {report}. This is
authorized continuation of reporting, not a new execution. Keep your response short.
"""
        path = self.work / (task_id + ".request.md")
        path.write_text(request)
        return path

    def launch(self, label, argv):
        stdout = open(self.output / (label + ".stdout"), "w")
        stderr = open(self.output / (label + ".stderr"), "w")
        self.handles.extend([stdout, stderr])
        child = subprocess.Popen(list(map(str, argv)), cwd=self.work, env=self.env,
                                 stdin=subprocess.DEVNULL, stdout=stdout, stderr=stderr,
                                 start_new_session=True)
        self.processes.append(child)
        return child

    def delegate(self, task_id, worker, wait=150):
        return self.launch(task_id, [CLI, "delegate", "--id", task_id, "--worker", worker["sessionId"],
                                    "--worker-name", worker["name"], "--requester", "live-canary",
                                    "--file", self.request(task_id), "--delivery-timeout", "120", "--timeout", str(wait)])

    def relaunch_message(self, task_id, label):
        prompt = self.work / (label + ".md")
        prompt.write_text(self.command([CLI, "task", "relay-prompt", task_id]))
        return self.launch(label, [CLI, "ask", "--relay", "--topic", label, "--file", prompt,
                                  "--timeout", "120", "--grace", "0"])

    def relay_finished(self, task_id):
        for path in (self.store / "exchanges").glob("*delivery-" + task_id + "/meta"):
            meta = dict(line.split("=", 1) for line in path.read_text().splitlines() if "=" in line)
            if meta.get("responder_finished_utc") and meta.get("responder_completion") == "validated-answer":
                return meta["responder_finished_utc"]
        return None

    def run(self):
        self.report["claude_version"] = self.command(["claude", "--version"]).strip()
        suffix = uuid.uuid4().hex[:8]
        a = self.worker("so-live-a-" + suffix)
        b = self.worker("so-live-b-" + suffix)
        foreground = self.delegate("foreground", a)
        late = self.delegate("late-pickup", b, wait=0)
        relay_end = self.until(lambda: self.relay_finished("foreground"))
        self.check("foreground waiter remains alive after relay exit", foreground.poll() is None, relay_end)
        (self.work / "foreground.release").touch()
        self.check("foreground worker completes successfully", foreground.wait(timeout=180) == 0)
        answer = self.task("result", "foreground")
        self.check("correct worker report after relay exit", answer["result"] == "LIVE_FOREGROUND_OK" and
                   answer["updated_utc"] > relay_end, answer)
        self.check("original late-pickup delegate exits without completion", late.wait(timeout=180) == 124)
        (self.work / "late-pickup.release").touch()
        later = json.loads(self.command([CLI, "task", "wait", "late-pickup", "--timeout", "150"], timeout=160))
        self.check("new waiter recovers late result", later["result"] == "LIVE_LATE_PICKUP_OK", later)
        self.check("two workers never cross results", answer["worker"] != later["worker"] and
                   answer["id"] == "foreground" and later["id"] == "late-pickup")

        restarted = self.delegate("restart", a)
        self.check("restart task reports attention", restarted.wait(timeout=250) == 3)
        pending = self.task("status", "restart")
        self.check("restart reason is explicit", pending["state"] == "needs_attention" and
                   pending["action_needed"] == "RESTART_REQUIRED", pending)
        self.command(["claude", "stop", a["id"]])
        a = self.worker(a["name"], resume=a["sessionId"])
        (self.work / "restart.release").touch()
        retry = self.relaunch_message("restart", "resume-reporting")
        self.check("resume reporting message delivered", retry.wait(timeout=140) == 0)
        resumed = json.loads(self.command([CLI, "task", "wait", "restart", "--timeout", "150"], timeout=160))
        self.check("resumed worker completes existing report", resumed["result"] == "LIVE_RESTART_OK", resumed)
        events = self.task("events", "restart")
        self.check("restart grants no second execution claim", sum(e["kind"] == "claimed" for e in events) == 1)

        before = self.task("events", "foreground")
        duplicate = self.relaunch_message("foreground", "duplicate-after-completion")
        self.check("duplicate native message accepted", duplicate.wait(timeout=140) == 0)
        def saw_duplicate():
            log = ANSI.sub("", self.command(["claude", "logs", a["id"]]))
            (self.output / "worker-a.log").write_text(log)
            return duplicate_witness(log, "foreground")
        self.until(saw_duplicate, 60)
        self.check("duplicate delivery preserves terminal history", self.task("events", "foreground") == before)
        self.check("all fixture effects executed exactly once", all(
            (self.work / (name + ".effect")).read_text() == "executions=1" and
            not (self.work / (name + ".duplicate")).exists()
            for name in ("foreground", "late-pickup", "restart")))

        inbox = self.task("inbox", "--consumer", "consumer-restart")
        self.check("new consumer finds all three results", {t["id"] for t in inbox} == {"foreground", "late-pickup", "restart"})
        for task in inbox:
            ack = ["ack", task["id"], "--consumer", "consumer-restart", "--revision", str(task["revision"])]
            first, second = self.task(*ack), self.task(*ack)
            self.check("idempotent consumption: " + task["id"], first["acknowledged"] and not second["acknowledged"])
        self.check("consumed inbox is empty", self.task("inbox", "--consumer", "consumer-restart") == [])
        self.report["status"] = "passed"

    def close(self):
        cleanup = []
        for worker_id in set(self.workers):
            try:
                cleanup.append(self.command(["claude", "stop", worker_id]).strip())
            except Exception as error:
                cleanup.append(str(error))
        for child in self.processes:
            if child.poll() is None:
                # Only a process group created by this harness; all IDs are held Popen objects.
                import signal
                os.killpg(child.pid, signal.SIGTERM)
                try:
                    child.wait(timeout=12)
                except subprocess.TimeoutExpired:
                    os.killpg(child.pid, signal.SIGKILL)
                    child.wait(timeout=3)
        for handle in self.handles:
            handle.close()
        self.report["cleanup"] = cleanup
        self.report["source_sha256_at_finish"] = {
            str(p.relative_to(ROOT)): hashlib.sha256(p.read_bytes()).hexdigest()
            for p in (CLI, CLI.parent.parent / "scripts/task_mailbox.py")}
        self.report["finished_utc"] = now()
        self.save()


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, required=True, help="new private artifact directory; must not exist")
    args = parser.parse_args()
    os.umask(0o077)
    canary = Canary(args.output)
    try:
        canary.run()
    except BaseException as error:
        canary.report.update(status="failed", error=repr(error))
        raise
    finally:
        canary.close()
