---
name: secondopinion-respond
description: Use when the user invokes /secondopinion-respond (optionally with an Exchange-ID), asks to process, answer, or check pending second-opinion requests from Codex in the global secondopinion store, or when this session was started headlessly by `secondopinion ask` to answer one exchange.
---

# Second opinion — respond (Claude Code side)

Answer second-opinion exchanges held in the global `secondopinion` store
(`~/.secondopinion`; tool `secondopinion` on PATH; one directory per exchange,
any number open at once across repositories and sessions).

Use when the user invokes `/secondopinion:secondopinion-respond [ID]` (Claude
plugin install) or `/secondopinion-respond [ID]` (skill install), asks to
process pending second-opinion requests, or when you are running headlessly
because `secondopinion ask` handed you these instructions inline (no Claude-side
install exists in that case) — then there is no user: never wait for input,
follow this workflow to the end, and treat the request as read-only unless it
says otherwise.

## Workflow

1. **Preflight**: `command -v secondopinion`. If missing, tell the user to run
   `plugins/secondopinion/scripts/install.sh` from the secondopinion checkout
   and stop.
2. **Find work**
   - With an ID: `secondopinion status <ID>`. Proceed only if `state=published`
     and `prompt_ok=yes`. If `state=claimed`: proceed only if THIS session still
     holds the matching `claim_token` from an earlier step; otherwise report an
     existing claim (`claimed_by`, `claim_age_secs`) and stop for that ID —
     re-running `claim` always fails, even for the same owner.
     If `state=published` but `responder_status=launching`, `running`, or
     `running-heartbeat`, an interactive/manual session must stop: a foreground
     `ask` already owns the reserved run. The headless responder launched by
     that `ask` carries its matching run identity and is allowed to continue.
   - Without an ID: `secondopinion list --pending --here` — exchanges whose
     repository (by git common dir, so every worktree counts) is the one this
     session runs in. If that is empty, run `secondopinion list --pending` and
     report exchanges pending for OTHER repositories, naming each repo path,
     instead of saying "nothing pending"; do not answer those from here — they
     need a Claude session in that repository. If several match here, process
     oldest first, one at a time.
   - Transition check (legacy per-checkout mailboxes): if nothing is pending
     here, also run, from the current repo:
     `git worktree list --porcelain | sed -n 's/^worktree //p' | while IFS= read -r w; do ls -- "$w/docs/superpowers/secondopinion/pending_codex_prompt.md" 2>/dev/null; done`
     If it prints a path, a Codex session on an older branch used the retired
     per-checkout mailbox: report the path and its `Exchange-ID`, and offer to
     migrate it (`secondopinion new` from that checkout, copy the Task/Required
     reading, `publish`) rather than answering it in place.
3. **Read before claiming**: `secondopinion show <ID>`. Note the header:
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
   `secondopinion claim <ID> --owner "claude:<hostname>:<short-context>"`.
   Keep the printed `claim_token` for step 7. If the claim is refused, another
   responder owns it — report that and stop for that ID. Never `--takeover`
   unless the user explicitly asks.
5. **Do the task exactly as written.** Follow the prompt's rules on evidence and
   output format. Label technical conclusions `PROVEN` / `LIKELY` / `UNPROVEN`
   / `REJECTED` when the prompt asks for evidence discipline. Ground claims in
   current source, artifacts, git history, or files the prompt cites — never
   chat memory. For a headless run, `status` records `primary_deadline_epoch`
   and `hard_deadline_epoch`. Prefer publishing a complete, concise answer with
   the best evidence already obtained well before the hard deadline; do not lose
   the whole result by holding publication for optional polish.
6. **Write the response** to a private temp file OUTSIDE the target repository
   (`mktemp` under your scratchpad or `/tmp`, mode 0600), starting exactly:
   ```text
   Exchange-ID: <ID>
   Responder: Claude Code
   ```
   then a blank line, then the body. End with a clear verdict and next action.
7. **Publish**: `secondopinion respond <ID> --token <claim_token> --file <tmpfile>`,
   then `secondopinion status <ID>` and remove the temp file. Report to the
   user: the ID, `state=answered`, `response_ok=yes`. Codex picks it up with its
   running `wait` or `secondopinion read-response <ID>`.

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
