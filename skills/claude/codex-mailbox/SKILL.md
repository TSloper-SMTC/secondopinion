---
name: codex-mailbox
description: Use when the user invokes /codex-mailbox (optionally with an Exchange-ID) or asks to process, answer, or check pending Codex mailbox exchanges held in the global agent-mailbox store.
---

# Codex Mailbox (global)

Answer Codex→Claude review exchanges held in the global `agent-mailbox` store
(`~/.agent-mailbox`; tool `agent-mailbox` on PATH; one directory per exchange,
any number open at once across repositories and sessions).

Use only when the user invokes `/codex-mailbox [ID]` or asks to process the
Codex mailbox.

## Workflow

1. **Preflight**: `command -v agent-mailbox`. If missing, tell the user to run
   `~/tools/agent-mailbox/install.sh` and stop.
2. **Find work**
   - With an ID: `agent-mailbox status <ID>`. Proceed only if `state=published`
     (or `state=claimed` and `claimed_by` is you) and `prompt_ok=yes`.
   - Without an ID: `agent-mailbox list --pending --here` — exchanges whose
     repository (by git common dir, so every worktree counts) is the one this
     session runs in. If that is empty, run `agent-mailbox list --pending` and
     report exchanges pending for OTHER repositories, naming each repo path,
     instead of saying "nothing pending"; do not answer those from here — they
     need a Claude session in that repository. If several match here, process
     oldest first, one at a time.
   - Transition check (legacy per-checkout mailboxes): if nothing is pending
     here, also run
     `for w in $(git worktree list --porcelain | awk '/^worktree /{print $2}'); do ls "$w"/docs/superpowers/agent_mailbox/pending_codex_prompt.md 2>/dev/null; done`
     from the current repo. If it prints a path, a Codex session on an older
     branch used the retired per-checkout mailbox: report the path and its
     `Exchange-ID`, and offer to migrate it (`agent-mailbox new` from that
     checkout, copy the Task/Required reading, `publish`) rather than answering
     it in place.
3. **Claim**: `agent-mailbox claim <ID> --owner "claude:<hostname>:<short-context>"`.
   Keep the printed `claim_token`. If the claim is refused, another responder
   owns it — report that and stop for that ID. Never `--takeover` unless the
   user explicitly asks.
4. **Read**: `agent-mailbox show <ID>`. Note the header: `Repo`, `Branch`,
   `Commit`, `Dirty-State`, `Git-Common-Dir`, `Codex-Thread`.
5. **Go to the exact checkout** named by `Repo:` — use that path for every
   command (`git -C`, absolute paths, or `cd` inside each command). Verify
   `git branch --show-current` and `git rev-parse --short HEAD` against the
   header; if they differ, state the drift in the response (a finding, not a
   blocker unless the task depends on it). If the path is missing, respond with
   that fact and REJECTED for anything you could not verify.
6. **Read the target checkout's `AGENTS.md`, `CLAUDE.md`, and every file under
   `Required reading` in the prompt BEFORE doing the task.** They are
   authoritative for how the task must be done (startup files, evidence
   discipline, no-commit rules, ledger requirements).
7. **Do the task exactly as written.** Follow the prompt's rules on evidence and
   output format. Label technical conclusions `PROVEN` / `LIKELY` / `UNPROVEN`
   / `REJECTED` when the prompt asks for evidence discipline. Ground claims in
   current source, artifacts, git history, or files the prompt cites — never
   chat memory.
8. **Write the response** to a temp file (your scratchpad), starting exactly:
   ```text
   Exchange-ID: <ID>
   Responder: Claude Code
   ```
   then a blank line, then the body. End with a clear verdict and next action.
9. **Publish**: `agent-mailbox respond <ID> --token <claim_token> --file <tmpfile>`,
   then `agent-mailbox status <ID>`. Report to the user: the ID, `state=answered`,
   `response_ok=yes`. Codex picks it up with its running `wait` or
   `agent-mailbox read-response <ID>`.

## Rules

- Never edit `prompt.md`; never archive; never `--takeover` unprompted.
- Never commit in the target repository as part of an exchange unless its
  prompt AND that repository's policy explicitly require it.
- If the prompt says the task is read-only, touch nothing except your response file.
- The target checkout's repository policy (`AGENTS.md`, `CLAUDE.md`) overrides
  this skill wherever they differ.
- Mailbox files are scratch, not durable evidence. If an exchange materially
  affects a decision, promote the conclusion into that repository's tracked
  docs the way its policy directs.
