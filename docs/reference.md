# Technical reference

Detailed installation options, CLI commands, runtime behavior, and integrity
guarantees. For installation and everyday usage, see the [README](../README.md).

```
~/.secondopinion/
  exchanges/<Exchange-ID>/prompt.md     requester writes; frozen (SHA-256) by `publish`
  exchanges/<Exchange-ID>/meta          tool-owned state, authoritative
  exchanges/<Exchange-ID>/claim/        atomic claim (token + owner)
  exchanges/<Exchange-ID>/response.md   responder writes; write-once, hash-bound
  archive/<Exchange-ID>/                after the requester consumes it
  responder-logs/<Exchange-ID>.<Run-ID>.log  immutable output of one headless run
```

States: `draft → published → claimed → answered → archived`.

## Delegate to an existing Claude worker

The worker mailbox supports a longer handoff: an installed Claude worker hook
or a temporary Claude relay notifies the worker, which publishes progress and its
final report directly to the durable mailbox. The hook needs no relay inference.

```bash
secondopinion workers  # optional public name/UUID/checkout listing
secondopinion delegate --async --id review-123 --worker-name EXACT_NAME --file request.md --timeout 900
secondopinion task result review-123
secondopinion task ack review-123 --consumer YOUR_CODEX_THREAD_ID --revision N
```

With `--async` and `notification=automatic`, exit 0 means tracking is active;
`delivery` distinguishes a queued hook notice, native acceptance and an independent worker claim.
Worker results arrive separately in this Codex conversation. No user registration
or watcher command is required. Otherwise keep `delegate` running: foreground
exit 0 requires a worker report. Exit 3 reports refusal, failure,
or a blocker; exit 124 means the foreground wait expired without stopping the worker. Reuse
the task ID to avoid duplicate execution. `task wait ID` resumes waiting, and
`task inbox --consumer ID` finds unconsumed results after a Codex restart.

Tasks, immutable terminal reports, progress history, and consumption records
live in `~/.secondopinion/tasks.sqlite3`, separately from sealed review exchanges
and their archive retention. The Python standard library supplies SQLite; no
new package is needed. Use a local filesystem for the store (not a shared NFS
database), the same OS user, and cooperating workers. No task pruning is automatic.
Version 1.2.0 upgrades the task database marker to schema 2, preserving existing
tasks, reports and acknowledgments. Older 1.1.0 clients then refuse the store
instead of silently overlooking conversation messages. Update every participating
installation together and restart the plugin service with the installer; older
already-running processes must also be restarted. Do not downgrade a migrated
store to a 1.1.0 client.
The migration occurs on the first mailbox open, including `task status` or the
installed return service's startup. This deliberate eager migration provides
one atomic upgrade point; mixing 1.1.0 clients with schema-2 clients is not supported.
Version 1.2.1 keeps schema 2 and requires no further migration from 1.2.0.

