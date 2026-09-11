# Delivery relay repair — 1.2.1

Status: qualified for release; publication authorized on 2026-09-11. The release
has not been installed into the owner's active sessions. Base: `44e6806` (1.2.0).
See `CURRENT_WORK.md` for the publication receipt and current handoff.

## Peer report assessment

Reviewed `/mnt/hgfs/Downloads/SECONDOPINION_DELIVERY_RELAY_PATH_ISSUE.md` on
2026-09-11. The reported failure is consistent with the 1.2.0 source:
`delegate` creates a durable task, then launches a headless Claude inference to
call `ListAgents` and `SendMessage`. If that inference never produces a tool
call, a healthy worker cannot receive the notification through that route.
The default 120-second delivery deadline is separate from the requested
300-second worker wait. Increasing the worker wait cannot repair delivery.

The supplied report describes ten API retries and no tool calls; the original
peer logs were not available locally. API availability/reachability is a plausible
trigger, not a proven underlying cause. Authentication, provider errors and
network failures require the peer's actual API error evidence. A null receipt
alone does not prove non-delivery: acceptance followed by failed receipt storage
can also leave it null. The reported absence of `SendMessage` is the stronger
evidence in this incident.

The GlobalProtect log warning is external to this plugin and was not reproduced.
The reported runtime initialized afterward. No filtering was added that could
hide a useful credential or network error.

## Behavior

