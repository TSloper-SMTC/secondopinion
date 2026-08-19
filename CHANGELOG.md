# Changelog

## 2.0.0 — 2026-08-17

Renamed from `agent-mailbox` to **secondopinion**; first version that needs no
human relay.

- `secondopinion ask`: one command creates and publishes the exchange, runs a
  headless Claude Code responder in the calling checkout
  (`claude -p "/secondopinion-respond <ID>" --permission-mode dontAsk` plus a
  tool allowlist; `--write` = `acceptEdits`), waits, validates and prints the
  answer (`--background`, `--timeout`, `--model`, `--json`).
- Standard plugin layout: `skills/<name>/SKILL.md`, `bin/`, `scripts/`,
  `LICENSE`, `CHANGELOG.md`; both manifests use the default `skills/` scan.
- Compatibility: `agent-mailbox` remains a deprecated alias, `AGENT_MAILBOX_*`
  variables are honoured with a warning, `~/.agent-mailbox` is migrated once by
  `scripts/install.sh` (old path left as a symlink).
- `scripts/install.sh` sets `[sandbox_workspace_write] network_access = true`
  in `~/.codex/config.toml` (needed for Codex-run commands to reach Claude);
  an explicit `false` is reported, never flipped.
- Env vars: `SECONDOPINION_DIR`, `SECONDOPINION_OWNER`,
  `SECONDOPINION_STALE_CLAIM_SECS`, `SECONDOPINION_BACKUP_DIR`,
  `SECONDOPINION_CLAUDE`, `SECONDOPINION_CLAUDE_ARGS`,
  `SECONDOPINION_MAX_TURNS`, `SECONDOPINION_ASK_TIMEOUT`.

## 1.3.x — 2026-08-17

Plugin packaging (1.3.0: `.claude-plugin`, `.codex-plugin`, self-hosted
marketplace, `install.sh --plugin`); installer hardening through eleven Codex
QA rounds (1.3.1–1.3.6): EOF-safe 64-record header bound, TOML-safe store
paths and semantic `writable_roots` membership, state-aware and side-effect-free
`--check`, mutually exclusive skill/plugin modes with duplicate detection,
fail-closed plugin inspection, overflow-safe seconds, non-clobbering backups
outside the plugin source.

## 1.2.x — 2026-08-17

Header integrity: derived header/meta values validated before an exchange is
reserved; strict `Responder:` value; header block bounded to the first blank
line (max 64 records) and byte-checked (CRLF/TAB allowed, other control bytes
refused); `publish` refuses an untouched Task placeholder; exactly one
positional ID per command; `wait --timeout` parsed as decimal.

## 1.1.0 — 2026-08-15

Symlink containment everywhere, `respond` snapshot-then-validate, retry-safe
claim/respond/archive, status exit codes, metadata/JSON sanitization, CRLF
tolerance.

## 1.0.0 — 2026-08-15

Global file mailbox for Codex→Claude review exchanges: one directory per
Exchange-ID, publish/claim/respond/read-response/archive, hash-bound prompt and
response, atomic claim, worktree-aware matching.