Ongoing conversation uses `task message TASK --id MESSAGE_ID --session SESSION
--file message.md` and `--reply-to MESSAGE_ID` for answers. Messages retain their
own order, content hashes and recipient acknowledgments, independently of task
revisions. Lead replies use the same verified worker route; worker messages wake
the registered lead as `secondopinion_message`. Foreground collection returns
exit 4 with a `messages` list when a conversation needs attention. See the
[conversation guide](../plugins/secondopinion/skills/secondopinion-request/references/delegated-workers.md#ongoing-conversation)
for consumption, reply and recovery commands.
`task status TASK` includes `unread_messages.requester` and
`unread_messages.worker` counts. Reading status never consumes those messages.

Lead relay sends are serialized per task. An earlier queued or uncertain relay
must be delivered or reconciled before a newer relay send. A worker hook can
instead discover the retained unread messages in sequence without resending
their contents or recording a native receipt. Independent workers can receive
messages concurrently.
Worker notifications preserve message order before queued task results. An
uncertain worker-message notification holds later notifications from that task
for reconciliation; other workers continue independently.
Discussion posted after task completion remains deliverable while an earlier
outcome notification is uncertain. The report remains available through
`task result`; such discussion cannot reopen the task or grant another execution.

`--worker-name` automatically resolves a unique name to its exact UUID and checkout.
The installed service publishes only Claude's public worker listing, refreshed
every few seconds; listings older than ten seconds or from a stopped service are
not trusted. This supports PID-namespaced callers without changing their sandbox.
An explicit `--worker UUID` remains available. The relay also checks its native
listing; no guessed peers, private inbox writes or automatic replacement workers.
Names are routing information, not authentication against another same-user process.

This mode requires a reachable existing worker. For notifications without a relay
model call, install with `install.sh --claude` and restart/resume workers; see the
[1.2.1 repair and activation notes](delivery-relay-1.2.1.md). Otherwise relay delivery
requires native `ListAgents`/`SendMessage` support. The installer configures automatic idle return for ordinary local
Codex CLI conversations on Linux with user systemd. Closed/unloaded conversations
are not resumed automatically. Unsupported clients use foreground waiting;
stored results remain available for later pickup. No notification overrides
approval or sandbox settings, and consumption requires an explicit acknowledgment.
Uninstall removes the plugin bridge but retains the shared Codex server to avoid
interrupting other conversations. See the [worker workflow](../plugins/secondopinion/skills/secondopinion-request/references/delegated-workers.md)
for recovery, authority boundaries, and acknowledgment semantics.

## How it works, from Codex

You say, in a Codex session in some checkout: *"get a second opinion from
Claude on the retry logic in arq.c"*. The `secondopinion-request` skill runs

```bash
secondopinion ask --topic "arq retry logic" --file request.md --timeout 900
```

which (1) creates the exchange — the header records `Repo`, `Git-Common-Dir`,
`Branch`, `Commit`, `Dirty-State` and Codex's thread id — fills the `Task:`
section and publishes it (prompt frozen by SHA-256); (2) starts a headless
Claude Code in that checkout:

```
claude -p "<the full secondopinion-respond workflow, inlined>\n…\nExchange-ID: <ID>" \
       --safe-mode \
       --permission-mode dontAsk \
       --allowedTools Bash,Read,Grep,Glob,Write --disallowedTools Edit,NotebookEdit,WebFetch,WebSearch \
       --no-session-persistence --output-format stream-json --verbose
```

The prompt is **self-contained**: `ask` inlines the respond instructions shipped
next to the CLI, so no skill or plugin has to exist in Claude — only a current
`claude` binary with `--safe-mode`. Safe mode suppresses user hooks, plugins,
auto-memory, session-environment setup and automatic startup-file discovery;
the sealed prompt explicitly tells Claude to read the target repository's
policy files itself. `dontAsk` is the analogue of the Codex plugin's
`approvalPolicy: never`: anything not on the allowlist is denied instead of
asked. Claude follows the same `secondopinion-respond` workflow a human session
would: verifies the checkout matches the header, reads that repository's
`AGENTS.md`/`CLAUDE.md`, claims the exchange (atomic, one-use token), does the
work, and publishes a write-once, hash-bound response from a temp file outside
the repository. While Claude works, the foreground supervisor prints only a
quiet status line every 60 seconds by default: `Claude is still working — 3m
elapsed; waiting for results.` Detailed event count, activity age, and last
tool/action remain recorded in `status`; opt into those live diagnostics with
`--verbose-progress` or `SECONDOPINION_PROGRESS_MODE=verbose`. Hidden reasoning
is never exposed. (3) `ask` waits, validates
(Exchange-ID, prompt hash, response hash) and prints the answer. Exit `0`
answered · `124` timeout · `1` error. `--timeout` is the primary deadline, not
an activity-based kill: the responder always receives an unconditional grace
window (`--grace`, default equal to the primary timeout). One GNU `timeout`
process is armed at launch: `timeout + grace` is the work deadline and sends
TERM, then a fixed 10-second bounded shutdown window ends in SIGKILL if needed.
`--grace 0` removes only the extra work window. No event/activity heuristic can
deny grace. Once termination begins, progress says `terminating`, never `still
working`. If a foreground launch reaches the work deadline,
if it fails after claiming, only that exact launch's run-bound claim is released
and the exchange returns to `published`, so `secondopinion ask --attach <ID>`
can retry immediately. A foreign or uncorrelated claim is never released.
`--write` runs the responder with `acceptEdits` for tasks that may edit files.

Foreground is the only supported execution mode. `--background` is rejected
before an exchange is created because a detached process cannot reliably
outlive Codex's PID-namespaced command sandbox. Keep the `ask` command/session
alive until it returns. Its quiet supervisor publishes a heartbeat so another
session can inspect `status` or safely refuse a duplicate `ask --attach`. A
later `status`, `list`, `wait`, `jobs`, or `result` lazily releases
only an expired exact-run claim: immediately after a definitely observed exit,
or only after the TERM→SIGKILL bound plus a small reap margin when liveness is
still reported or hidden by a PID namespace. Sandbox teardown therefore does
not leave an exchange claimed forever and a live run is never reaped during
shutdown. Every attach receives a fresh run ID and log path, so recovery cannot
truncate an incumbent run's diagnostics. If an explicit attach replaces a
stale responder hidden in a foreign PID namespace, its prior run ID, pid,
namespace, heartbeat and log remain recorded under `previous_responder_*` with
`attach_arbitration=stale-foreign-replacement`; claim-token arbitration still
allows only one response.
PID-based cancellation is refused across PID namespaces to avoid signalling an
unrelated process. Set `SECONDOPINION_PROGRESS_SECS` to a positive integer to
change the reporting interval (default 60).

For Codex-driven requests, detailed prompt text belongs in a private temporary
request file passed with `--file`; do not place it inline in the long-running
terminal command. Codex can redisplay that command while waiting, which would
repeat the full prompt as a large UI block. `--topic` is restricted to a single
line of at most 120 characters, and `--task` to a single line of at most 240
characters. `review --task` has the same boundary
and `review --file` accepts detailed focus text. This is enforced by the CLI as well as
the bundled request skill, so it carries into new sessions and other machines
when the plugin is installed there.

There is no turn cap by default. The work deadline plus bounded termination is
the normal bound because tool-turn counts do not reliably measure useful progress
and can cut Claude off immediately before it publishes. `--max-turns N` (or
`SECONDOPINION_MAX_TURNS`) remains available as an explicit cost/work-budget
guard when you actually want one. The default grace equals the primary timeout,
so it can double a caller's previous wall-clock/cost ceiling; this is the
intentional reliability tradeoff that protects a healthy but temporarily silent
run. Set `--grace` and/or `--max-turns` explicitly when cost is the priority.

Codex reaches Claude from inside its own sandbox only because the installer sets
`[sandbox_workspace_write] network_access = true` in `~/.codex/config.toml`
(and adds the store to `writable_roots`). That is a deliberate, visible loosening
of the Codex sandbox for all workspace-write commands; an explicit
`network_access = false` is reported and never flipped.

## Install

```bash
git clone https://github.com/TSloper-SMTC/secondopinion ~/tools/secondopinion
~/tools/secondopinion/plugins/secondopinion/scripts/install.sh            # default: the Codex plugin; nothing in Claude
~/tools/secondopinion/plugins/secondopinion/scripts/install.sh --claude   # + the Claude Code plugin (optional)
~/tools/secondopinion/plugins/secondopinion/scripts/install.sh --skills   # symlink form instead of plugins
~/tools/secondopinion/plugins/secondopinion/scripts/install.sh --check    # verify; exit 0 = installed
~/tools/secondopinion/plugins/secondopinion/scripts/install.sh --uninstall # COMPLETE removal: both sides, config edits, the store and all state
```

Prerequisites: bash, GNU coreutils/sed/grep/awk/flock, git, python3 (installer
and `ask`), the `codex` CLI (default form), and the `claude` CLI on PATH for the
headless responder (the default install adds nothing to Claude itself). Claude Code must
advertise `--safe-mode`; `ask` checks this before creating an exchange.

Every form creates `~/.local/bin/secondopinion` (the checkout is the install —
everything else is a symlink into it), the store (0700), the Codex sandbox
settings above, and a deprecated `agent-mailbox` alias for scripts from the tool's
pre-release life as agent-mailbox. Per
side at most one form is active, as `--check` verifies.

- **Default** — the true Codex plugin: `codex plugin marketplace add
  ~/tools/secondopinion && codex plugin add secondopinion@secondopinion`
  (driven by `install.sh`). The Claude side is left EMPTY — any earlier
  secondopinion skill symlink or plugin there is retired — because
  `secondopinion ask` carries its instructions inline. Re-running `install.sh`
  repoints a stale marketplace, updates/reinstalls to the checkout's version,
  re-enables a disabled plugin, and fails — before touching anything — if
  `codex`/`python3` are missing, a plugin registry cannot be inspected, or the
  store path cannot be written into TOML.
- **`--claude`** — additionally installs the Claude Code plugin
  (`claude plugin marketplace add` + `claude plugin install`), so a human
  Claude session can run `/secondopinion:secondopinion-respond [ID]`
  interactively and receive task/message reminders through its mailbox hook.
  Restart/resume workers after installation and retain `--claude` on updates.
  `--plugin` is a deprecated alias.
- **`--skills`** — symlink form for setups without plugin support:
  `~/.codex/skills/secondopinion-request` (and, with `--claude`,
  `~/.claude/skills/secondopinion-respond`, invoked as
  `/secondopinion-respond [ID]`); the plugins are removed.

`install.sh --check` never modifies HOME (it does not start `claude`/`codex` on
a pristine HOME). The Codex side must be installed in exactly one current form;
the Claude side may be absent, but if anything of ours is present it must be
current and unique — stale, disabled, wrong-version, duplicate (a current
plugin plus a skill symlink/dir) or uninspectable state fails on either side.
It also requires the store as a real member of
`[sandbox_workspace_write].writable_roots` (comments ignored, multiline arrays
understood) plus `network_access = true`.
Replaced files/dirs are moved without clobbering to
`$HOME/.local/state/secondopinion/backups/` (`SECONDOPINION_BACKUP_DIR`).
Upgrading from a pre-release agent-mailbox install: `~/.agent-mailbox` is migrated once (old path left as a
symlink, and REMOVED from `writable_roots` — Codex's bubblewrap sandbox cannot
build with a symlinked writable root; the real store entry covers it), old
skill links retired, `AGENT_MAILBOX_*` variables honoured with a warning.

## Repository layout (standard plugin/marketplace shape)

```
.claude-plugin/marketplace.json           Claude Code marketplace (source ./plugins/secondopinion)
.agents/plugins/marketplace.json          Codex marketplace (same plugin path)
plugins/secondopinion/                    the plugin
  .claude-plugin/plugin.json  .codex-plugin/plugin.json
  skills/secondopinion-request/SKILL.md   Codex side: runs `secondopinion ask`
  skills/secondopinion-respond/SKILL.md   Claude side: find/claim/answer/publish (also the headless runner)
  bin/secondopinion                       the CLI (plugin executables dir)
  scripts/install.sh                      installer
  LICENSE  CHANGELOG.md
tests/                                    bash suites (run: tests/run.sh)
```

Both official validators pass: `claude plugin validate --strict` (plugin +
marketplace) and Codex's `plugin-creator/scripts/validate_plugin.py`.

## Beyond ask: jobs, result, cancel, review, follow-up, prune

- `ask` is foreground-only; `--background` is rejected before creating an
  exchange. `ask --attach <ID>` re-launches a responder for an existing
  published exchange after an interrupted, failed, or timed-out foreground run.
- `secondopinion jobs` — repository-scoped table (id, state, age, responder
  liveness). `secondopinion result <ID>` prints the validated answer or an
  honest status + responder log path. `secondopinion cancel <ID>` stops a
  foreground responder from another session — it verifies the recorded pid *and* process start time
  (no PID-reuse kills), never demotes an answered exchange, and leaves the
  exchange published for another responder.
- `secondopinion review [--adversarial] [--base REF]` — dedicated read-only
  review of the working tree (or `REF...HEAD`) with a structured JSON contract;
  `--adversarial` challenges design choices and assumptions, not just defects.
  `secondopinion review-result <ID>` parses the fenced JSON verdict/findings
  (exit 3 with the full raw response preserved when parsing fails — a
  schema-valid response is still not automatically correct).
- `ask --follow-up <ID>` — a NEW exchange linked to its parent
  (`Parent-Exchange:` header), embedding the hash-validated parent prompt and
  response; published exchanges are never mutated. `ask --persist` opts into a
  stored Claude session id so `ask --resume <ID>` can continue that native
  session later; the default stays `--no-session-persistence`.
- `ask --model sonnet` or `review --model opus` selects the responder model;
  full model IDs supported by the installed Claude CLI can also be passed.
  Existing delegated workers retain their own session's model configuration.
- `ask --effort low|medium|high|xhigh|max` — validated against the *live*
  `claude --help`; unsupported CLIs are refused, never silently ignored.
  Requested and (when the responder output proves them) realized models are
  recorded in `status`. The realized model is the last observed primary
  responder model, or the sole usage model when no primary stream is available.
  Aggregate usage may contain helper models; ambiguous identity is `unproven`.
- `secondopinion prune` — bounded retention over `archive/` only, **per
  repository** (git common dir; separate non-git bucket; default keep newest
  50, `SECONDOPINION_RETAIN`/`--retain`). Dry-run by default with exact
  targets, rules and bytes; `--apply` holds each exchange's lock through a
  tombstone-first removal (IDs are never reused; an interrupted prune completes
  on the next run; only verified removals are counted). Drafts, pending,
  claimed and answered-but-unconsumed exchanges are never candidates. By
  default nothing prunes automatically — when a repository's bucket goes over
  the bound, `archive` and `jobs` print a one-line note on stderr pointing at
  `prune`. Opt in to auto-prune with `SECONDOPINION_AUTO_PRUNE=1` (or per call:
  `archive --prune`): an archive that lands in an over-bound bucket then prunes
  **that repository's bucket only**, fail-open (a prune failure never fails the
  archive), reporting `auto_prune=ok removed=N` (or `auto_prune=failed`) as a
  parseable stdout key. The bucket-scoped run skips the store-wide crash-litter
  GC and repairs, which stay with manual `prune --apply`.

