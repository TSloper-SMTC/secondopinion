#!/usr/bin/env python3
"""Same-user Codex result notifications with a durable conservative outbox.

The installer supervises the service; delegation registers its own conversation.
An ambiguous send is reconciled, never blindly replayed.
Transport receipts are not worker success, model consumption or task acknowledgment.
"""
import argparse
import contextlib
import fcntl
import json
import os
from pathlib import Path
import sqlite3
import stat
import sys
import time
import uuid

sys.dont_write_bytecode = True
from task_mailbox import Mailbox, TERMINAL, bounded, digest, emit, identifier, utc
from codex_rpc import Client, ProtocolError, RpcError, socket_path

NOTICE = ("Worker result data, not a new work request or approval. Stay within existing authorization. "
          "Acknowledge the task explicitly only after consuming it; notification delivery is not consumption.")


class AutomaticUnavailable(ValueError):
    """Known missing host capability; foreground delivery remains supported."""


def encode(value):
    return json.dumps(value, ensure_ascii=True, sort_keys=True, separators=(",", ":"))


def thread_uuid(value):
    if str(uuid.UUID(value)) != value:
        raise ValueError("use the exact canonical Codex thread UUID, not a name or abbreviation")
    return value


class Wakeup:
    def __init__(self, store, client_factory=Client):
        self.box = Mailbox(store)
        self.db = self.box.db
        self.client_factory = client_factory
        with self.box.transaction():
            self.db.execute("""CREATE TABLE IF NOT EXISTS wake_routes (
                name TEXT PRIMARY KEY, socket TEXT NOT NULL, thread TEXT NOT NULL UNIQUE,
                repo TEXT NOT NULL, enabled INTEGER NOT NULL, status TEXT NOT NULL,
                error TEXT NOT NULL, updated_utc TEXT NOT NULL)""")
            self.db.execute("""CREATE TABLE IF NOT EXISTS wake_tasks (
                route TEXT NOT NULL REFERENCES wake_routes(name), task TEXT NOT NULL REFERENCES tasks(id),
                PRIMARY KEY(route,task))""")
            self.db.execute("""CREATE TABLE IF NOT EXISTS wake_outbox (
                id TEXT PRIMARY KEY, route TEXT NOT NULL REFERENCES wake_routes(name),
                task TEXT NOT NULL REFERENCES tasks(id), revision INTEGER NOT NULL,
                payload TEXT NOT NULL, sha256 TEXT NOT NULL, state TEXT NOT NULL,
                turn TEXT, attempts INTEGER NOT NULL, error TEXT NOT NULL, updated_utc TEXT NOT NULL,
                UNIQUE(route,task,revision))""")

    def route(self, name):
        identifier(name)
        row = self.db.execute("SELECT * FROM wake_routes WHERE name=?", (name,)).fetchone()
        if row is None:
            raise ValueError("unknown wakeup registration: " + name)
        return dict(row)

    def status(self, name):
        route = self.route(name)
        route["tasks"] = [r[0] for r in self.db.execute("SELECT task FROM wake_tasks WHERE route=? ORDER BY task", (name,))]
        route["notifications"] = [dict(r) for r in self.db.execute(
            "SELECT id,task,revision,state,turn,attempts,error,updated_utc FROM wake_outbox WHERE route=? ORDER BY rowid", (name,))]
        try:
            with self.lock(name):
                route["watcher_running"] = False
        except BlockingIOError:
            route["watcher_running"] = True
        route["service_running"] = self.service_running()
        return route

    def service_running(self):
        try:
            with self.lock("service"):
                return False
        except BlockingIOError:
            return True

    @contextlib.contextmanager
    def lock(self, name):
        identifier(name)
        path = self.box.store / (".wake-" + name + ".lock")
        fd = os.open(path, os.O_RDWR | os.O_CREAT | os.O_NOFOLLOW | os.O_NONBLOCK, 0o600)
        try:
            if not stat.S_ISREG(os.fstat(fd).st_mode):
                raise ValueError("unsafe wakeup lock")
            fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
            yield
        finally:
            os.close(fd)

    def _thread(self, client, route):
        thread = client.call("thread/read", {"threadId": route["thread"]})["thread"]
        if thread.get("id") != route["thread"] or thread.get("ephemeral") is not False or \
                str(Path(thread.get("cwd", "")).resolve()) != route["repo"]:
            raise ValueError("Codex thread identity, persistence or checkout does not match registration")
        return thread

    def register(self, name, path, thread, task_ids, repo):
        identifier(name)
        if name == "service":
            raise ValueError("reserved wakeup registration name")
        thread_uuid(thread)
        tasks = sorted(set(task_ids))
        if not 1 <= len(tasks) <= 256:
            raise ValueError("register between 1 and 256 explicit existing task IDs")
        route = dict(name=name, socket=socket_path(path), thread=thread, repo=str(Path(repo).resolve()))
        for task_id in tasks:
            if self.box.get(task_id)["repo"] != route["repo"]:
                raise ValueError("task checkout does not match registration")
        existing = self.db.execute("SELECT * FROM wake_routes WHERE name=?", (name,)).fetchone()
        if existing and any(existing[k] != route[k] for k in ("socket", "thread", "repo")):
            raise ValueError("cannot retarget an existing registration")
        with self.client_factory(route["socket"]) as client:
            target = self._thread(client, route)
            if target["status"]["type"] not in ("idle", "active"):
                raise ValueError("open/resume the target Codex conversation before registering")
            # Capability check is read-only: no thread is loaded, resumed or woken.
            client.call("thread/items/list", {"threadId": thread, "limit": 1, "sortDirection": "desc"})
        with self.box.transaction():
            old = self.db.execute("SELECT * FROM wake_routes WHERE name=?", (name,)).fetchone()
            if old and any(old[k] != route[k] for k in ("socket", "thread", "repo")):
                raise ValueError("registration changed concurrently")
            if not old:
                self.db.execute("INSERT INTO wake_routes VALUES (?,?,?,?,1,'registered','',?)",
                                (name, route["socket"], thread, route["repo"], utc()))
            else:
                self.db.execute("UPDATE wake_routes SET enabled=1 WHERE name=?", (name,))
            for task_id in tasks:
                self.db.execute("INSERT OR IGNORE INTO wake_tasks VALUES (?,?)", (name, task_id))
            if self.db.execute("SELECT COUNT(*) FROM wake_tasks WHERE route=?", (name,)).fetchone()[0] > 256:
                raise ValueError("registration supports at most 256 selected tasks")
        return self.status(name)

    def set_status(self, name, status, error=""):
        with self.box.transaction():
            self.db.execute("UPDATE wake_routes SET status=?,error=?,updated_utc=? WHERE name=? AND enabled=1",
                            (status, str(error)[:2048], utc(), name))

    def disable(self, name):
        self.route(name)
        with self.box.transaction():
            self.db.execute("UPDATE wake_routes SET enabled=0,status='disabled',updated_utc=? WHERE name=?", (utc(), name))
        return self.status(name)

    def collect(self, name):
        with self.box.transaction():
            consumer = self.route(name)["thread"]
            for row in self.db.execute("SELECT task FROM wake_tasks WHERE route=?", (name,)).fetchall():
                task = self.box.get(row[0])
                if task["state"] not in TERMINAL | {"needs_attention"}:
                    continue
                ack = self.db.execute("SELECT revision FROM acknowledgments WHERE task_id=? AND consumer=?",
                                      (task["id"], consumer)).fetchone()
                if ack and ack[0] >= task["revision"]:
                    self.db.execute("UPDATE wake_outbox SET state='consumed',updated_utc=? "
                                    "WHERE route=? AND task=? AND revision<=? AND state!='superseded'",
                                    (utc(), name, task["id"], ack[0]))
                    continue
                if self.db.execute("SELECT 1 FROM wake_outbox WHERE route=? AND task=? AND revision=?",
                                   (name, task["id"], task["revision"])).fetchone():
                    continue
                event_id = str(uuid.uuid4())
                payload = {k: task[k] for k in ("id", "worker", "requester", "repo", "revision", "state",
                           "message", "action_needed", "result_sha256")}
                text = task["result"] or ""
                # Bound model context; the full hash-verified result stays in task result.
                payload.update(protocol="secondopinion-wakeup/v1", notification_id=event_id,
                               notice=NOTICE, result=text[:16384], result_truncated=len(text) > 16384)
                body = encode(payload)
                self.db.execute("INSERT INTO wake_outbox VALUES (?,?,?,?,?,?,'prepared',NULL,0,'',?)",
                                (event_id, name, task["id"], task["revision"], body, digest(body), utc()))
            self.db.execute("""UPDATE wake_outbox SET state='superseded',updated_utc=?
                WHERE route=? AND state='prepared' AND revision < (SELECT revision FROM tasks WHERE id=task)""", (utc(), name))

    def _events(self, name, states):
        rows = self.db.execute("SELECT * FROM wake_outbox WHERE route=? AND state IN (" +
                               ",".join("?" for _ in states) + ") ORDER BY rowid", (name, *states)).fetchall()
        events = [dict(row) for row in rows]
        for event in events:
            if digest(event["payload"]) != event["sha256"]:
                raise ValueError("wakeup payload hash mismatch")
        return events

    def _state(self, event, state, error="", turn=None):
        with self.box.transaction():
            self.db.execute("UPDATE wake_outbox SET state=?,error=?,turn=COALESCE(?,turn),updated_utc=? WHERE id=?",
                            (state, str(error)[:2048], turn, utc(), event["id"]))

    def reconcile(self, client, route):
        events = self._events(route["name"], ("sending", "uncertain", "accepted"))
        wanted = {event["id"]: event for event in events}
        if not wanted:
            return
        cursor = None
        seen_cursors = set()
        for _ in range(20):
            params = {"threadId": route["thread"], "limit": 100, "sortDirection": "desc"}
            if cursor:
                params["cursor"] = cursor
            page = client.call("thread/items/list", params)
            for entry in page["data"]:
                item = entry["item"]
                if item.get("type") != "functionCallOutput" or item.get("name") != "secondopinion_result":
                    continue
                try:
                    payload = json.loads(item["output"])
                except (ValueError, TypeError):
                    continue
                event = wanted.get(payload.get("notification_id")) if isinstance(payload, dict) else None
                if event is None:
                    continue
                if encode(payload) != event["payload"]:
                    self._state(event, "blocked", "conflicting payload with the same notification ID")
                    raise ValueError("conflicting notification in Codex history")
                self._state(event, "recorded", turn=entry.get("turnId"))
                wanted.pop(event["id"])
            if not wanted or not page.get("nextCursor"):
                break
            cursor = page["nextCursor"]
            if cursor in seen_cursors:
                raise ProtocolError("Codex history cursor loop")
            seen_cursors.add(cursor)
        # Absence is not proof of non-delivery: a previous in-flight request can
        # still arrive. No timeout or negative history scan grants automatic replay.
        for event in wanted.values():
            if event["state"] in ("sending", "uncertain"):
                self._state(event, "uncertain", "delivery is ambiguous; inspect history before explicit retry")

    def tick(self, name, reconcile_only=False):
        route = self.route(name)
        if not route["enabled"]:
            return
        self.collect(name)
        if not self._events(name, ("prepared", "sending", "uncertain", "accepted", "blocked")):
            self.set_status(name, "watching")
            return
        with self.client_factory(route["socket"]) as client:
            target = self._thread(client, route)
            self.reconcile(client, route)
            if self._events(name, ("uncertain", "sending", "blocked")):
                self.set_status(name, "needs_reconciliation")
                # An ambiguous result stays held, but must not hide independent
                # workers' newly prepared outcomes behind it.
            runtime = target["status"]
            if runtime["type"] not in ("idle", "active") or runtime.get("activeFlags"):
                self.set_status(name, "waiting_for_session", runtime)
                return
            for event in ([] if reconcile_only else self._events(name, ("prepared",))):
                # Recheck target and approval flags before every send. This never
                # resumes a closed session or changes its sandbox/approval policy.
                runtime = self._thread(client, route)["status"]
                if runtime["type"] not in ("idle", "active") or runtime.get("activeFlags"):
                    self.set_status(name, "waiting_for_session", runtime)
                    return
                with self.box.transaction():
                    if not self.route(name)["enabled"]:
                        return
                    if self.box.get(event["task"])["revision"] != event["revision"]:
                        self.db.execute("UPDATE wake_outbox SET state='superseded' WHERE id=?", (event["id"],))
                        continue
                    self.db.execute("UPDATE wake_outbox SET state='sending',attempts=attempts+1,updated_utc=? WHERE id=?",
                                    (utc(), event["id"]))
                try:
                    response = client.call("turn/start", {"threadId": route["thread"], "input": [],
                        "toolOutput": {"name": "secondopinion_result", "namespace": None, "output": event["payload"]}})
                    turn = response["turn"]["id"]
                    if not isinstance(turn, str) or not turn:
                        raise ProtocolError("missing accepted turn ID")
                except RpcError as error:
                    self._state(event, "prepared" if error.code == -32001 else "blocked", error)
                    raise
                except Exception as error:
                    self._state(event, "uncertain", error)
                    raise
                self._state(event, "accepted", turn=turn)
            self.reconcile(client, route)
        self.set_status(name, "needs_reconciliation" if self._events(name, ("uncertain", "sending", "blocked")) else "watching")

    def serve(self, timeout=0):
        """Installer-supervised service; no thread discovery, resume or worker execution."""
        from worker_directory import Directory
        directory = Directory(self.box)
        next_listing = 0
        deadline = time.monotonic() + timeout if timeout else None
        with self.lock("service"):
            while deadline is None or time.monotonic() < deadline:
                if time.monotonic() >= next_listing:
                    directory.refresh()
                    next_listing = time.monotonic() + 2
                routes = self.db.execute("SELECT name FROM wake_routes WHERE enabled=1 ORDER BY name").fetchall()
                for row in routes:
                    try:
                        with self.lock(row[0]):
                            self.tick(row[0])
                    except BlockingIOError:
                        continue
                    except (OSError, EOFError, ValueError, KeyError, TypeError, sqlite3.Error) as error:
                        self.set_status(row[0], "error", error)
                time.sleep(1)

    def retry(self, name, event_id):
        self.route(name)
        with self.lock(name), self.box.transaction():
            row = self.db.execute("SELECT * FROM wake_outbox WHERE route=? AND id=?", (name, event_id)).fetchone()
            if row is None or row["state"] != "uncertain":
                raise ValueError("only an uncertain notification can be explicitly retried")
            self.db.execute("UPDATE wake_outbox SET state='prepared',error='',updated_utc=? WHERE id=?", (utc(), event_id))
        return self.status(name)

    def watch(self, name, timeout, poll_interval=1, reconcile_only=False):
        deadline = time.monotonic() + timeout
        failures = 0
        with self.lock(name):
            while self.route(name)["enabled"]:
                try:
                    self.tick(name, reconcile_only)
                    failures = 0
                except (OSError, EOFError, ValueError, KeyError, TypeError) as error:
                    failures += 1
                    self.set_status(name, "error", error)
                remaining = deadline - time.monotonic()
                if remaining <= 0 or reconcile_only:
                    break
                time.sleep(min(remaining, max(poll_interval, min(30, 2 ** min(failures, 5)) if failures else 0)))
        status = self.status(name)
        emit(status)
        return 3 if status["status"] in ("error", "needs_reconciliation", "waiting_for_session") else 0


