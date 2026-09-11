#!/usr/bin/env python3
"""Transport fixture only. Exercises the real ask/delegate/worker CLI processes."""
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import time


def call(*args):
    return subprocess.check_output([os.environ["TASK_FIXTURE_CLI"], *args], text=True)


if "--help" in sys.argv:
    print("--safe-mode --effort (low, medium, high)")
    sys.exit(0)

if "--fixture-worker" in sys.argv:
    task_id, worker, scenario = sys.argv[2:]
    time.sleep(0.15)
    claim = json.loads(call("task", "claim", task_id, "--session", worker))
    if not claim["execute"]:
        sys.exit(0)
    report = Path(os.environ["SECONDOPINION_DIR"]) / (task_id + "-report.md")
    report.write_text("worker report after relay exit\n")
    state = "refused" if scenario == "refused" else "complete"
    call("task", "update", task_id, "--session", worker, "--revision", str(claim["task"]["revision"]),
         "--state", state, "--message", "fixture outcome", "--file", str(report))
    report.unlink()
    sys.exit(0)

prompt = sys.argv[sys.argv.index("-p") + 1]
assert "ListAgents,SendMessage" in " ".join(sys.argv)
exchange = re.findall(r"^Exchange-ID: (.+)$", prompt, re.M)[-1]
request = Path(os.environ["SECONDOPINION_DIR"], "exchanges", exchange, "prompt.md").read_text()
task_id, worker = re.search(r"Delegated task ([\w.-]+); assigned worker session ([\w.-]+)\.", request).groups()
scenario = os.environ["TASK_FIXTURE_SCENARIO"]
if scenario == 'api-timeout':
    print(json.dumps(dict(type='system',subtype='init',tools=['ListAgents','SendMessage'])),flush=True)
    for _ in range(10):
        print(json.dumps(dict(type='system',subtype='api_retry',error='unknown')),flush=True)
    time.sleep(30)
    sys.exit(1)
if scenario != "no-tools":
    call("task", "delivered", task_id, "--receipt", "fixture-message-" + task_id)
if scenario not in ("delivery-only", "no-tools"):
    # This worker is independent of the short-lived relay, with no inherited pipes.
    subprocess.Popen([sys.executable, __file__, "--fixture-worker", task_id, worker, scenario],
                     stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                     start_new_session=True)
if scenario == "relay-crash":
    sys.exit(1)
claim = call("claim", exchange, "--owner", "fixture-relay")
token = re.search(r"^claim_token=(.+)$", claim, re.M).group(1)
response = Path(os.environ["SECONDOPINION_DIR"], exchange + "-response.md")
response.write_text(f"Exchange-ID: {exchange}\nResponder: Claude Code\n\nDelivery receipt only; worker completion unverified.\n")
call("respond", exchange, "--token", token, "--file", str(response))
response.unlink()