## Manual flow (any two sessions, no headless responder)

Requester (Codex, any checkout):
```bash
secondopinion new --topic "h1 review"      # -> exchange_id, prompt_path (records Repo, Git-Common-Dir, Branch, Commit, CODEX_THREAD_ID)
$EDITOR <prompt_path>                       # replace the Task: section
secondopinion publish <ID>                  # freeze; now visible as pending
secondopinion wait <ID> --timeout 600 &     # or poll `status <ID>`; exit 0 answered / 124 timeout / 2 archived / 1 error
secondopinion read-response <ID>            # validated (ID + prompt hash + response hash)
secondopinion archive <ID>
```

Responder (Claude Code, `/secondopinion-respond [ID]`, any checkout of that repo):
```bash
secondopinion list --pending --here         # exchanges for this repo (matched by git common dir → all worktrees)
secondopinion show <ID>                     # read first: verify Repo/Branch/Commit, read that repo's AGENTS.md/CLAUDE.md
secondopinion claim <ID> --owner claude:...  # claim immediately before substantive work -> claim_token
# ... do the task in the exact Repo path from the header, per that repo's policy ...
tmp="$(mktemp)"; chmod 600 "$tmp"           # write the response OUTSIDE the target repository
secondopinion respond <ID> --token <claim_token> --file "$tmp" && rm -f "$tmp"   # write-once; a failed respond keeps the file for retry
```

