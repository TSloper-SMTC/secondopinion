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
     and `prompt_ok=yes`. If `state=claimed`: proceed only if THIS session still
     holds the matching `claim_token` from an earlier step; otherwise report an
     existing claim (`claimed_by`, `claim_age_secs`) and stop for that ID —
     re-running `claim` always fails, even for the same owner.
   - Without an ID: `agent-mailbox list --pending --here` — exchanges whose
     repository (by git common dir, so every worktree counts) is the one this
     session runs in. If that is empty, run `agent-mailbox list --pending` and
     report exchanges pending for OTHER repositories, naming each repo path,
     instead of saying "nothing pending"; do not answer those from here — they
     need a Claude session in that repository. If several match here, process
     oldest first, one at a time.
   - Transition check (legacy per-checkout mailboxes): if nothing is pending
     here, also run, from the current repo:
     `git worktree list --porcelain | sed -n 's/^worktree //p' | while IFS= read -r w; do ls -- "$w/docs/superpowers/agent_mailbox/pending_codex_prompt.md" 2>/dev/null; done`
     If it prints a path, a Codex session on an older branch used the retired
     per-checkout mailbox: report the path and its `Exchange-ID`, and offer to
     migrate it (`agent-mailbox new` from that checkout, copy the Task/Required
     reading, `publish`) rather than answering it in place.
3. **Read before claiming**: `agent-mailbox show <ID>`. Note the header:
   `Repo`, `Branch`, `Commit`, `Dirty-State`, `Git-Common-Dir`, `Codex-Thread`.
   Go to the exact checkout named by `Repo:` — use that path for every command
   (`git -C`, absolute paths, or `cd` inside each command). Verify
   `git branch --show-current` and `git rev-parse --short HEAD` against the
   header; if they differ, the drift is a finding to state in the response (not
   a blocker unless the task depends on it). If the path is missing, you cannot
   serve this exchange: report that and stop without claiming.
   Then read that checkout's `AGENTS.md`, `CLAUDE.md`, and every file under
   `Required reading` in the prompt. They are authoritative for how the task
   must be done (startup files, evidence discipline, no-commit rules, ledger
   requirements). If they forbid the task as written, respond saying so.
4. **Claim** (immediately before substantive work):
   `agent-mailbox claim <ID> --owner "claude:<hostname>:<short-context>"`.
   Keep the printed `claim_token` for step 7. If the claim is refused, another
   responder owns it — report that and stop for that ID. Never `--takeover`
   unless the user explicitly asks.
5. **Do the task exactly as written.** Follow the prompt's rules on evidence and
   output format. Label technical conclusions `PROVEN` / `LIKELY` / `UNPROVEN`
   / `REJECTED` when the prompt asks for evidence discipline. Ground claims in
   current source, artifacts, git history, or files the prompt cites — never
   chat memory.
6. **Write the response** to a private temp file OUTSIDE the target repository
   (`mktemp` under your scratchpad or `/tmp`, mode 0600), starting exactly:
   ```text
   Exchange-ID: <ID>
   Responder: Claude Code
   ```
   then a blank line, then the body. End with a clear verdict and next action.
7. **Publish**: `agent-mailbox respond <ID> --token <claim_token> --file <tmpfile>`,
   then `agent-mailbox status <ID>` and remove the temp file. Report to the
   user: the ID, `state=answered`, `response_ok=yes`. Codex picks it up with its
   running `wait` or `agent-mailbox read-response <ID>`.

## Rules

- Never edit `prompt.md`; never archive; never `--takeover` unprompted.
- Never commit in the target repository as part of an exchange unless its
  prompt AND that repository's policy explicitly require it.
- If the prompt says the task is read-only, write nothing inside the target
  repository; the only writes are the mailbox store (via the tool) and your
  external temp response file.
- The target checkout's repository policy (`AGENTS.md`, `CLAUDE.md`) overrides
  this skill wherever they differ.
- Mailbox files are scratch, not durable evidence. If an exchange materially
  affects a decision, promote the conclusion into that repository's tracked
  docs the way its policy directs.
