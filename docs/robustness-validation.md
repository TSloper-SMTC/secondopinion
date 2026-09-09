# 1.2.0 robustness qualification

Owner: Tim. Date: 2026-09-09. Tim explicitly approved the commit/push after qualification.
Release version **1.2.0** is aligned across the CLI, both manifests, Claude
marketplace and both changelogs. Qualification is complete. Claude Code returned
**APPROVE** in both adversarial reviews and independently reran the full suite.
Publication status and its verified Git receipt are recorded in
[`CURRENT_WORK.md`](../CURRENT_WORK.md). Product/test identity is bound by
`release-1.2.0.sha256`; the qualified archive is `out/secondopinion-1.2.0.tar.gz`.

This audit extends the [initial conversation qualification](conversation-validation.md)
and the existing 1.1.0 workflow coverage. Supported scope is a Codex lead with
existing Claude workers, on this Linux/user-systemd host with Codex 0.153.4 and
Claude Code 2.1.266. It does not establish interchangeable agent roles, cross-host
transport, unlimited capacity, or exactly-once external effects.

## Defects reproduced and corrected

1. Automatic task results could arrive before already queued worker messages;
   a later message/result could also overtake an uncertain earlier message from
   that worker. Notifications now preserve message sequence before results and
   hold that task for reconciliation while other workers continue.
2. Each idle poll loaded all retained message bodies and rewrote every consumed
   notification. Collection now selects only new unread messages, marks newly
   consumed notifications once, and indexes pending work. Explicit history reads
   still retain and validate the complete conversation.
3. SQLite storage exhaustion could trigger its own rollback, which our second
   rollback masked with a misleading error. A failed commit could leave a
   transaction open. Both paths now roll back only an active transaction and
   preserve the original failure. Real SQLite page exhaustion and a reader that
   blocks commit verify recovery and retry without partial messages or claims.
4. Model status guessed the alphabetically first model from aggregate usage,
   which can be a helper model. A real Sonnet request was incorrectly reported
   as Haiku. Status now uses the primary assistant stream, falling back only to
   unambiguous single-model usage. A fresh real request returned and reported
   `claude-sonnet-5` despite aggregate usage also containing Haiku.
5. A repeated full run exposed a pre-existing capability-probe race: `grep -q`
   could close the help pipe while Claude was still writing, and `pipefail`
   then misclassified the resulting SIGPIPE as missing `--safe-mode` support.
   The probe now drains all help output. A delayed large-output producer
   deterministically reproduces the failure and the ordinary suite tests it.

Failing reproducers are retained in `out/robustness-repro-v1.log` and
`out/robustness-repro-v2.log`. These are failures, not qualification passes.
The model-specific failure is retained in `out/robustness-model-repro-v1.log`;
the corrected parity suite passed **168/168** in
`out/robustness-model-fixed-v1.log`.
The intervening full run `out/robustness-regression-v2.log` failed the progress
case because of that capability race. Its captured error and deterministic
reproducer are `out/robustness-progress-failure.txt` and
`out/robustness-help-repro.txt`; it is not counted as a passing full run.

## Coverage and evidence

| Use case | Evidence |
| --- | --- |
| Ordinary request, manual exchange lifecycle, file/checkout integrity, timeout, claim and recovery boundaries | Final suite **1186/1186**, zero failures, `out/robustness-regression-v5-summary.json` and log |
| Follow-up, persisted native session/resume, model/effort, normal and adversarial/base reviews, cancel/attach, opted-in writes and archive/prune | Real Claude lifecycle test, `out/robustness-lifecycle-v3/summary.json`, **23/23** |
| Four workers returning to an idle Codex lead; native identity, single execution and two hard service crashes | `out/robustness-installed-v2/summary.json`, **49/49**; initial run also **49/49** |
| Mixed success/refusal/blocker, independent timeout, duplicate delivery, killed caller, approved continuation and worker reuse | `out/robustness-mixed-pool-v1/summary.json`, **36/36** |
| Two workers, two question/reply rounds, model-issued consumption and replies, service restart and exact results | `out/robustness-conversation-v2/summary.json`, **25/25**, exact final runtime on schema 2 |
| Missing return service automatically falls back from `--async` to foreground question/reply collection | `out/robustness-fallback-v1/summary.json`, **8/8** |
| Requested model/effort and accurate realized primary model despite helper usage | `out/robustness-model-live-v1/summary.json`, real Sonnet request and hash-validated response passed |
| Concurrent traffic, interrupted send, lost/late receipts, ordering, identity, terminal task and acknowledgment isolation | **61** conversation tests, including eight processes posting **1,024** exact messages and an actual sender SIGKILL |
| Storage exhaustion, failed commit, atomic recovery and existing task lifecycle | **55** mailbox tests plus conversation storage test |
| Installation, plugin/skill validation, exported package and version consistency | Actual source/cache comparison and skill validation passed; exported package **126/126** in `out/robustness-package-check-v4.log` |

