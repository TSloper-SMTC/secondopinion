# Delegated worker validation — 2026-09-08–09

Historical foreground-mailbox qualification. At the time of these runs the
candidate was local and uninstalled. The later installed automatic-return
candidate and current release boundary are documented in
[automatic-return validation](automatic-return-validation.md). Counts and source
hashes below remain evidence for their original runs, not current release gates.

## Supported result

Codex can delegate an authorized task to an existing reachable Claude session,
let the delivery relay exit, and collect that worker's report through a bounded
foreground wait. Tasks persist independently of the relay exchange. Refusal,
failure, attention, and a wait timeout are distinct from successful completion.
The original direct `ask` workflow remains available.

The entry point and recovery commands are documented in the
[worker workflow](../plugins/secondopinion/skills/secondopinion-request/references/delegated-workers.md).
The implementation uses Python's standard-library SQLite with FULL synchronous
transactions, separate delivery receipts, monotonic worker revisions, immutable
terminal state, report snapshots plus SHA-256 validation, and explicit consumer
acknowledgments. Store it on a local filesystem, under the same Unix account.

## Automated evidence

The complete `tests/run.sh` gate passed again after the multi-worker journal-race
fix. Packaging was rerun after the final worker-guide changes, executing the
installed Codex cache directly. Final suite results:

| Suite | Passed | Failed |
| --- | ---: | ---: |
| `tests/test_install.sh` | 129 | 0 |
| `tests/test_parity.sh` | 166 | 0 |
| `tests/test_plugin.sh` | 116 | 0 |
| `tests/test_secondopinion.sh` | 563 | 0 |
| `tests/test_tasks.sh` | 51 | 0 |
| Total | 1025 | 0 |

The task tests cover concurrent creation, competing claims and revision updates;
duplicate/mismatched requests; wrong workers; immutable routes and outcomes;
receipt without acknowledgment/completion; late receipt after completion;
blockers and refusal; worker results surviving deletion of their source file;
foreground completion and later pickup; replay until explicit acknowledgment;
consumer/checkout isolation; staleness without automatic takeover; malformed
input, hash tampering, database corruption and unsafe symlinks; transaction
rollback including an actually killed writer; and unknown future schemas.
Additional cases exercise 12 independent concurrent workers, 16 competing
acknowledgments, duplicate delivery during execution, a restarted worker
continuing reporting without a new claim, report size/UTF-8 limits, acknowledgment
racing completion, and unsafe delivery locks. A FIFO report reproduced an
indefinite block before the fix; non-regular files now fail before reading.

The additional-worker tests exercise 32 concurrent simulated workers with two
distinct assignments each, mixed complete/attention/failed/refused outcomes,
multiple independent tasks on one worker, and selected-task `wait-any` collection.
The collector returns ready outcomes without waiting behind slower workers;
acknowledging an attention revision does not hide a later completion. Five
additional 32-worker/64-task stress runs passed; these repeated runs are not
added to the unique gate count above. This is mailbox/CLI load qualification,
not a claim that 32 native Claude sessions were run or that a host can afford them.

Repeated load exposed a real race: a normal SQLite commit could remove its journal
between separate `exists()` and `is_file()` checks, producing a false unsafe-file
error. A deterministic regression reproduced it before the fix. One `lstat`
snapshot now classifies each database object; links/non-regular files remain
rejected. Both the regression and repeated load pass after the fix. Retained
gate/stress logs are under `out/live-worker-pool-20260909-four-interactive-v3/`;
the final installed-payload rerun is under the corresponding `-v4/` directory.

Transport fixtures run the real CLI and separate worker processes for successful
completion, refusal, relay crash after delivery, receipt-only timeout, and absent
messaging tools. These fixtures do not establish native Claude messaging; the
live tests below provide that evidence. Nine added parity checks cover a missing
persisted session and fresh attach preserving parent context while clearing the
obsolete current session ID. Packaging verifies the new helper and workflow
reference survive a real isolated plugin installation.

Bash syntax, `git diff --check`, both skill validators, the official Codex plugin
validator, and strict Claude plugin/marketplace validation also passed.

## Live Claude evidence

Test runtime: Claude Code **2.1.263**. One isolated native background worker was
created through the public `claude --bg` command. Worker session:
`cc62af3a-32ef-48d3-98e5-1de44195a1b5`; exact name
`secondopinion-native-canary`; messaging reference `[9ebbeb]`.
No real project, hardware, or unrelated worker was targeted.

The test's scratch/store root was `/tmp/secondopinion-native.vmdg0W`; these
temporary artifacts are diagnostic conveniences, not required to interpret
the preserved observations below.

| Event (UTC) | Observation |
| --- | --- |
| 23:34:28.363629 | SendMessage accepted task `native-completion`, receipt `b404a4e7-c496-4f88-ab91-538e51a93280` |
| 23:34:32.056758 | Worker atomically claimed the task, revision 2 |
| 23:34:55 | Relay finished its validated exchange and exited |
| 23:35:18.536993 | Worker published running, revision 3 |
| 23:35:21.772154 | Worker published complete, revision 4; waiting delegate returned exit 0 |

