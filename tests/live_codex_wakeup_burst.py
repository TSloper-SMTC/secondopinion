#!/usr/bin/env python3
"""Opt-in concurrent notification canary; synthetic results, real Codex/TUI.

This tests the notification transport, not four native Claude workers or durable
watcher retries. The separate native worker-pool and saved-thread canaries cover
those execution and single-worker end-to-end paths respectively.
"""
import argparse
from concurrent.futures import ThreadPoolExecutor
import hashlib
import json
import os
from pathlib import Path
import sys
import threading

sys.dont_write_bytecode = True
from live_codex_wakeup_saved import SavedWakeCanary


class BurstCanary(SavedWakeCanary):
    def run(self, native_worker=False):
        self.report["harness_sha256"]["live_codex_wakeup_burst.py"] = hashlib.sha256(
            Path(__file__).read_bytes()).hexdigest()
        self.start_server()
        self.setup_thread()
        self.attach_tui("codex-burst-tui")
        clients = [self.connect("burst-client-" + str(i)) for i in range(4)]

        for phase in ("busy", "idle"):
            self.idle(phase + " burst starts from verified idle state")
            start = len(self.rpc.messages)
            terminal_start = len(self.active_tui["data"])
            gate = None
            active_turn = None
            if phase == "busy":
                active_turn = self.start_text("Call poc_hold once. When it returns, acknowledge every "
                    "completion actually received, one RECEIVED <remembered token> <result> line per result. "
                    "Never guess unreceived results. Keep this acknowledgment rule for subsequent turns too.")
                gate = self.rpc.wait(lambda m: (m.get("method") == "item/tool/call" and
                    m["params"].get("tool") == "poc_hold") or (m.get("method") == "turn/completed" and
                    m["params"]["turn"]["id"] == active_turn), start=start)
                self.check("busy burst reaches controlled gate", gate["method"] == "item/tool/call")
                self.check("thread active before concurrent notifications", self.state()["status"]["type"] == "active")

            barrier = threading.Barrier(len(clients))
            payloads = [{"id": phase + "-worker-" + str(i),
                         "worker": "synthetic-worker-" + str(i),
                         "result": phase.upper() + "_BURST_" + str(i) + "_" + os.urandom(4).hex()}
                        for i in range(len(clients))]

            def deliver(pair):
                client, payload = pair
                barrier.wait(timeout=10)
                return self.start_output(client, payload)

            with ThreadPoolExecutor(max_workers=4) as pool:
                turn_ids = list(pool.map(deliver, zip(clients, payloads)))
            self.report.setdefault("bursts", []).append({"phase": phase, "payloads": payloads,
                                                        "returned_turn_ids": turn_ids})
            self.save()
            if gate:
                self.check("all busy notifications join the original turn", set(turn_ids) == {active_turn}, turn_ids)
                self.rpc.send({"id": gate["id"], "result": {"success": True,
                    "contentItems": [{"type": "inputText", "text": "GATE_RELEASED"}]}})
            for turn_id in set(turn_ids):
                self.completed(turn_id, start)
            self.idle(phase + " burst returns to idle")
            actual_text = "\n".join(self.text(turn_id) for turn_id in set(turn_ids))
            outputs = [json.loads(m["params"]["item"]["output"]) for m in self.rpc.messages[start:]
                       if m.get("method") == "item/completed" and
                       m["params"]["item"].get("type") == "functionCallOutput"]
            self.check(phase + " burst records each result exactly once in public events",
                       len(outputs) == 4 and sorted(outputs, key=lambda p: p["id"]) == payloads, outputs)
            for payload in payloads:
                expected = "RECEIVED " + self.token + " " + payload["result"]
                self.check(phase + " burst acknowledges " + payload["worker"], expected in actual_text, actual_text)
                self.visible(expected, phase + " burst visible for " + payload["worker"], terminal_start)
            if phase == "busy":
                starts = [m for m in self.rpc.messages[start:] if m.get("method") == "turn/started"]
                self.check("busy burst creates no competing turns", len(starts) == 1)
        self.report["status"] = "passed"


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    os.umask(0o077)
    canary = BurstCanary(args.output)
    try:
        canary.run()
    except BaseException as error:
        canary.report.update(status="failed", error=repr(error))
        raise
    finally:
        canary.close()