## Guarantees

- No shared "pending" slot: creators never clobber each other (atomic `mkdir`
  reservation, IDs stay reserved across `archive/`).
- The responder never sees a half-written prompt (`draft` is invisible; `publish`
  freezes the hash; a later edit makes the exchange non-pending and unclaimable).
  `publish` refuses a prompt whose `Task:` placeholder is still untouched.
- Every header/meta value is validated before an exchange is reserved: explicit
  options, the derived repository path/branch/commit and `CODEX_THREAD_ID` must
  be free of newlines and control characters. A response's `Responder:` value
  must be nonempty and control-free.
- Every command that addresses an exchange accepts exactly one exchange ID.
- Prompt and response headers end at the first blank line (or EOF); every line in
  that block is byte-validated and header values are taken only from it. Header
  records 1–64 are accepted; record 65 is refused whether the block ends with a
  blank line, EOF, or an unterminated final line. CRLF and TAB are allowed; any
  other control byte (embedded CR, NUL, ESC…) is refused (byte-level, C locale;
  UTF-8 text is fine). A rejected candidate changes nothing (state stays
  `draft`/`claimed`, status `n/a`); a stored artifact that later fails validation
  reports `prompt_ok`/`response_ok=no`, and re-running `publish` on such a prompt
  is an error.