The report was exactly `NATIVE_WORKER_OK`, SHA-256
`ce916e14c34b3c9e504a68695e0de174ee668821b503716a6ebd5b6d1e21cb1f`.
It arrived about **27 seconds after relay exit**, demonstrating the missing
return path from the coworker's report without an inbox reply to the relay.
Relay exchange: `2026-09-08T233347Z-delivery-native-completion`.

A separate `native-refusal` request used the verified worker-name mapping.
SendMessage receipt `a1c4a1c5-696b-41b1-8f5c-16837234ab7a` was recorded at
23:39:28.926924. The worker claimed revision 3 at 23:39:32.167062, then published
`refused`, revision 4, message `NATIVE_REFUSAL_OK`, at 23:39:38.775659.
`delegate` returned exit **3**, not success.

A real duplicate SendMessage (`09957397-a6f3-44b5-8fe2-a849aecf0e5d`, exchange
`2026-09-08T234132Z-native-duplicate-delivery`) reached the same worker. Its
public log confirmed `claim` returned `execute: false`. The four-event history,
terminal revision, and original receipt remained unchanged; no second execution
occurred. Later CLI invocations recovered both terminal tasks through `inbox`.
A first acknowledgment returned true, a repeated acknowledgment returned false,
and acknowledging both tasks left that consumer's inbox empty.

The worker was stopped using `claude stop cc62af3a`; the command confirmed it
stopped, and the public all-session listing subsequently reported `state=done`.
No test worker is intentionally left running.

## Expanded two-worker canary

The repeatable `tests/live_delegation.py` canary passed **20/20 live checks**
from 2026-09-09 00:01:57 to 00:07:07 UTC with Claude Code **2.1.266**.
Both plugin source hashes were unchanged from start to finish:

- CLI: `895ac4fdc8c183ded1aa5c3e86e660ed1c377bd9e6fc434d71ca52c628963a5e`
- Mailbox: `86e7071458845992f1486b79d4642fccbf52f9e7d70e05632d9600f05bd53e18`

| Scenario | Observed result |
| --- | --- |
| Two existing native workers receive concurrent tasks | Different UUIDs received their own task/result; no cross-routing |
| Foreground completion after messenger exit | Waiter stayed alive after relay exit; harness released the fixture; exact report returned |
| Original wait ends before work completes | `delegate` returned 124 with its gate still closed; a new wait collected the later result |
| Worker interruption/restart | Worker reported needs_attention; public stop/respawn preserved its UUID; it reconciled the existing effect/report and completed revision 6 |
| Duplicate delivery after completion | Worker re-claim returned execute=false; terminal history stayed unchanged |
| Fixture side effects | All three effect files recorded executions=1; no second-execution marker appeared |
| Consumer restart | A new consumer recovered all three reports; each first ack returned true and repeat ack false; final inbox empty |

The native terminal log explicitly ties `execute=false` to the duplicate
`foreground` message and result `LIVE_FOREGROUND_OK`. The canary's log predicate
was tightened afterward to ignore earlier duplicate evidence from the `restart`
task, then checked against this actual captured log and negative earlier-message
segments. This prevents a prior execute=false from satisfying the wrong check.

An earlier run passed delivery, result isolation, and late pickup but failed its
restart expectation: `claude --bg --resume` on 2.1.263 allocated a different UUID.
The mailbox kept the original claim; no replacement execution was authorized.
That failed run is retained. The successful run used the public `claude respawn`
command on 2.1.266 and verified the UUID afterward. This proves that specific
restart path; it does not prove all native resume variants preserve identity.
The canary now registers a launched ID for cleanup before discovery can fail.
The earlier replacement `346e5812` was also explicitly stopped after the failed
lookup; both workers in the successful run were stopped by its cleanup.

Retained local artifacts (ignored `out/`, not shipped in the Git payload):

- `out/live-delegation-20260909-respawn/summary.json`: checks, task snapshots,
  worker identities, source hashes, and cleanup confirmations.
- `out/live-delegation-20260909-respawn/worker-a.log`: public native log with
  restart reconciliation and task-specific duplicate rejection.
- `out/live-delegation-20260908-expanded/summary.json`: the failed native
  `--bg --resume` attempt, including its different returned UUID.
- `out/live-delegation-20260908-expanded/automated.log`: complete suite run.
- `out/live-delegation-20260908-expanded/installed-payload.log`: final packaging
  rerun, including execution from the installed Codex cache.