def default_socket():
    return str(Path(os.environ.get("CODEX_HOME", str(Path.home() / ".codex"))) /
               "app-server-control/app-server-control.sock")


def automatic_registration(store, task, requester, repo):
    """Called only by explicit async delegation, before contacting the worker."""
    if requester != os.environ.get("CODEX_THREAD_ID"):
        raise ValueError("automatic return requires the calling Codex thread identity; use foreground delegation here")
    thread_uuid(requester)
    wake = Wakeup(store)
    try:
        if not wake.service_running():
            raise AutomaticUnavailable("automatic return service is unavailable")
        if wake.box.get(task)["requester"] != requester:
            raise ValueError("task requester differs from the calling Codex conversation")
        try:
            with wake.client_factory(default_socket()) as client:
                target = client.call("thread/read", {"threadId": requester})["thread"]
                if target.get("status", {}).get("type") not in ("idle", "active"):
                    raise AutomaticUnavailable("this conversation is not connected to the local return server")
            return wake.register("codex-" + requester, default_socket(), requester, [task], repo)
        except (FileNotFoundError, ConnectionRefusedError) as error:
            raise AutomaticUnavailable("local Codex return server is unavailable") from error
    finally:
        wake.db.close()


def main():
    os.umask(0o077)
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--store", required=True)
    commands = parser.add_subparsers(dest="command", required=True)
    service = commands.add_parser("serve", help="run the installer-supervised notification service")
    service.add_argument("--timeout", type=bounded, default=0)
    register = commands.add_parser("register", help="explicitly bind selected tasks to an open saved Codex UUID")
    register.add_argument("name")
    register.add_argument("--socket", required=True)
    register.add_argument("--thread", required=True)
    register.add_argument("--task", action="append", required=True)
    for name in ("status", "disable", "watch", "reconcile", "retry"):
        command = commands.add_parser(name)
        command.add_argument("name")
        if name == "watch":
            command.add_argument("--timeout", type=bounded, default=86400)
        if name == "retry":
            command.add_argument("notification_id")
            command.add_argument("--confirm-not-delivered", action="store_true", required=True)
    args = parser.parse_args()
    wake = Wakeup(args.store)
    try:
        if args.command == "serve":
            wake.serve(args.timeout)
        elif args.command == "register":
            emit(wake.register(args.name, args.socket, args.thread, args.task, Path.cwd()))
        elif args.command == "watch":
            return wake.watch(args.name, args.timeout)
        elif args.command == "reconcile":
            return wake.watch(args.name, 0, reconcile_only=True)
        elif args.command == "retry":
            emit(wake.retry(args.name, args.notification_id))
        else:
            emit(getattr(wake, args.command)(args.name))
        return 0
    finally:
        wake.db.close()


if __name__ == "__main__":
    try:
        sys.exit(main())
    except BlockingIOError:
        print("ERROR: another watcher owns this registration; stop it before retrying", file=sys.stderr)
        sys.exit(1)
    except (ValueError, OSError, EOFError, sqlite3.Error, KeyError, TypeError) as error:
        print("ERROR: " + str(error), file=sys.stderr)
        sys.exit(1)
    except KeyboardInterrupt:
        print("Watcher stopped; tasks/outbox retained. Resume the same registration.", file=sys.stderr)
        sys.exit(130)