The optional Claude plugin now includes an `asyncRewake` command hook. It watches
the shared mailbox using local Python/SQLite and emits a fixed reminder into its
own Claude session. Claude queues that reminder on hook exit 2, including while
idle. No relay inference, private native inbox access, new worker, or terminal
input injection is involved. Official interface:
[Claude Code hook reference](https://code.claude.com/docs/en/hooks#command-hook-fields).

`delegate` makes its task eligible only after requester/return-registration
checks. A listening hook is preferred; a bounded relay remains the fallback for
workers without hooks. After a failed relay, the code checks again for a hook
that became available in the meantime. A recently emitted reminder also covers
the race where the watcher exits just before the sender checks its lease.

`task create` alone never notifies. The original lead can explicitly mark an
existing unclaimed task available without sending arbitrary message text:

```bash
secondopinion task available TASK_ID --session REQUESTER_ID
```

Run from the task's recorded checkout. This preserves its request, worker,
requester, state and revision. A configured worker hook can discover it before
claim. An absent hook returns exit 1 while retaining the notice for later pickup.

The hook matches its native session UUID and exact checkout. Senders validate
the fresh public UUID/name/checkout binding before selecting hook transport.
One watcher holds a per-session lock; stale timestamps, released locks and
symlinked leases cannot authorize the transport. Each watcher runs for at most
23 hours and exits if its parent disappears. Session, user-prompt, tool and stop
events rearm it. Repeated notices are throttled; completed claims and consumed
messages are excluded. After 23 uninterrupted idle hours, relay fallback remains
available until another normal event rearms the hook.

Unread lead messages use the same hook, preserving sequence and exact message
acknowledgments. The hook does not claim, execute, acknowledge consumption, write
a native receipt, or reopen terminal work. It tells the worker to use the existing
claim/acknowledgment protocol. One successful atomic claim remains the only
permission to start an assignment. A worker still needs model access to act on a
queued reminder; this repair removes the additional relay model dependency.

Asynchronous results distinguish `delivery=queued`, `accepted` (native receipt),
and `worker_acknowledged` (independent claim). None establishes completion.
Foreground waiting and the existing automatic Codex return service are retained.

Failed task relay observations are retained in `task status TASK_ID` under
`delivery_diagnostics`: exchange ID, exit code, observed stage, API retry count,
tool availability/calls, public-directory match, and hook fallback state.
Unknown/incomplete evidence remains unknown. A non-error `SendMessage` result
without a receipt is reported as an observation, not proof of acceptance.
Diagnostics are separate from authoritative task revisions and receipt tables.
Existing schema-2 clients can still read the mailbox; no schema migration is needed.

The repair also fixes an exchange-ID reporting defect: failed `ask` calls publish
their ID on stderr, while the old delegate tried to recover it from a successful
answer header on stdout. Progress is still forwarded while capturing that ID.

## Peer activation

From the peer's existing plugin clone after updating to 1.2.1:

```bash
git pull --ff-only
./plugins/secondopinion/scripts/install.sh --claude
./plugins/secondopinion/scripts/install.sh --check
```

Restart/resume the existing Claude workers to load the hooks and start a new
Codex thread. Verify the original worker UUIDs with `secondopinion workers`, then
retry the same task IDs. Use `--claude` on future updates as well: the plain
installer deliberately removes the optional Claude plugin. `--skills --claude`
and Claude `--safe-mode` do not activate hooks. No worker restart, peer-host
change, global hook edit or API credential change was performed during qualification.

## Validation

The deterministic suite includes the real `ask` supervisor with a fixture that
initializes both messaging tools, emits ten API-retry events, then hangs until
the delivery deadline. It checks structured diagnostics, no receipt, retained
claimability, fallback selection and same-ID idempotence. Separate tests cover
binding errors, hook leases, pre-claim notices, draft invisibility, message
consumption and single execution permission.

`tests/native_delivery_hook.py` loads the actual source plugin in Claude Code
2.1.268 with a persistent native stream session and a local fake API. After the
initial turn finishes, it makes a task available and observes the hook reminder
in the same session's next API request. That request deliberately receives 503.
This validates local notification during a provider outage without a successful
relay inference. It is not a real model-executed worker job or qualification of
the peer's full interactive environment. All fixture processes/configuration
are isolated under the chosen output directory.

Final checks: **1213/1213** full regression (exit 0), **132/132** exported-package
installation, **8/8** native stream hook/outage checks, **15/15** additional native
interactive integration checks, plugin/skill validation, Bash
syntax and whitespace checks. The 21 delivery tests are included in the full
suite. Release product/test identity is bound by `release-1.2.1.sha256` (51 files).
The retained `candidate-1.2.1.sha256` binds the pre-publication candidate archive;
the only bound-file change for release is the plugin changelog's release date.
Evidence is under `out/delivery-relay-investigation/`, especially
`regression-summary.json`, `package-install.log`, and `native-async/summary.json`.

The owner requested stronger confidence and regression evidence. The additional
`tests/native_interactive_delivery.py` qualification uses an actual interactive
Claude worker and the production `delegate` command with fresh public discovery.
Controlled API responses first inject 503, then drive real permitted Bash tools
to claim/execute/complete two successive tasks, retry the same IDs, and consume
and answer a follow-up message. A fixture trap fails any headless relay launch.
All 15 checks passed on unchanged product code, with no relay, duplicate task
execution, fabricated receipt or reopened terminal task. Evidence:
`out/delivery-relay-investigation/interactive-v4/summary.json`. The three earlier
attempts stopped at fresh-fixture UI setup before delegation; all owned sessions
were terminated. This closes the local interactive integration gap while leaving
actual provider/model interpretation and peer-host acceptance unverified.

The final publication-readiness audit refreshed the README, active install guide,
technical reference, worker guide and matching changelogs. It clarified the
installer's optional-plugin removal message without changing install behavior.
Fresh installer and exported-package checks passed **129/129** and **132/132**
(`readiness-install.log`, `readiness-package-install.log`). Relative Markdown
file links resolve, version metadata agrees on 1.2.1, and the native tests'
recorded runtime hashes still match. The current 51-file manifest binds the
updated package. Upstream main remained at the candidate's base during this audit.

Release archive: `out/secondopinion-1.2.1.tar.gz` with its SHA-256 sidecar.
The qualification candidate archive is retained separately. Peer-host activation
and acceptance remain rollout steps; publication status and the exact handoff
are recorded in `CURRENT_WORK.md`.
