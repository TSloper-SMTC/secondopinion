# Changelog

## 1.0.1 — 2026-08-20

Reliability hardening from an exhaustive live + adversarial test campaign
(all defects reproduced first; every fix carries a regression test — suite
grows 309→350).

- **No more availability crashes on damaged meta.** An exchange whose
  `created_epoch`/`claimed_epoch` is empty (crash-torn or hand-edited meta)
  no longer aborts `list`/`jobs` mid-output (rows after it were silently
  dropped with exit 0) or crashes `claim`/`status` with a raw bash arithmetic
  error; it lists with age `-`, and takeover on an epoch-less claim fails safe
  (age 0). `status` on a meta-less exchange directory (a crash-orphaned `new`)
  reports a clean error naming the cleanup instead of a raw `cat` failure.
- **Lost-token outage closed.** A responder that died after publishing
  `response.md` but before finalizing meta used to strand the exchange in
  `claimed` for `SECONDOPINION_STALE_CLAIM_SECS` (default 30 min) until a
  takeover re-ran `respond`. `wait` and `result` now roll a valid on-disk
  response forward under the exchange lock (write-once + hash validation make
  this safe); an invalid response is never finalized. Likewise, a takeover
  that crashed between removing the old claim and recording the new one left
  a claim nothing could ever answer — `claim` now treats state=claimed with
  no `claim/` as orphaned and re-claims immediately.
- **Locks time out.** A wedged holder used to hang every mutator on that
  exchange silently and forever; `lock()` now fails with `exchange busy`
  after `SECONDOPINION_LOCK_WAIT_SECS` (default 30).
- **Prune removal is rename-first.** `flock` is per-inode and `lock()` opens
  with O_CREAT, so a concurrent locker could recreate `.lock` inside a
  directory mid-`rm -rf` and acquire a lock the pruner did not hold
  (found by an adversarial self-review; mechanism demonstrated live).
  `prune --apply` now renames the target to `archive/.prune-trash.*` under
  the held lock before deleting, and sweeps stale trash on the next apply.
- **`ask --attach` refuses a live responder.** Attaching while the recorded
  background responder is still running would truncate its log mid-write and
  orphan it from `cancel`; it now fails with a `cancel` hint.
- **Timeout diagnostics.** A foreground `ask` timeout now appends a
  `killed by ask --timeout` line to the responder log (previously empty —
  headless `claude -p` buffers everything until completion) and the retry
  hints name `ask --attach` (the actual recovery) instead of only `wait`.
- `meta_set` fsyncs the store's authoritative file after rename (best-effort,
  same discipline as tombstones; untestable in the suite — power-loss only).

## 1.0.0 — 2026-08-19

First public release. secondopinion gives one AI coding agent a sealed,
verifiable second opinion from another — today Codex → Claude Code — with no
human relay and nothing installed on the responding side.

- `secondopinion ask`: one command creates and publishes the exchange, runs a
  headless Claude Code responder in the calling checkout, waits, validates and
  prints the answer (`--background`, `--timeout`, `--model`, `--json`). The
  responder prompt is **self-contained** — the full respond workflow travels
  inline plus `--permission-mode dontAsk` and a tool allowlist (`--write` =
  `acceptEdits`) — so nothing has to be installed in Claude, only the `claude`
  CLI on PATH: the mirror of the Claude→Codex plugin, which installs nothing
  in Codex.
- `scripts/install.sh` default is the **true Codex plugin**
  (`codex plugin marketplace add` + `codex plugin add secondopinion@secondopinion`)
  and leaves the Claude side empty (removing any earlier secondopinion
  skill/plugin there). `--claude` opts into the Claude Code plugin for
  interactive responding; `--skills` is the symlink form for setups without
  plugin support; `--plugin` is a deprecated alias for `--claude`. `--check`
  requires the Codex side in exactly one current form and accepts an absent
  Claude side.
- Standard plugin layout: `skills/<name>/SKILL.md`, `bin/`, `scripts/`,
  `LICENSE`, `CHANGELOG.md`; both manifests use the default `skills/` scan.
- Compatibility: `agent-mailbox` remains a deprecated alias, `AGENT_MAILBOX_*`
  variables are honoured with a warning, `~/.agent-mailbox` is migrated once by
  `scripts/install.sh` (old path left as a symlink). The legacy path is removed
  from `[sandbox_workspace_write].writable_roots`: Codex's bubblewrap sandbox
  fails fatally on a symlinked writable root ("cannot enforce sandbox read-only
  path …/.git because it crosses writable symlink"); the real store entry covers
  accesses through the symlink.
- `scripts/install.sh` sets `[sandbox_workspace_write] network_access = true`
  in `~/.codex/config.toml` (needed for Codex-run commands to reach Claude);
  an explicit `false` is reported, never flipped.
- Env vars: `SECONDOPINION_DIR`, `SECONDOPINION_OWNER`,
  `SECONDOPINION_STALE_CLAIM_SECS`, `SECONDOPINION_BACKUP_DIR`,
  `SECONDOPINION_CLAUDE`, `SECONDOPINION_CLAUDE_ARGS`,
  `SECONDOPINION_MAX_TURNS`, `SECONDOPINION_ASK_TIMEOUT`.
- Operational parity with the Claude→Codex companion plugin: `jobs`, `result`,
  `cancel` (verified pid + start time, race-safe with answer publication),
  `review`/`review-result` (read-only, adversarial profile, structured JSON
  with an honest parse-failure path), `ask --follow-up` (immutable linked
  exchanges), opt-in `--persist`/`--resume` native sessions, validated
  `--effort`, requested/realized model recording, and bounded per-repository
  archive retention with a tombstoned, dry-run-first `prune` that holds each
  exchange's lock through removal, plus a stderr retention notice from
  `archive`/`jobs` when a bucket goes over its bound. `ask --background`
  handshakes startup (nonzero `responder=startup-failed`), warns inside
  PID-namespaced sandboxes whose teardown kills detached responders, and
  `ask --attach ID` re-launches a responder for an existing published
  exchange; `ask`/`review --max-turns` sizes the responder turn budget. The
  CLI's final line pairs `main \"$@\"; exit` so a running invocation never
  re-reads its own script file — an in-place update of the dev tree under a
  blocked `ask` previously got parsed as shell input after the response
  (exit 2, \"syntax error near unexpected token\").
- Release hardening (final Codex QA round): `ask` refuses unreadable respond
  instructions before creating an exchange and rejects a zero timeout (GNU
  `timeout 0` = no limit); a responder that claims and then dies is reported as
  `state=claimed` with the `--takeover` path; `--background` reports the real
  state; `archive` relocates the responder log into the archived exchange (no
  orphan files); the installer backs up a real directory at the Codex skill
  location, `--check` never lets a current skill symlink mask a stale plugin
  and stays silent about sides it could not inspect; whitespace-form
  `[ sandbox_workspace_write ]` headers are recognized (no duplicate tables).

## Prehistory (internal, as `agent-mailbox`)

Before the public release the tool lived as `agent-mailbox` (internal versions
1.0.0–1.3.6, git tags `agent-mailbox--v*`): the exchange store with
publish/claim/respond/read-response/archive, hash-bound prompt and response,
atomic claim, worktree-aware matching; symlink containment and retry-safe
operations; validated bounded headers; plugin packaging and eleven Codex QA
hardening rounds (semantic TOML handling, state-aware side-effect-free
`--check`, fail-closed plugin inspection, non-clobbering backups).