- Two responders can't both answer (atomic claim + token; `respond` is
  write-once via `link(2)`); stale claims can be taken over after
  `SECONDOPINION_STALE_CLAIM_SECS` (default 1800) with `--takeover`. A
  foreground `ask` reserves its run before launching Claude, so an unrelated
  manual responder cannot steal the exchange during startup or execution.
  `status` reports that short reservation as `launching`; if no responder PID
  appears within five seconds it becomes `exited`, allowing normal recovery.
- `show` emits a draft directly, but emits a published prompt only from a
  snapshot matching its recorded hash; tampered published prompts are refused
  without exposing their contents.
- `read-response`/`wait`/`ask` succeed only when Exchange-ID, prompt hash, and
  response hash all validate — never by mtime.
- Strict ID grammar (no path traversal). `list` does not follow symlinked
  exchange directories or metadata; every command that accesses an exchange
  refuses a symlinked exchange directory, `.lock`, `meta`, `claim/`, `prompt.md`
  or `response.md`; `umask 077`; `wait`/`ask` always have a finite timeout.
- Interrupted operations are retry-safe: an orphan `claim/` does not block a
  fresh claim; a valid linked-but-unfinalized `response.md` rolls forward on the
  next `respond` (an invalid one is refused for manual inspection: while the
  exchange is still `claimed` and `meta` holds no `response_sha256`, inspect and
  remove `<exchange_dir>/response.md`, then re-run `respond`); an interrupted
  `archive` completes (or restores state) on retry. `respond` snapshots the
  candidate file before validating it.
