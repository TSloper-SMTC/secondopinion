# Changelog

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
  exchange; `ask`/`review --max-turns` sizes the responder turn budget.
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
