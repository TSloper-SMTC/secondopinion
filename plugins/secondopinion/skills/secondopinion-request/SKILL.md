---
name: secondopinion-request
description: Use when working in Codex and the user wants a second opinion, independent review, red-team, verification, or diagnosis from Claude Code — phrases like "ask Claude", "get Claude's take", "have Claude review/verify this", "second opinion". Runs `secondopinion ask`, which publishes the request and returns Claude's validated answer with no user intervention.
---

# Second opinion from Claude Code (Codex side)

`secondopinion` is a file-based, hash-bound exchange between coding agents.
From Codex, one command does everything: create and publish the exchange, run
a headless Claude Code responder in this checkout, wait, validate, and print
the answer.

## Preconditions

- `command -v secondopinion` must succeed. If not, tell the user to run
  `~/tools/secondopinion/scripts/install.sh` and stop.
- Run it from the checkout the request is about: the exchange records that
  checkout's `Repo`, `Git-Common-Dir`, `Branch`, `Commit`, `Dirty-State` and
  your `CODEX_THREAD_ID`, and Claude works in exactly that path.
- If `ask` fails and its log shows Claude could not connect ("Request timed
  out"), the Codex sandbox has no network: the user must run
  `scripts/install.sh` (it sets `[sandbox_workspace_write] network_access =
  true` in `~/.codex/config.toml`) and restart Codex. Do not work around it.
- Repository instructions (`AGENTS.md`) stay authoritative for what may be
  asked and what Claude may do in that repository.

## Ask

1. Write the request to a file (or use `--task "…"` for a one-liner): what to
   review, exact paths/commits/artifacts, the verdict form you need
   (PROVEN/LIKELY/UNPROVEN/REJECTED, "READY / NOT READY: reasons", …), and
   say explicitly whether it is read-only (the default) or Claude may edit.
2. Run, in the foreground for a bounded request:

   ```bash
   secondopinion ask --topic "<short topic>" --file request.md --timeout 900
   ```

   For a long or open-ended request use `--background`; it prints the ID at
   once. Keep working, then `secondopinion wait <ID> --timeout 600` (yields a
   handle under unified exec; poll it) and `secondopinion read-response <ID>`.
   Add `--write` only when Claude is meant to change files (responder runs
   with `acceptEdits` instead of deny-only).
3. Exit codes: `0` — the printed text is Claude's validated answer (it starts
   with `Exchange-ID:` and `Responder:` lines); `124` — timeout, the exchange
   stays published (retry `secondopinion wait <ID>`, or ask the user to run
   `/secondopinion-respond <ID>` in a Claude Code session); `1` — error, the
   log path is printed and the exchange stays published for a retry.
4. Independently classify what is actionable, wrong, stale, or unproven, then
   `secondopinion archive <ID>` once the content has been consumed.

## Rules

- Never trust output that `read-response` rejects; report the failure.
- One `Exchange-ID` per request; never edit a published prompt — create a new
  exchange instead.
- Exchange files are scratch, not durable evidence: promote conclusions into
  tracked docs, proposals or ledgers where the repository requires it.
- Manual path (no headless responder available): `secondopinion new --topic …`,
  edit the prompt's `Task:` section, `secondopinion publish <ID>`, tell the
  user to run `/secondopinion-respond <ID>` in Claude Code, then `wait` /
  `read-response` / `archive` as above.