- Forced timeout reports only the bounded deadline result; Bash's internal
  asynchronous-job `Killed (...)` notification is suppressed.
- Responder process exit and answer completion are separate metadata: even an
  exit code 0 is explicitly `no-valid-answer` unless a hash-validated response
  was published.

## Threat model

The store is private to one user (`0700`/`0600`). Integrity checks (Exchange-ID,
prompt SHA-256, response SHA-256, write-once response, one-use claim tokens)
protect against mistakes and races between cooperating agents and sessions.
They are NOT a defence against a process running as the same UID that edits
`meta` or reads claim tokens directly. The headless responder has no filesystem
sandbox of its own: read-only behaviour is enforced by the tool allowlist
(`Edit`/`NotebookEdit` disallowed, `dontAsk`) and by the skill/AGENTS.md
instructions, not by the kernel — the same trust you already extend to the two
agents on your machine.

## Environment

`SECONDOPINION_DIR` (store), `SECONDOPINION_OWNER` (default claim owner),
`SECONDOPINION_STALE_CLAIM_SECS` (non-negative decimal seconds ≤ 4294967295,
leading zeros allowed, same rule as `wait --timeout`),
`SECONDOPINION_LOCK_WAIT_SECS` (default 30: a command that cannot acquire a held
exchange lock within this many seconds fails with `exchange busy` instead of
waiting forever), `SECONDOPINION_BACKUP_DIR`
(installer backups), `SECONDOPINION_CLAUDE` (responder binary, default `claude`),
`SECONDOPINION_CLAUDE_ARGS` (extra responder flags), `SECONDOPINION_MAX_TURNS`
(optional explicit cost/work cap; unset by default), `SECONDOPINION_ASK_TIMEOUT`
(primary deadline, default 1800), `SECONDOPINION_ASK_GRACE` (unconditional
grace, default equal to the primary timeout), `SECONDOPINION_PROGRESS_SECS`
(default 60), `SECONDOPINION_PROGRESS_MODE` (`quiet` by default or `verbose`),
`SECONDOPINION_AUTO_PRUNE` (nonempty and not `0`/`false`/`no`: `archive`
auto-prunes its own repository bucket, see prune above). Legacy `AGENT_MAILBOX_*`
names are honoured with a deprecation warning.

