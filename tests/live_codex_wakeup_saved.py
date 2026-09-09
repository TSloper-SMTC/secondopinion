#!/usr/bin/env python3
"""Opt-in saved-thread/TUI wakeup and restart canary, using only owned sessions.

Normal Codex runtime storage holds the new saved thread; cleanup archives it
through the public API. No daemon installation or existing-thread mutation.
"""
import argparse
import errno
import fcntl
import hashlib
import json
import os
from pathlib import Path
import pty
import re
import signal
import struct
import subprocess
import sys
import termios
import threading
import time

sys.dont_write_bytecode = True
from live_codex_wakeup import WakeCanary


class SavedWakeCanary(WakeCanary):
    def __init__(self, output):
        super().__init__(output, ephemeral=False)
        self.tuis = []
        self.active_tui = None
        self.report["harness_sha256"] = {
            name: hashlib.sha256((Path(__file__).parent / name).read_bytes()).hexdigest()
            for name in ("live_codex_wakeup_saved.py", "live_codex_wakeup.py", "live_worker_pool.py", "live_delegation.py")}
        self.save()

    def attach_tui(self, label, local_default=False):
        master, slave = pty.openpty()
        fcntl.ioctl(slave, termios.TIOCSWINSZ, struct.pack("HHHH", 50, 180, 0, 0))
        log = open(self.output / (label + ".terminal.log"), "wb", buffering=0)
        record = {"fd": master, "data": bytearray(), "log": log, "label": label}
        self.tuis.append(record)
        env = dict(self.env, TERM="xterm-256color")
        args = ["codex", "resume", "--remote", "unix://" + str(self.socket), "--no-alt-screen",
                "--sandbox", "read-only", "--ask-for-approval", "never", "--disable", "apps",
                "--disable", "plugins", "-c", "project_doc_max_bytes=0", "-c", 'model_reasoning_effort="low"',
                self.thread_id]
        if local_default:
            # Ordinary launch: no endpoint, config overrides, startup wrapper or
            # model prompt. The test server already owns the default socket.
            args = ["codex", "resume", "--no-alt-screen", self.thread_id]
        def terminal_session():
            os.setsid()
            fcntl.ioctl(0, termios.TIOCSCTTY, 0)
        try:
            process = subprocess.Popen(args, cwd=self.work, env=env, stdin=slave,
                stdout=slave, stderr=slave, preexec_fn=terminal_session)
        finally:
            os.close(slave)
        self.processes.append(process)
        record["process"] = process
        self.report.setdefault("tui_launches", []).append({"label": label, "pid": process.pid,
                                                        "thread_id": self.thread_id, "argv": args})
        self.save()

        def drain():
            seen_cpr = seen_bg = 0
            trusted_fixture = False
            try:
                while True:
                    chunk = os.read(master, 65536)
                    if not chunk:
                        break
                    record["data"].extend(chunk)
                    log.write(chunk)
                    data = bytes(record["data"])
                    # Terminal protocol replies only: never inject a user prompt,
                    # accept permissions, or press Enter to trigger a turn.
                    cpr = data.count(b"\x1b[6n")
                    while seen_cpr < cpr:
                        os.write(master, b"\x1b[1;1R")
                        seen_cpr += 1
                    bg = data.count(b"\x1b]11;?")
                    while seen_bg < bg:
                        os.write(master, b"\x1b]11;rgb:0000/0000/0000\x1b\\")
                        seen_bg += 1
                    if local_default and not trusted_fixture and \
                            "Doyoutrustthecontentsofthisdirectory?" in re.sub(r"\s+", "", self.readable(data)) and \
                            str(self.work) in self.readable(data):
                        # Only the new test checkout, before the conversation
                        # loads. This is not a work/permission approval.
                        time.sleep(0.2)
                        os.write(master, b"\r")
                        trusted_fixture = True
                        self.report["fixture_trust_accepted"] = str(self.work)
            except OSError as error:
                if error.errno not in (errno.EIO, errno.EBADF):
                    record["reader_error"] = repr(error)

        record["reader"] = threading.Thread(target=drain, daemon=True)
        record["reader"].start()
        self.active_tui = record
        self.visible("READY " + self.token, label + " replays original conversation", timeout=90)
        self.check(label + " is attached and alive", process.poll() is None,
                   {"pid": process.pid, "thread_id": self.thread_id})
        self.idle(label + " attaches without starting a turn")

    @staticmethod
    def readable(data):
        text = bytes(data).decode("utf-8", errors="replace")
        text = re.sub(r"\x1b\][^\x07\x1b]*(?:\x07|\x1b\\)", "", text)
        return re.sub(r"\x1b\[[0-?]*[ -/]*[@-~]", "", text)

    def visible(self, expected, label, start=0, timeout=45):
        record = self.active_tui

        def shown():
            if record["process"].poll() is not None:
                raise RuntimeError("test TUI exited: " + self.readable(record["data"])[-2500:])
            return expected in self.readable(record["data"][start:])

        try:
            self.until(shown, timeout)
        finally:
            (self.output / (record["label"] + ".readable.log")).write_text(self.readable(record["data"]))
        self.check(label, True, {"expected": expected, "byte_offset": start})

    def stop_tui(self):
        record = self.active_tui
        if record is None:
            return
        process = record["process"]
        if process.poll() is None:
            os.killpg(process.pid, signal.SIGTERM)
            try:
                process.wait(timeout=10)
            except subprocess.TimeoutExpired:
                os.killpg(process.pid, signal.SIGKILL)
                process.wait(timeout=5)
        self.active_tui = None

    def run(self, native_worker):
        self.start_server()
        self.setup_thread()
        self.attach_tui("codex-tui")
        start = len(self.active_tui["data"])
        self.queue_test()
        self.check("saved-thread CLI queue is accepted", self.report["queue_exit"] == 0)
        self.visible("QUEUE_AWAKE " + self.token, "CLI queue wakeup appears in attached TUI", start)

        start = len(self.active_tui["data"])
        self.output_test()
        self.visible("RECEIVED " + self.token + " IDLE_TOOL_OUTPUT_OK",
                     "independent completion appears in attached TUI", start)
        start = len(self.active_tui["data"])
        self.busy_test()
        self.visible("RECEIVED " + self.token + " BUSY_TOOL_OUTPUT_OK",
                     "busy completion appears in attached TUI", start)

        if native_worker:
            start = len(self.active_tui["data"])
            self.claude_test()
            self.visible("RECEIVED " + self.token + " LIVE_FOREGROUND_OK",
                         "real Claude result appears automatically in attached TUI", start)

        # Restart only this harness's server; saved UUID and context must survive.
        self.stop_tui()
        for client in self.clients:
            client.transport.close()
            client.reader.join(timeout=2)
        os.killpg(self.server.pid, signal.SIGTERM)
        self.server.wait(timeout=15)
        self.check("owned app-server stopped before recovery", self.server.poll() is not None)
        previous = self.thread_id
        self.start_server("app-server-restarted", "coordinator-restarted")
        restored = self.rpc.call("thread/resume", {"threadId": previous,
            "cwd": str(self.work), "sandbox": "read-only", "approvalPolicy": "never"})
        self.check("public resume preserves saved thread UUID", restored["thread"]["id"] == previous)
        self.idle("resumed saved thread is idle")
        self.attach_tui("codex-tui-restarted")
        start = len(self.active_tui["data"])
        bridge = self.connect("completion-bridge-restarted")
        turn_id = self.start_output(bridge, {"id": "after-restart", "result": "RESTART_CONTEXT_OK"})
        self.completed(turn_id)
        self.check("wakeup after server restart preserves context", "RECEIVED " + self.token +
                   " RESTART_CONTEXT_OK" in self.text(turn_id), self.text(turn_id))
        self.visible("RECEIVED " + self.token + " RESTART_CONTEXT_OK",
                     "recovered completion appears in reopened TUI", start)
        self.idle("recovered conversation finishes idle")
        self.report["status"] = "passed"

    def close(self):
        try:
            self.stop_tui()
            if self.thread_id and hasattr(self, "rpc") and not self.rpc.failure:
                try:
                    self.rpc.call("thread/archive", {"threadId": self.thread_id}, timeout=15)
                    self.report["test_thread_archived"] = self.thread_id
                except Exception as error:
                    self.report["archive_error"] = repr(error)
        finally:
            try:
                super().close()
            finally:
                for record in self.tuis:
                    os.close(record["fd"])
                    record["reader"].join(timeout=2)
                    record["log"].close()
                self.save()


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--native-worker", action="store_true")
    args = parser.parse_args()
    os.umask(0o077)
    canary = SavedWakeCanary(args.output)
    try:
        canary.run(args.native_worker)
    except BaseException as error:
        canary.report.update(status="failed", error=repr(error))
        raise
    finally:
        canary.close()
