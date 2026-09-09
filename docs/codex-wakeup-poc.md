# Idle Codex wakeup proof of concept

This records the historical opt-in prototype, not the production integration.
For the later installed candidate, see [automatic-return validation](automatic-return-validation.md).
Live qualification on 2026-09-09:

| Run | Checks | Scope |
| --- | --- | --- |
| Initial ephemeral thread | 22/22 | Idle/busy delivery and one real interactive Claude worker |
| Saved thread + terminal | 42/42 | CLI queue, visible idle/busy/native wakeup, server restart and same-thread recovery |
| Concurrent notifications | 34/34 | Four simultaneous synthetic results into busy and idle real Codex, all visible in terminal |
| Four real workers + terminal | 42/42 | Four interactive Claude workers finish after their messengers exit; four independent mailbox watchers wake the saved Codex terminal |

Counts are per run and include overlapping setup checks, not a sum of unique tests.

## What actually worked

A real interactive Claude worker received a task through the existing temporary
messenger. The messenger exited while the worker was still executing. Codex's
test conversation was independently confirmed idle through the public API.
After the worker published its durable result, a separate watcher process sent
that result to the same Codex thread. Codex started a new turn without user input,
acknowledged the exact worker result, and remembered a random context token from
its earlier turn. The fixture executed once. The harness acknowledged the mailbox
only after verifying Codex's response, not merely after API acceptance.

The test also delivered a synthetic completion while Codex was demonstrably busy
at a harmless controlled tool gate. The completion was consumed in that existing
turn, with the same turn ID, rather than starting competing work.

The saved-thread extension repeated the real-worker path with a real Codex CLI
terminal attached over the private endpoint. It verified that both `codex queue`
and standalone tool output actually wake the saved conversation and display the
response, without submitting terminal keystrokes. Only terminal-protocol queries
(cursor position/background color) were answered. After stopping the owned server,
public resume on a replacement server preserved the UUID and context; a subsequent
completion appeared automatically in a reopened terminal.

The burst test used four independent public API clients synchronized to deliver
different, randomly generated result tokens. All four were retained and acknowledged
with original conversation context, both from idle and at a controlled busy gate.
Each input appeared once in public result events, and all acknowledgments appeared
in the terminal. The busy test started no competing turns. These were synthetic
completion notifications, not four Claude workers.

Finally, the combined native-pool test started four independently discovered
interactive Claude workers and four temporary messengers. Every messenger exited
while its worker was held at a harmless fixture gate. Codex was confirmed idle
at that point. Releasing all workers let their independent completion reports
arrive naturally; separate watcher processes delivered all four into the same
saved Codex conversation, over two automatic turns. Each exact randomized report
was acknowledged with the earlier context token and displayed in the attached
terminal without human input. All four task/worker bindings matched, all four
fixtures executed once, and all four reports were explicitly acknowledged.

## Mechanism and evidence

