# secondopinion

Sealed, verifiable second-opinion exchanges between AI coding agents — today
Codex → Claude Code — with **no human relay**: from Codex, one command publishes
a hash-bound request recorded against the exact checkout, runs a headless
Claude Code responder that never prompts, and returns the validated answer.
Works across repositories, git worktrees and sessions. Ships as a **true Codex
plugin** plus a bash CLI; **nothing is installed in Claude** — the responder
prompt is self-contained and needs only the `claude` CLI on PATH, the exact
mirror of the Claude→Codex plugin, which installs nothing in Codex. (An
optional Claude Code plugin exists for interactive responding; this repo is a
marketplace for both.)

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
headless responder (nothing is installed into Claude itself). Claude Code must
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
  interactively. `--plugin` is a deprecated alias.
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
- `ask --effort low|medium|high|xhigh|max` — validated against the *live*
  `claude --help`; unsupported CLIs are refused, never silently ignored.
  Requested and (when the responder output proves them) realized models are
  recorded in `status`.
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
