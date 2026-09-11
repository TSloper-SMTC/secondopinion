#!/usr/bin/env python3
"""Fault, concurrency and process-boundary tests for delegated worker tasks."""
import concurrent.futures
import importlib.util
import json
import os
from pathlib import Path
import sqlite3
import subprocess
import sys
import tempfile
import time
import unittest
import uuid
from unittest import mock

ROOT = Path(__file__).resolve().parents[1]
CLI = ROOT / "plugins/secondopinion/bin/secondopinion"
MODULE = ROOT / "plugins/secondopinion/scripts/task_mailbox.py"
sys.path.insert(0, str(MODULE.parent))
spec = importlib.util.spec_from_file_location("task_mailbox", MODULE)
mailbox = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mailbox)


class Tasks(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix="secondopinion-tasks-")
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.repo = self.root / "checkout with spaces"
        self.repo.mkdir()
        self.store = self.root / "store with spaces"
        self.req = self.root / "request.md"
        self.req.write_text("Read-only fixture task. Return the requested evidence.\n")
        self.report = self.root / "result.md"
        self.report.write_text("Complete: fixture evidence 123.\n")
        self.env = {k: v for k, v in os.environ.items() if not k.startswith(("SECONDOPINION_", "AGENT_MAILBOX_"))}
        self.env.update(SECONDOPINION_DIR=str(self.store), SECONDOPINION_PROGRESS_SECS="1")
        self.env.pop("CODEX_THREAD_ID", None)

    def run_cli(self, *args, rc=0, mode="task", env=None):
        result = subprocess.run([str(CLI), mode, *map(str, args)], env=env or self.env,
                                cwd=self.repo, capture_output=True, text=True, timeout=25)
        self.assertEqual(result.returncode, rc, result.stderr + result.stdout)
        return json.loads(result.stdout) if result.stdout.strip() else None

    def create(self, task_id="t", worker="worker-1"):
        return self.run_cli("create", "--id", task_id, "--worker", worker, "--file", self.req)

    def claim(self, task_id="t"):
        return self.run_cli("claim", task_id, "--session", "worker-1")

    def update(self, state, revision=None, task_id="t", rc=0, **kwargs):
        if revision is None:
            revision = self.run_cli("status", task_id)["revision"]
        args = ["update", task_id, "--session", "worker-1", "--revision", revision,
                "--state", state, "--message", kwargs.pop("message", "test progress")]
        for key, value in kwargs.items():
            args.extend(["--" + key.replace("_", "-"), value])
        return self.run_cli(*args, rc=rc)

    def finish(self, task_id="t"):
        return self.update("complete", task_id=task_id, file=self.report)

    def test_idempotent_creation_and_conflicting_request(self):
        original = self.create()
        self.assertEqual(self.create(), original)
        self.req.write_text("different task")
        self.run_cli("create", "--id", "t", "--worker", "worker-1", "--file", self.req, rc=1)
        self.assertEqual(self.run_cli("status", "t")["request"], original["request"])

    def test_idempotency_is_bound_to_checkout_worker_and_requester(self):
        self.create()
        self.run_cli("create", "--id", "t", "--worker", "worker-2", "--file", self.req, rc=1)
        self.run_cli("create", "--id", "t", "--worker", "worker-1", "--requester", "other", "--file", self.req, rc=1)
        other = self.root / "other"
        other.mkdir()
        self.repo = other
        self.run_cli("create", "--id", "t", "--worker", "worker-1", "--file", self.req, rc=1)

    def test_worker_name_can_be_bound_before_delivery_but_never_retargeted(self):
        self.create()
        routed = self.run_cli("create", "--id", "t", "--worker", "worker-1", "--file", self.req,
                              "--worker-name", "fixture worker")
        self.assertEqual(routed["worker_name"], "fixture worker")
        self.assertEqual(self.create()["worker_name"], "fixture worker")
        self.run_cli("create", "--id", "t", "--worker", "worker-1", "--file", self.req,
                     "--worker-name", "another worker", rc=1)
        self.create("claimed")
        self.claim("claimed")
        self.run_cli("create", "--id", "claimed", "--worker", "worker-1", "--file", self.req,
                     "--worker-name", "too late", rc=1)
        self.create("delivered")
        self.run_cli("delivered", "delivered", "--receipt", "accepted")
        self.run_cli("create", "--id", "delivered", "--worker", "worker-1", "--file", self.req,
                     "--worker-name", "too late", rc=1)

    def test_invalid_worker_name_is_not_recorded(self):
        for name in ("", "one\ntwo", "x" * 121):
            self.run_cli("create", "--id", "t", "--worker", "worker-1", "--file", self.req,
                         "--worker-name", name, rc=1)
        self.run_cli("status", "t", rc=1)

    def test_rejects_path_traversal_and_invalid_input(self):
        for name in ("../oops", "x/y", "a\nb", "", "x" * 121):
            self.run_cli("create", "--id", name, "--worker", "worker-1", "--file", self.req, rc=1)
        self.req.write_text(" ")
        self.run_cli("create", "--id", "empty", "--worker", "worker-1", "--file", self.req, rc=1)

    def test_concurrent_creation(self):
        with concurrent.futures.ThreadPoolExecutor(max_workers=8) as pool:
            tasks = list(pool.map(lambda _: self.create(), range(12)))
        self.assertEqual(len({t["revision"] for t in tasks}), 1)
        self.assertEqual(len(self.run_cli("events", "t")), 1)

    def test_only_one_concurrent_claim_can_execute(self):
        self.create()
        with concurrent.futures.ThreadPoolExecutor(max_workers=8) as pool:
            claims = list(pool.map(lambda _: self.claim(), range(12)))
        self.assertEqual(sum(c["execute"] for c in claims), 1)
        self.assertEqual(self.run_cli("status", "t")["state"], "acknowledged")

    def test_wrong_worker_never_claims_or_updates(self):
        self.create()
        self.run_cli("claim", "t", "--session", "worker-2", rc=1)
        self.claim()
        self.run_cli("update", "t", "--session", "worker-2", "--revision", 2,
                     "--state", "running", "--message", "oops", rc=1)

    def test_progress_requires_claim_and_current_revision(self):
        self.create()
        self.update("running", rc=1)
        self.claim()
        self.update("running", revision=1, rc=1)
        running = self.update("running")
        self.assertEqual(running["revision"], 3)
        self.update("preflight", rc=1)

    def test_concurrent_updates_have_one_winner(self):
        self.create()
        self.claim()
        cmd = [str(CLI), "task", "update", "t", "--session", "worker-1", "--revision", "2",
               "--state", "running", "--message", "race"]
        with concurrent.futures.ThreadPoolExecutor(max_workers=2) as pool:
            results = list(pool.map(lambda _: subprocess.run(cmd, cwd=self.repo, env=self.env,
                                                            capture_output=True), range(2)))
        self.assertEqual(sorted(r.returncode for r in results), [0, 1])

    def test_receipt_is_not_acknowledgment_or_completion(self):
        self.create()
        self.run_cli("delivered", "t", "--receipt", "message-1")
        task = self.run_cli("wait", "t", "--timeout", 0, rc=124)
        self.assertEqual(task["state"], "created")
        self.assertEqual(task["delivery_receipt"], "message-1")
        self.run_cli("result", "t", rc=3)

    def test_late_receipt_cannot_demote_complete_or_invalidate_ack(self):
        self.create()
        self.claim()
        done = self.finish()
        self.run_cli("ack", "t", "--consumer", "codex-1", "--revision", done["revision"])
        task = self.run_cli("delivered", "t", "--receipt", "late-message")
        self.assertEqual(task["revision"], done["revision"])
        self.assertEqual(task["state"], "complete")
        self.assertEqual(self.run_cli("inbox", "--consumer", "codex-1"), [])

    def test_complete_snapshots_report_survives_original_deletion(self):
        self.create()
        self.claim()
        done = self.finish()
        self.report.unlink()
        self.assertEqual(self.run_cli("result", "t")["result"], done["result"])
        self.assertEqual(self.run_cli("wait", "t", "--timeout", 0)["state"], "complete")
        self.assertFalse(self.claim()["execute"])

    def test_terminal_outcomes_are_immutable(self):
        for state in ("complete", "refused", "failed"):
            with self.subTest(state=state):
                self.create(state)
                self.claim(state)
                self.update(state, task_id=state, **({"file": self.report} if state == "complete" else {}))
                self.update("running", task_id=state, rc=1)
                self.assertFalse(self.claim(state)["execute"])

    def test_complete_requires_valid_report(self):
        self.create()
        self.claim()
        self.update("complete", rc=1)
        self.update("complete", file=self.root / "missing", rc=1)
        self.report.write_bytes(b"\xff")
        self.update("complete", file=self.report, rc=1)
        self.assertEqual(self.run_cli("status", "t")["state"], "acknowledged")

    def test_blocker_returns_attention_and_can_continue_after_resolution(self):
        self.create()
        self.claim()
        self.update("needs_attention", rc=1)
        blocker = self.update("needs_attention", action_needed="Operator must restore fixture")
        self.assertEqual(self.run_cli("wait", "t", "--timeout", 0, rc=3)["action_needed"], blocker["action_needed"])
        self.update("running")
        self.finish()

    def test_inbox_replays_until_explicit_idempotent_ack(self):
        self.create()
        self.claim()
        done = self.finish()
        self.assertEqual(len(self.run_cli("inbox", "--consumer", "codex-1")), 1)
        self.assertEqual(len(self.run_cli("inbox", "--consumer", "codex-1")), 1)
        self.run_cli("ack", "t", "--consumer", "codex-1", "--revision", 2, rc=1)
        first = self.run_cli("ack", "t", "--consumer", "codex-1", "--revision", done["revision"])
        repeat = self.run_cli("ack", "t", "--consumer", "codex-1", "--revision", done["revision"])
        self.assertTrue(first["acknowledged"])
        self.assertFalse(repeat["acknowledged"])
        self.assertEqual(self.run_cli("inbox", "--consumer", "codex-1"), [])
        self.assertEqual(len(self.run_cli("inbox", "--consumer", "codex-2")), 1)

    def test_attention_ack_does_not_hide_later_completion(self):
        self.create()
        self.claim()
        blocker = self.update("needs_attention", action_needed="needed")
        self.run_cli("ack", "t", "--consumer", "codex-1", "--revision", blocker["revision"])
        self.finish()
        self.assertEqual(self.run_cli("inbox", "--consumer", "codex-1")[0]["state"], "complete")

    def test_inbox_checkout_filter(self):
        self.create()
        self.claim()
        self.finish()
        self.assertEqual(self.run_cli("inbox", "--consumer", "codex-1", "--repo", self.root), [])

    def test_staleness_does_not_imply_dead_worker_or_release_claim(self):
        self.create()
        self.claim()
        status = self.run_cli("status", "t", "--stale-after", 0)
        self.assertTrue(status["stale"])
        self.assertEqual(status["state"], "acknowledged")
        self.assertFalse(self.claim()["execute"])

    def test_foreground_wait_observes_later_completion(self):
        self.create()
        self.claim()
        waiter = subprocess.Popen([str(CLI), "task", "wait", "t", "--timeout", "5"],
                                  cwd=self.repo, env=self.env, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        self.finish()
        output, errors = waiter.communicate(timeout=8)
        self.assertEqual(waiter.returncode, 0, errors)
        self.assertEqual(json.loads(output)["state"], "complete")

    def test_waiter_exit_does_not_lose_completion(self):
        self.create()
        self.claim()
        self.run_cli("wait", "t", "--timeout", 0, rc=124)
        self.finish()
        self.assertEqual(len(self.run_cli("inbox", "--consumer", "restarted-codex")), 1)

    def test_history_retains_each_transition(self):
        self.create()
        self.claim()
        self.update("preflight")
        self.update("running")
        self.finish()
        events = self.run_cli("events", "t")
        self.assertEqual([e["revision"] for e in events], [1, 2, 3, 4, 5])
        self.assertEqual([e["state"] for e in events], ["created", "acknowledged", "preflight", "running", "complete"])

    def test_transaction_failure_rolls_back_state_and_event(self):
        self.create()
        box = mailbox.Mailbox(self.store)
        self.addCleanup(box.db.close)
        box.db.execute("CREATE TRIGGER fail_event BEFORE INSERT ON events BEGIN SELECT RAISE(ABORT, 'disk fault'); END")
        with self.assertRaises(sqlite3.Error):
            box.claim("t", "worker-1")
        self.assertEqual(box.get("t")["state"], "created")
        self.assertEqual(len(self.run_cli("events", "t")), 1)

    def test_failed_commit_releases_transaction_and_can_retry(self):
        self.create()
        box = mailbox.Mailbox(self.store)
        self.addCleanup(box.db.close)
        box.db.execute('PRAGMA busy_timeout=20')
        reader = sqlite3.connect(self.store / 'tasks.sqlite3', isolation_level=None)
        self.addCleanup(reader.close)
        reader.execute('BEGIN')
        reader.execute('SELECT * FROM tasks').fetchall()
        # A real SQLite reader allows BEGIN/UPDATE but prevents COMMIT.
        with self.assertRaisesRegex(sqlite3.OperationalError, 'locked'):
            box.claim('t', 'worker-1')
        self.assertFalse(box.db.in_transaction)
        self.assertEqual(box.get('t')['state'], 'created')
        reader.execute('ROLLBACK')
        self.assertTrue(box.claim('t', 'worker-1')['execute'])
        self.assertEqual(len(self.run_cli('events', 't')), 2)

    def test_schema_one_upgrade_preserves_pending_completed_and_acknowledged_tasks(self):
        self.create('pending')
        self.create('finished')
        self.claim('finished')
        final = self.finish('finished')
        self.run_cli('ack', 'finished', '--consumer', 'reader', '--revision', final['revision'])
        box = mailbox.Mailbox(self.store)
        before = {name: box.get(name) for name in ('pending', 'finished')}
        events = [tuple(r) for r in box.db.execute('SELECT * FROM events ORDER BY task_id,revision')]
        acks = [tuple(r) for r in box.db.execute('SELECT * FROM acknowledgments')]
        box.db.execute('PRAGMA user_version=1')
        box.db.close()
        upgraded = mailbox.Mailbox(self.store)
        self.addCleanup(upgraded.db.close)
        self.assertEqual(upgraded.db.execute('PRAGMA user_version').fetchone()[0], 2)
        self.assertEqual({name: upgraded.get(name) for name in before}, before)
        self.assertEqual([tuple(r) for r in upgraded.db.execute('SELECT * FROM events ORDER BY task_id,revision')], events)
        self.assertEqual([tuple(r) for r in upgraded.db.execute('SELECT * FROM acknowledgments')], acks)
        self.assertFalse(upgraded.claim('finished', 'worker-1')['execute'])
        self.assertTrue(upgraded.claim('pending', 'worker-1')['execute'])

    def test_corruption_and_symlinked_database_fail_closed(self):
        self.store.mkdir()
        target = self.root / "do-not-touch"
        target.write_text("original")
        path = self.store / "tasks.sqlite3"
        path.symlink_to(target)
        self.run_cli("status", "t", rc=1)
        self.assertEqual(target.read_text(), "original")
        path.unlink()
        path.write_bytes(b"partial database write")
        self.run_cli("status", "t", rc=1)

    def test_tampered_result_and_request_are_rejected(self):
        self.create()
        self.claim()
        self.finish()
        with sqlite3.connect(self.store / "tasks.sqlite3") as db:
            db.execute("UPDATE tasks SET result='corrupt' WHERE id='t'")
        self.run_cli("result", "t", rc=1)
        self.run_cli("wait", "t", "--timeout", 0, rc=1)
        self.run_cli("inbox", "--consumer", "codex", rc=1)
        self.create("request-tamper")
        with sqlite3.connect(self.store / "tasks.sqlite3") as db:
            db.execute("UPDATE tasks SET request='changed request' WHERE id='request-tamper'")
        self.run_cli("claim", "request-tamper", "--session", "worker-1", rc=1)

    def test_killed_writer_rolls_back_uncommitted_state(self):
        self.create()
        code = """import sqlite3, sys, time
db = sqlite3.connect(sys.argv[1], isolation_level=None)
db.execute('BEGIN IMMEDIATE')
db.execute("UPDATE tasks SET state='running', revision=99 WHERE id='t'")
print('transaction started', flush=True)
time.sleep(30)
"""
        writer = subprocess.Popen([sys.executable, "-c", code, str(self.store / "tasks.sqlite3")],
                                  stdout=subprocess.PIPE, text=True)
        try:
            self.assertEqual(writer.stdout.readline().strip(), "transaction started")
        finally:
            writer.kill()
            writer.communicate(timeout=3)
        task = self.run_cli("status", "t")
        self.assertEqual((task["state"], task["revision"]), ("created", 1))

    def test_future_database_schema_and_symlinked_journal_are_rejected(self):
        self.create()
        journal = self.store / "tasks.sqlite3-journal"
        target = self.root / "protected"
        target.write_text("unchanged")
        journal.symlink_to(target)
        self.run_cli("status", "t", rc=1)
        self.assertEqual(target.read_text(), "unchanged")
        journal.unlink()
        with sqlite3.connect(self.store / "tasks.sqlite3") as db:
            db.execute("PRAGMA user_version=999")
        self.run_cli("status", "t", rc=1)

    def test_journal_disappearing_during_safety_check_is_not_an_unsafe_file(self):
        self.create()
        journal = self.store / "tasks.sqlite3-journal"
        journal.write_bytes(b"")
        real_is_file = Path.is_file
        def raced_is_file(path):
            # Reproduce a concurrent writer committing after an exists() check
            # but before a separate is_file() check. One lstat avoids this race.
            if path == journal and journal.exists():
                journal.unlink()
            return real_is_file(path)
        with mock.patch.object(Path, "is_file", raced_is_file):
            box = mailbox.Mailbox(self.store)
            self.addCleanup(box.db.close)
            self.assertEqual(box.get("t")["state"], "created")

    def test_invalid_timeouts_are_rejected(self):
        self.create()
        for value in ("-1", "nan", "999999999999999999999", "86401"):
            self.run_cli("wait", "t", "--timeout", value, rc=2)

    def test_private_store_permissions(self):
        self.create()
        self.assertEqual(self.store.stat().st_mode & 0o777, 0o700)
        self.assertEqual((self.store / "tasks.sqlite3").stat().st_mode & 0o777, 0o600)

    def test_non_regular_report_is_rejected_without_blocking(self):
        self.create()
        self.claim()
        fifo = self.root / "partial-report-pipe"
        os.mkfifo(fifo)
        result = subprocess.run([str(CLI), "task", "update", "t", "--session", "worker-1",
                                 "--revision", "2", "--state", "complete", "--message", "done",
                                 "--file", str(fifo)], cwd=self.repo, env=self.env,
                                capture_output=True, text=True, timeout=2)
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        self.assertEqual(self.run_cli("status", "t")["state"], "acknowledged")

    def test_many_concurrent_acknowledgments_have_one_first_consumer(self):
        self.create()
        self.claim()
        done = self.finish()
        def consume(_):
            return self.run_cli("ack", "t", "--consumer", "same-codex", "--revision", done["revision"])
        with concurrent.futures.ThreadPoolExecutor(max_workers=8) as pool:
            replies = list(pool.map(consume, range(16)))
        self.assertEqual(sum(r["acknowledged"] for r in replies), 1)

    def test_duplicate_delivery_during_execution_preserves_progress(self):
        self.create()
        self.claim()
        before = self.update("running", message="external executor already launched")
        self.run_cli("delivered", "t", "--receipt", "first")
        self.run_cli("delivered", "t", "--receipt", "duplicate")
        self.assertFalse(self.claim()["execute"])
        after = self.run_cli("status", "t")
        self.assertEqual(after["revision"], before["revision"])
        self.assertEqual(after["message"], before["message"])
        self.assertEqual(after["delivery_receipt"], "first")

    def test_restarted_worker_can_finish_reporting_without_second_execution(self):
        self.create()
        self.assertTrue(self.claim()["execute"])
        self.update("needs_attention", action_needed="executor needs reconciliation")
        self.assertFalse(self.claim()["execute"])
        self.run_cli("claim", "t", "--session", "replacement-with-other-uuid", rc=1)
        self.finish()
        events = self.run_cli("events", "t")
        self.assertEqual(sum(e["kind"] == "claimed" for e in events), 1)

    def test_independent_workers_complete_concurrently_without_crossing_results(self):
        def worker(i):
            task_id, session = f"task-{i}", f"worker-{i}"
            self.create(task_id, session)
            claim = self.run_cli("claim", task_id, "--session", session)
            report = self.root / (task_id + ".report")
            report.write_text("result for " + task_id)
            return self.run_cli("update", task_id, "--session", session,
                                "--revision", claim["task"]["revision"], "--state", "complete",
                                "--message", "done", "--file", report)
        with concurrent.futures.ThreadPoolExecutor(max_workers=6) as pool:
            results = list(pool.map(worker, range(12)))
        for i, result in enumerate(results):
            self.assertEqual((result["id"], result["worker"], result["result"]),
                             (f"task-{i}", f"worker-{i}", f"result for task-{i}"))
        self.assertEqual(len(self.run_cli("inbox", "--consumer", "collector")), 12)

    def test_symlinked_delivery_lock_is_not_followed(self):
        self.create()
        target = self.root / "protected-lock-target"
        target.write_text("unchanged")
        (self.store / ".task-delivery-t.lock").symlink_to(target)
        self.run_cli("--id", "t", "--worker", "worker-1", "--file", self.req, mode="delegate", rc=1)
        self.assertEqual(target.read_text(), "unchanged")

    def test_wait_any_collects_fast_worker_without_waiting_for_slow_worker(self):
        self.create("slow")
        self.claim("slow")
        self.create("fast")
        self.claim("fast")
        self.finish("fast")
        ready = self.run_cli("wait-any", "slow", "fast", "--consumer", "coordinator", "--timeout", 0)
        self.assertEqual([t["id"] for t in ready], ["fast"])
        self.assertEqual(self.run_cli("status", "slow")["state"], "acknowledged")

    def test_wait_any_scopes_results_to_explicit_tasks_and_deduplicates_ids(self):
        for name in ("selected", "unrelated"):
            self.create(name)
            self.claim(name)
            self.finish(name)
        ready = self.run_cli("wait-any", "selected", "selected", "--consumer", "coordinator", "--timeout", 0)
        self.assertEqual([t["id"] for t in ready], ["selected"])
        with sqlite3.connect(self.store / "tasks.sqlite3") as db:
            db.execute("UPDATE tasks SET result='corrupt' WHERE id='unrelated'")
        self.assertEqual(len(self.run_cli("wait-any", "selected", "--consumer", "coordinator", "--timeout", 0)), 1)

    def test_wait_any_refuses_unknown_invalid_and_oversized_selection(self):
        self.create()
        for ids in (("t", "missing"), ("../escape",), tuple(f"t{i}" for i in range(257))):
            self.run_cli("wait-any", *ids, "--consumer", "coordinator", "--timeout", 0, rc=1)
        self.run_cli("wait-any", "t", "--consumer", "../bad", "--timeout", 0, rc=1)

    def test_wait_any_mixed_outcomes_and_acknowledgment_are_independent(self):
        for name, state in (("good", "complete"), ("bad", "failed"), ("blocked", "needs_attention")):
            self.create(name)
            self.claim(name)
            self.update(state, task_id=name, **({"file": self.report} if state == "complete" else
                                               {"action_needed": "approval"} if state == "needs_attention" else {}))
        args = ("wait-any", "good", "bad", "blocked", "--consumer", "coordinator", "--timeout", 0)
        ready = self.run_cli(*args, rc=3)
        self.assertEqual({t["id"] for t in ready}, {"good", "bad", "blocked"})
        for task in ready:
            self.run_cli("ack", task["id"], "--consumer", "coordinator", "--revision", task["revision"])
        self.assertEqual(self.run_cli(*args, rc=124), [])
        self.finish("blocked")
        self.assertEqual([t["id"] for t in self.run_cli(*args)], ["blocked"])

    def test_wait_any_consumers_do_not_hide_each_others_results(self):
        self.create()
        self.claim()
        done = self.finish()
        self.run_cli("ack", "t", "--consumer", "one", "--revision", done["revision"])
        self.assertEqual(self.run_cli("wait-any", "t", "--consumer", "one", "--timeout", 0, rc=124), [])
        self.assertEqual(self.run_cli("wait-any", "t", "--consumer", "two", "--timeout", 0)[0]["id"], "t")

    def test_wait_any_observes_new_completion_and_does_not_auto_ack(self):
        self.create()
        self.claim()
        waiter = subprocess.Popen([str(CLI), "task", "wait-any", "t", "--consumer", "coordinator", "--timeout", "5"],
                                  cwd=self.repo, env=self.env, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        try:
            self.finish()
            output, errors = waiter.communicate(timeout=8)
            self.assertEqual(waiter.returncode, 0, errors)
            self.assertEqual(json.loads(output)[0]["id"], "t")
            self.assertEqual(len(self.run_cli("inbox", "--consumer", "coordinator")), 1)
        finally:
            if waiter.poll() is None:
                waiter.kill()
                waiter.communicate(timeout=3)

    def test_multiple_distinct_tasks_can_belong_to_same_worker_without_merging(self):
        def job(i):
            name = f"job-{i}"
            self.create(name)
            self.assertTrue(self.claim(name)["execute"])
            return self.finish(name)
        with concurrent.futures.ThreadPoolExecutor(max_workers=8) as pool:
            results = list(pool.map(job, range(8)))
        self.assertEqual(len({t["id"] for t in results}), 8)
        self.assertEqual({t["worker"] for t in results}, {"worker-1"})
        for task in results:
            self.assertFalse(self.claim(task["id"])["execute"])

    def test_32_worker_pool_mixed_outcomes_remain_independent_across_two_jobs_each(self):
        states = ("complete", "needs_attention", "failed", "refused")
        def worker(i):
            results = []
            for round_number in range(2):
                task_id, session = f"pool-{i}-{round_number}", f"pool-worker-{i}"
                self.create(task_id, session)
                claim = self.run_cli("claim", task_id, "--session", session)
                self.assertTrue(claim["execute"])
                state = states[(i + round_number) % len(states)]
                args = ["update", task_id, "--session", session, "--revision", claim["task"]["revision"],
                        "--state", state, "--message", "outcome for " + task_id]
                if state == "complete":
                    report = self.root / (task_id + ".report")
                    report.write_text("result for " + task_id)
                    args.extend(["--file", report])
                elif state == "needs_attention":
                    args.extend(["--action-needed", "approval for " + task_id])
                results.append(self.run_cli(*args))
            return results
        with concurrent.futures.ThreadPoolExecutor(max_workers=32) as pool:
            results = [task for pair in pool.map(worker, range(32)) for task in pair]
        self.assertEqual(len({task["id"] for task in results}), 64)
        self.assertEqual(len({task["worker"] for task in results}), 32)
        for task in results:
            self.assertEqual(task["message"], "outcome for " + task["id"])
            self.assertEqual(task["result"], "result for " + task["id"] if task["state"] == "complete" else None)
            self.assertEqual(sum(e["kind"] == "claimed" for e in self.run_cli("events", task["id"])), 1)
        selected = [task["id"] for task in results]
        ready = self.run_cli("wait-any", *selected, "--consumer", "pool-coordinator", "--timeout", 0, rc=3)
        self.assertEqual({task["id"] for task in ready}, set(selected))
        with concurrent.futures.ThreadPoolExecutor(max_workers=16) as pool:
            list(pool.map(lambda task: self.run_cli("ack", task["id"], "--consumer", "pool-coordinator",
                                                  "--revision", task["revision"]), ready))
        self.assertEqual(self.run_cli("inbox", "--consumer", "pool-coordinator"), [])
        self.assertEqual(len(self.run_cli("inbox", "--consumer", "independent-observer")), 64)

    def test_utf8_size_limit_and_empty_report_leave_claim_recoverable(self):
        self.create()
        self.claim()
        for text in (" \n", "界" * (mailbox.MAX_TEXT // 3 + 1)):
            self.report.write_text(text)
            self.update("complete", file=self.report, rc=1)
        self.assertEqual(self.run_cli("status", "t")["state"], "acknowledged")
        self.report.write_text("valid recovered report")
        self.finish()

    def test_attention_ack_rejects_a_race_with_completion(self):
        self.create()
        self.claim()
        blocker = self.update("needs_attention", action_needed="test")
        done = self.finish()
        self.run_cli("ack", "t", "--consumer", "codex", "--revision", blocker["revision"], rc=1)
        self.assertEqual(self.run_cli("inbox", "--consumer", "codex")[0]["revision"], done["revision"])

    def test_delegate_reuses_completed_task_without_relay(self):
        self.create()
        self.claim()
        self.finish()
        env = dict(self.env, SECONDOPINION_CLAUDE="/nonexistent")
        task = self.run_cli("--id", "t", "--worker", "worker-1", "--file", self.req,
                            mode="delegate", env=env)
        self.assertEqual(task["state"], "complete")

    def test_delegate_refuses_concurrent_delivery(self):
        self.create()
        import fcntl
        with open(self.store / ".task-delivery-t.lock", "w") as lock:
            fcntl.flock(lock, fcntl.LOCK_EX)
            self.run_cli("--id", "t", "--worker", "worker-1", "--file", self.req, mode="delegate", rc=1)

    def test_relay_success_without_receipt_is_not_worker_success(self):
        self.create()
        box = mailbox.Mailbox(self.store)
        self.addCleanup(box.db.close)
        args = mailbox.parser().parse_args(["--store", str(self.store), "--cli", str(CLI),
                                            "delegate", "--id", "t", "--worker", "worker-1",
                                            "--file", str(self.req), "--requester", "local", "--timeout", "0"])
        with mock.patch.object(mailbox.Path, "cwd", return_value=self.repo), \
             mock.patch.object(mailbox.subprocess, "run", return_value=subprocess.CompletedProcess([], 0)), \
             mock.patch("relay_diagnostics.run_relay", return_value=(None, 0)), \
             mock.patch("worker_directory.Directory.bound", return_value={}), \
             mock.patch.object(mailbox, "emit"):
            self.assertEqual(mailbox.delegate(box, args), 1)
        self.assertEqual(box.get("t")["state"], "created")

    def test_real_cli_relay_and_separate_worker_process(self):
        for scenario, expected_rc, expected_state in (
            ("complete", 0, "complete"), ("refused", 3, "refused"),
            ("relay-crash", 0, "complete"), ("delivery-only", 124, "created"),
            ("no-tools", 1, "created"),
        ):
            with self.subTest(scenario=scenario):
                env = dict(self.env, SECONDOPINION_CLAUDE=str(ROOT / "tests/fake_task_claude.py"),
                           TASK_FIXTURE_SCENARIO=scenario, TASK_FIXTURE_CLI=str(CLI))
                result = self.run_cli("--id", scenario, "--worker", "worker-1", "--file", self.req,
                                     "--timeout", "1", "--delivery-timeout", "10", mode="delegate",
                                     env=env, rc=expected_rc)
                task = result.get("task", result)
                self.assertEqual(task["state"], expected_state)
                if expected_state == "complete":
                    self.assertEqual(task["result"], "worker report after relay exit\n")
                if scenario == "delivery-only":
                    self.assertIsNotNone(task["delivered_utc"])

    def test_async_missing_host_capability_falls_back_without_operator_setup(self):
        env = dict(self.env, CODEX_THREAD_ID=str(uuid.uuid4()),
                   SECONDOPINION_CLAUDE=str(ROOT / "tests/fake_task_claude.py"),
                   TASK_FIXTURE_SCENARIO="complete", TASK_FIXTURE_CLI=str(CLI))
        task = self.run_cli("--async", "--id", "fallback", "--worker", "worker-1", "--file", self.req,
                            "--timeout", "2", "--delivery-timeout", "10", mode="delegate", env=env)
        self.assertEqual(task["state"], "complete")
        self.assertEqual(task["result"], "worker report after relay exit\n")

    def test_async_wrong_requester_rejects_before_contacting_worker(self):
        env = dict(self.env, CODEX_THREAD_ID=str(uuid.uuid4()))
        self.run_cli("--async", "--id", "wrong-caller", "--requester", str(uuid.uuid4()),
                     "--worker", "worker-1", "--file", self.req, mode="delegate", env=env, rc=1)
        self.assertEqual(self.run_cli("status", "wrong-caller")["state"], "created")
        self.assertFalse((self.store / "exchanges").exists())


if __name__ == "__main__":
    unittest.main(verbosity=2)
