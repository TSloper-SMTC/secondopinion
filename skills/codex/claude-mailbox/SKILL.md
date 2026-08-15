---
name: claude-mailbox
description: Use when the user asks Codex to ask Claude Code for an independent review, create a Claude mailbox prompt, wait for or read a Claude mailbox response, or process agent-mailbox exchanges.
---

# Claude Mailbox (global agent-mailbox)

File-based Codex→Claude Code exchanges through the global tool `agent-mailbox`
(store `~/.agent-mailbox`; one directory per exchange; any number of exchanges
may be open at once across repositories, worktrees, and sessions).

## Preconditions

- `command -v agent-mailbox` must succeed. If not, report that the mailbox tool
  is not installed (`~/tools/agent-mailbox/install.sh`) and stop.
- If `new` fails with "cannot create mailbox store" / "Read-only file system",
  your sandbox lacks the store as a writable root; ask the user to run
  `~/tools/agent-mailbox/install.sh` (it adds `[sandbox_workspace_write]
  writable_roots` for `~/.agent-mailbox` to `~/.codex/config.toml`) and restart
  Codex. Do not work around it by writing elsewhere.
- Run `new` from the checkout the review is about. It records that checkout's
  `Repo`, `Git-Common-Dir`, `Branch`, `Commit`, `Dirty-State`, and your
  `CODEX_THREAD_ID`; Claude uses them to work in the right place.
- Repository instructions (`AGENTS.md`) remain authoritative for the content of
  the request and for what Claude may do in that repository.

## Creating a request

1. `agent-mailbox new --topic "<short-topic>"` → note `exchange_id` and `prompt_path`.
2. Edit `prompt_path`: replace the `Task:` section with the focused request.
   Keep the header lines intact. Include only task-relevant paths; list the
   repository's startup files (whatever its `AGENTS.md`/`CLAUDE.md` require)
   under `Required reading`; keep the response requirements (exact
   `Exchange-ID`, PROVEN/LIKELY/UNPROVEN/REJECTED labels, grounding, verdict +
   next action). Say explicitly if the task is read-only.
3. `agent-mailbox publish <ID>`. The exchange is invisible to Claude until
   published; after publish the prompt is frozen (hash-bound). To change it,
   create a new exchange.
4. Tell the user: run `/codex-mailbox <ID>` in Claude Code, in any checkout of
   that repository.

## Waiting for the response (keep working meanwhile)

- Start `agent-mailbox wait <ID> --timeout 600` as a long-running command. With
  unified exec it yields after ~10 s with a handle while the process keeps
  running; continue other work and poll the handle between steps.
  Exit codes: `0` answered · `124` timeout (re-issue if still wanted) ·
  `2` archived · `1` error.
- Or poll `agent-mailbox status <ID>` (instant) between steps.
- Do not busy-loop; never poll faster than the tool itself does.

## Reading the response

1. `agent-mailbox read-response <ID>` — validates the `Exchange-ID`, the frozen
   prompt hash, and the response hash. If it exits non-zero, do NOT use the
   response; report the failure.
2. Summarize Claude's findings and independently classify what is actionable,
   wrong, stale, or unproven.
3. `agent-mailbox archive <ID>` only after the useful content has been consumed.

## Rules

- Never trust a response that `read-response` rejects.
- Never publish a prompt that still contains the template placeholder.
- One `Exchange-ID` per request; never reuse or edit a published prompt.
- Mailbox files are scratch, not durable evidence: promote useful conclusions
  into tracked docs/proposals or the ledger where the repository requires it.