The [reference](reference.md#tests) gives the host-side canary command. These are
native background peers using the public messaging path. The coworker's exact
interactive sessions, Claude build, permissions, and bench task still require a
harmless acceptance run on his host. No hardware work was part of these tests.

## Four interactive workers — current source qualification

`tests/live_worker_pool.py` passed **36/36 live checks** on Claude Code 2.1.266
from **2026-09-09 00:43:10 to 00:49:25 UTC**. Four independent interactive
sessions were started in owned PTYs before delegating tasks. The public
`claude agents --json` listing confirmed `kind=interactive`, exact names,
session UUIDs and the fixture checkout. Temporary headless relays then used
the same native messaging approach described in the coworker's report.

| Existing worker | Task outcomes observed |
| --- | --- |
| A, `42a4538c-e379-49ac-851b-f20b339f2439` | Delayed `LIVE_FOREGROUND_OK`; caller killed; replacement waiter recovered result; native duplicate audited as execute=false |
| B, `9282d679-126d-40f5-bf61-480f4d34e932` | Original wait timed out; `LIVE_LATE_PICKUP_OK` collected before A finished |
| C, `cfe3777b-b1fd-4577-81d4-eaf6aaf4fc90` | TEST_APPROVAL_REQUIRED attention; original task completed with LIVE_APPROVED_REPORT_OK after reporting-only approval |
| D, `e3104296-ead3-44c9-8c4a-d97c588cabd5` | TEST_REFUSAL_OK refusal; a separate later assignment completed with LIVE_REUSE_OK |

`wait-any` returned the blocker/refusal while A and B were still running; B's
later result was collected without waiting for A. C's completion became visible
after its attention revision had been acknowledged. D's refusal remained
immutable and did not prevent its next assignment. Delivery to a nonexistent
unique peer failed unconfirmed, with no claim or execution. A fresh consumer
recovered all five outcomes, each first acknowledgment succeeded and each repeat
returned false, and its final inbox was empty.

The original waiting caller was actually SIGKILLed after messenger exit. The
interactive worker remained alive. All three execution fixtures recorded exactly
one execution and no second-execution marker. A native duplicate triggered a
reporting-only JSON audit containing execute=false and the correct task/worker
binding; no final-response wording is used as its oracle. All four owned
interactive processes were terminated and reaped (exit 143) during cleanup.

Current production hashes were identical at start, finish, and post-run verification:

- CLI: `895ac4fdc8c183ded1aa5c3e86e660ed1c377bd9e6fc434d71ca52c628963a5e`
- Mailbox: `55852a1e71bb677d68d0663f8d9c3933dfbb6a264418fd948bfa5841c8faf15a`

Artifacts: `out/live-worker-pool-20260909-four-interactive-v4/summary.json`,
the four `*.terminal.log` files, and
`workspace/foreground.duplicate-rejected.json`. The successful run was not
relabeled from an earlier failure. Earlier attempt records remain available:

- Initial directory: harness sent Enter to a screen-reader trust prompt that
  required `y`; it never reached task delivery. The owned process was stopped.
- `-v2/`: mixed outcomes, out-of-order collection, caller kill and duplicate
  rejection passed; the harness then read old attention with plain `task wait`
  immediately after sending approval. The corrected collection path acknowledges
  attention and waits for the next outcome with the same consumer's `wait-any`.
- `-v3/`: worker safely ignored a mid-run duplicate while retaining its claim,
  but the harness incorrectly demanded a new claim and literal execute=false
  log wording. Its terminal log and markers show no repeated execution. The
  final fixture explicitly requests a task-bound JSON audit instead.

This qualifies four simultaneous native interactive workers on this host/build,
not an arbitrary number of native workers or unknown Claude releases. The
32-worker tests are separate simulated mailbox/CLI load tests. No real bench
work, hardware restoration or the coworker's particular host was exercised.

## Findings and boundaries

1. **Session UUID and messaging reference differ.** The initial relay correctly
   refused to guess a target. The implementation now supports public-listing
   cross-checks and an explicit, immutable `--worker-name` mapping.
2. **PID namespaces hide live workers.** A sandboxed `claude agents --json`
   returned `[]` while ListAgents still exposed the worker. A host-side public
   listing confirmed its exact UUID, name, and checkout. `--worker-name` permits
   this verified mapping to travel into the relay. It is routing information,
   not authentication against another process running as the same OS user.
3. **No automatic idle Codex wakeup is implemented in the plugin.** The later
   [isolated wakeup PoC](codex-wakeup-poc.md) now proves a public API route,
   including an attached Codex CLI terminal and controlled server restart.
   That prototype is separate from the qualified worker release here. The initial public
   `codex app-server proxy` probe could not connect because this host had no
   app-server control socket. The [official app-server documentation](https://learn.chatgpt.com/docs/app-server)
   describes client-driven turn starts, but a supported live integration to this
   conversation was not established. No daemon, private inbox/socket mutation,
   or guessed notification bridge was installed. Foreground waiting and later
   inbox pickup are the supported modes.
4. **Claims do not make external effects transactional.** Cooperative workers
   must honor `execute=false`. After a crash, reconcile the actual executor before
   continuing; the mailbox never grants automatic takeover or reruns a bench.
   Notifications replay until acknowledgment, whose bookkeeping is idempotent.
5. **Native session persistence remains host-dependent.** The missing-session
   error has a tested fresh-attach recovery path. This work does not claim to
   repair Claude's persistence implementation or establish why the coworker's
   transcript was unavailable.

## Next action

Review the local changes and choose a release version, then use the normal
plugin cachebuster/install and publication workflow. Before coworker rollout,
verify the worker UUID/name/checkout mapping on that host and run one harmless
`delegate` task while keeping its foreground command alive. Idle push requires
a separately qualified host integration; it is not part of this release candidate.