## Tests

```bash
tests/run.sh
```

For the native worker-hook qualification with a local deterministic API fixture:

```bash
python3 -B tests/native_delivery_hook.py --output out/native-hook-acceptance
python3 -B tests/native_interactive_delivery.py --output out/interactive-hook-acceptance
```

Use new output directories. These run isolated Claude sessions against a local
API fixture, including an injected 503. The interactive test exercises actual
worker discovery, delegation, Bash tool execution, task retries and follow-up
messages. It qualifies runtime integration, not real-model interpretation or
provider availability. See the [1.2.1 validation record](delivery-relay-1.2.1.md).

For the optional end-to-end existing-worker canary, run on the host from the
repository root, using a new output directory for each run:

```bash
python3 -B tests/live_delegation.py --output out/live-delegation-acceptance
```

For four existing **interactive** workers, including mixed outcomes and
out-of-order collection, run the separate pool canary:

```bash
python3 -B tests/live_worker_pool.py --output out/live-worker-pool-acceptance
```

This starts four uniquely named sessions in owned test terminals, exercises the
temporary messenger and durable mailbox, then stops the owned sessions. It uses
real Claude requests. Both output paths must be new directories; artifacts stay
under them. For a manual test with your own named sessions, follow
[several existing workers](../plugins/secondopinion/skills/secondopinion-request/references/delegated-workers.md#several-existing-workers).

The background canary uses real Claude requests and creates two isolated native background
workers, then stops them. It checks delayed completion after relay exit,
pickup by a new waiter, independent worker results, stop/respawn recovery,
duplicate delivery, and acknowledgment. It touches no hardware. Requests,
fixture effects, logs, and `summary.json` stay in the selected output directory.
Automatic wakeup of an idle Codex conversation is not an acceptance claim of
this canary. See the [validation record](worker-delegation-validation.md).

For current installed-service and user-facing automatic-return qualification:

```bash
python3 -B tests/live_installed_workers.py --output out/installed-workers-acceptance
python3 -B tests/live_natural_worker.py --output out/natural-worker-acceptance
```

These require the installed services. They create only their own test workers and
saved Codex conversations, use real model requests, retain audit records, disable
their routes, archive their threads and reap their processes. The installed pool
test deliberately crashes only the plugin return service and verifies systemd
recovery; it refuses that test if unrelated enabled routes exist. The natural test
asks a real sandboxed Codex to discover a worker by name, delegate through the
installed skill, yield, then consume and acknowledge the result without controller
assistance. Evidence and limits: [automatic-return validation](automatic-return-validation.md).