The final full suite covers 61 conversation, 129 installation, 170 parity,
126 packaging, 565 ordinary-use, 55 mailbox, 46 notification/wire, 13 service
and 21 directory checks. Counts describe assertions/tests, not unique use cases.

`out/robustness-final-conversation-audit.json` verifies the final live runtime
hashes exactly, schema 2, archived test thread, reaped owned processes and zero
enabled test routes. Earlier mixed/four-worker/lifecycle evidence retains its
original source identity: subsequent changes were the reviewed model/probe fixes,
schema migration, status counts and clearer error text. Those paths are covered
by the final suite, the actual legacy migration test, the final live conversation
and both real Claude review calls. Earlier source-correspondence receipts are
point-in-time records, not assertions that every older run used final bytes.

The first two lifecycle attempts exposed test-harness mistakes: the expected
parse field was `parse_ok`, and an in-flight request must be discovered through
`list --pending --json` because response stdout is produced only on completion.
Those failed run records are retained. The corrected harness also uses the
documented plain `jobs` interface; it does not invent a `jobs --json` option.

## Reproduction

```bash
bash tests/run.sh
python3 -B tests/live_request_lifecycle.py --output out/lifecycle-UNIQUE
python3 -B tests/live_worker_pool.py --output out/mixed-workers-UNIQUE
python3 -B tests/live_conversation.py --output out/conversation-UNIQUE
python3 -B tests/live_conversation_fallback.py --async-fallback --output out/fallback-UNIQUE
python3 -B tests/live_installed_workers.py --output out/installed-workers-UNIQUE
```

The installed-worker and conversation tests must run separately because they
restart the plugin bridge and refuse to disturb unrelated enabled routes. They
preserve the shared Codex server. Live fixtures create only owned sessions,
checkouts and stores; cleanup receipts and failures remain in their output dirs.
Retention tests prune only their isolated fixture store. Detailed model requests
use private temporary files, removed by the harness.

## Adversarial review disposition

Claude Code (Opus) approved the initial review in exchange
`2026-09-09T185941Z-adversarial-review`, then approved the final follow-up in
`2026-09-09T191753Z-adversarial-review`. Full private/local reports are retained
in `out/robustness-claude-review-v1.md` and `out/robustness-claude-review-v2.md`,
with parsed verdicts beside them. It independently ran the deterministic suite
with zero failures in each review and reported no remaining release blocker.

| Finding | Disposition |
| --- | --- |
| Raw lock-contention error | Actionable wait/inspect/same-ID guidance, with a regression; the lock precedes any ambiguous retry |
| Unsafe fallback model name | One printable/non-synthetic predicate covers primary and aggregate models; injected metadata/control characters are rejected |
| Old readers silently miss questions | Atomic schema-2 marker; actual 1.1.0 reader refusal and preserved task/claim data verified in `out/robustness-schema-upgrade/summary.json` |
| Pending messages hidden in status | Per-recipient unread counts in status/inbox; no consumption or nested transaction |
| Discussion can pass an uncertain result | Intentional and tested: terminal discussion can aid reconciliation while the unchanged result remains readable and no execution is granted |

The first unread-count implementation caused a nested transaction in inbox;
`out/robustness-review-fixes-mailbox.log` and the v4 full-run package failure retain
that failure. It was corrected and a dedicated terminal-inbox/wait-any regression
was added. Final v5 and both independently reviewed final paths pass.

Final informational notes were dispositioned without changing approved runtime:
eager migration is intentional (one atomic upgrade point; even a query/service
startup can migrate), the shared install guide now names 1.2.0 and the coordinated
update/no-downgrade rule, and the worker guide explains exit-1 contention versus
stored ambiguity. Model sanitation remains centralized at parsing: the independent
review verified its controls; duplicating the same validation at the write site
is an optional defense, not a remaining defect.

Final documentation/guide clarifications were made after the review; runtime and
test bytes remain those reviewed. The final archive includes these handoff docs,
source and tests, excluding private stores, raw model logs, caches and Git history.
No engineering gate remains for the qualified setup. Publication changes only
documentation of approval, installation and the Git receipt; the qualified archive
retains its pre-publication handoff text and unchanged product/test bytes.
See `CURRENT_WORK.md` for the current status and next action.