The prototype follows the official [Codex app-server protocol](https://learn.chatgpt.com/docs/app-server#start-a-turn):
`turn/start`, empty `input`, and a standalone `toolOutput`. Results remain tool
output rather than masquerading as a new human instruction. The server listens
on a private, mode-0600 Unix socket inside a mode-0700 artifact directory. The
conversations are newly created test threads; no pre-existing user thread was
resumed or messaged. The initial thread was ephemeral; saved test threads are
archived recoverably through the public API after the later tests.
The Codex thread has a read-only sandbox and no approval escalation. Optional
apps/plugins are disabled only for this server invocation; code-mode host remains
enabled for the controlled dynamic-tool gate. Existing configuration is unchanged.
Normal authenticated Codex/Claude runtime files can be updated by their CLIs.

- Codex: `codex-cli 0.153.4`, configured `gpt-6-astra`, low effort.
- Claude Code: `2.1.266`; public discovery verified an interactive peer.
- Codex thread: `01a083ba-fc14-7b61-9ede-3343ba894f5d`.
- Claude worker: `01474856-e9bf-457e-bcb3-65150b7fa9fb`.
- Final evidence: `out/wake-poc-20260909-v7/summary.json`.
- Timestamped public protocol: `coordinator.jsonl`, `completion-bridge.jsonl`.
- Native evidence: worker terminal log, relay exchange, mailbox and fixture files
  under that same artifact directory; watcher stdout contains the accepted turn.
- All owned processes stopped/reaped: server 2436037, worker 2436307,
  requester 2436459, watcher 2437659. No daemon/startup service was installed.
- CLI and mailbox hashes matched before/after and were not changed for this PoC:
  `895ac4fdc8c183ded1aa5c3e86e660ed1c377bd9e6fc434d71ca52c628963a5e` and
  `55852a1e71bb677d68d0663f8d9c3933dfbb6a264418fd948bfa5841c8faf15a`.
- Initial passing harness SHA-256 (before adding optional saved-thread support):
  `4bf35f36bdad55b641482380ee497f6bc76b84bee394e601d41fc4092913c88f`.

Additional evidence:

- Saved-thread run: `out/wake-saved-20260909-v1/summary.json`,
  01:29:45–01:31:52 UTC; 42/42 passed. Test thread
  `01a083c9-0cdd-7a83-a0db-34c2da4ba8db` was archived after cleanup.
- Burst run: `out/wake-burst-20260909-v1/summary.json`,
  01:33:04–01:33:48 UTC; 34/34 passed. Test thread
  `01a083cc-1343-7610-a2ff-a46d6b42cd4f` was archived after cleanup.
- Both runs record source/harness hashes and owned-process exit codes. The saved
  run retains original and reopened terminal logs plus before/after server traces;
  the burst run retains individual sender traces and exact expected/observed tokens.
- All test-owned processes in both runs were stopped/reaped. The production CLI
  and mailbox hashes above remained unchanged.
- Combined four-native-worker run: `out/wake-native-pool-20260909-v1/summary.json`,
  01:36:22–01:38:53 UTC; 42/42 passed. Test thread
  `01a083cf-188c-74f3-939c-af98403f5496` was archived. Its four worker UUIDs, fourteen
  owned-process exit codes, four watcher receipts, exact reports and source hashes
  are recorded in the summary and adjacent private artifacts. All owned processes
  stopped/reaped, and the production hashes remained unchanged.
- Current harness hashes (recorded in the passing summaries):
  base `18fa370d1622a0029d6aa6a3054991c2138fce01c40e80ad67b3a079c19b921f`;
  saved `247c58b949660a67b92de9531705bd646b7cc16ea26c47cd500724b68f320f5f`;
  burst `acc9bd57321d7d23a659e35832df00c2340b64746e7da8c77fb008b62bd0d3f8`;
  native pool `da95864ae58d306f2eaf9f834d757dcae05598bb15d80e37970e32ad2d183b3c`.
- Mailbox unit regressions reran: 51/51 passed in 26.445 seconds. This is a rerun
  of the existing suite, not 51 new cases.

The raw artifact directory is private/ignored and may contain normal account
metadata. Do not publish raw logs without reviewing them.

## Reproduce

Run on the host using authenticated CLIs. The output directory must not exist:

```bash
python3 -B tests/live_codex_wakeup.py --output out/wake-poc-new --native-worker
python3 -B tests/live_codex_wakeup_saved.py --output out/wake-saved-new --native-worker
python3 -B tests/live_codex_wakeup_burst.py --output out/wake-burst-new
python3 -B tests/live_codex_wakeup_pool.py --output out/wake-native-pool-new
```

These consume real model usage, create owned temporary processes, and stop them
in cleanup. The saved-thread script restarts its private server; the burst script
does not start Claude workers. The native-pool script starts four. These scripts are intentionally not part of the
default automated test gate. Python compilation and diff whitespace
checks passed; the previously qualified plugin payload itself is unchanged.

## Boundaries and retained failures

This proves waking a thread managed by the test app-server. It does **not** prove
waking this existing Codex conversation or attaching to every independently launched
terminal/app. Display in a test CLI terminal attached to the private server is now
proven; other apps/extensions and arbitrary standalone sessions are not. OpenAI documents
app-server/WebSocket integration as experimental, not production-supported.

`codex queue` rejected the ephemeral thread explicitly. That is not a failure of
the successful `turn/start.toolOutput` route. The later saved-thread test proved
CLI queue acceptance, automatic generation and visible response on the attached TUI.
Queue messages are user-input messages; the tool-output route retains result semantics.

The watcher is one-shot. Controlled saved-thread server restart/context recovery is
proven; automatic watcher crash/restart recovery, reconnect/retry handling, durable
event deduplication, approval/cancellation boundaries,
target registration and installation lifecycle remain to be engineered/tested for
a release. Existing mailbox durability does not make notification delivery
exactly-once. No latency guarantee follows from this run.

Backups and network settings were left alone throughout the resumed testing,
as requested. All changes remain local and uncommitted; there was no installation,
cache refresh, version bump, release or coworker delivery. The README stays at
61 lines; detailed test evidence belongs here, not in the installation guide.

Earlier attempts remain under `out/wake-poc-20260909-v1` through `v6`:
sandbox runtime writes were blocked; new SQLite homes rebuilt historical indexes
and missed startup deadlines; the raw stdio proxy did not initialize against this
WebSocket listener; ephemeral naming was rejected; disabling code-mode host
prevented the dynamic-tool busy gate. One initial model turn encountered transient
connection retries before succeeding. The final run used the documented Unix
WebSocket handshake, normal runtime index, no ephemeral naming, and code-mode host.
These attempts are not counted as passing end-to-end runs.

Next action, if authorized: turn the one-shot watcher into an opt-in plugin
integration with explicit endpoint/thread registration and durable delivery
reconciliation, then qualify delivery through crashes/retries and permission boundaries.
