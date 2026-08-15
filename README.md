# agent-mailbox

Global, concurrent, file-based mailbox for Codex → Claude Code review exchanges.
One directory per exchange under `~/.agent-mailbox/`, so any number of
exchanges can be open at once across repositories, git worktrees, and
Codex/Claude sessions. Replaces per-checkout mailboxes (which silently split
across worktrees).

```
~/.agent-mailbox/
  exchanges/<Exchange-ID>/prompt.md     Codex writes; frozen (SHA-256) by `publish`
  exchanges/<Exchange-ID>/meta          tool-owned state, authoritative
  exchanges/<Exchange-ID>/claim/        atomic claim (token + owner)
  exchanges/<Exchange-ID>/response.md   Claude writes; write-once, hash-bound
  archive/<Exchange-ID>/                after Codex consumes it
```

States: `draft → published → claimed → answered → archived`.

## Install

```bash
~/tools/agent-mailbox/install.sh        # symlinks bin + both skills into $HOME
~/tools/agent-mailbox/install.sh --check
```

Links: `~/.local/bin/agent-mailbox`, `~/.claude/skills/codex-mailbox`
(Claude Code, all projects), `~/.codex/skills/claude-mailbox` (Codex, all
projects). Also creates the store (0700) and adds it to Codex's sandbox as a
writable root (`[sandbox_workspace_write] writable_roots` in
`~/.codex/config.toml`) — without that, Codex's workspace-write sandbox sees
`$HOME` read-only and `agent-mailbox new` fails. Restart sessions to load
skills. Replaced real directories are backed up under `backups/` (outside the
skills trees, so a backup can never be discovered as a duplicate skill).

## Flow

Codex (any checkout):
```bash
agent-mailbox new --topic "h1 review"      # -> exchange_id, prompt_path (records Repo, Git-Common-Dir, Branch, Commit, CODEX_THREAD_ID)
$EDITOR <prompt_path>                       # fill in Task:
agent-mailbox publish <ID>                  # freeze; now visible as pending
agent-mailbox wait <ID> --timeout 600 &     # or poll `status <ID>`; exit 0 answered / 124 timeout / 2 archived
agent-mailbox read-response <ID>            # validated (ID + prompt hash + response hash)
agent-mailbox archive <ID>
```

Claude Code (`/codex-mailbox [ID]`, in any checkout of that repo):
```bash
agent-mailbox list --pending --here         # exchanges for this repo (matched by git common dir → all worktrees)
agent-mailbox claim <ID> --owner claude:...  # -> claim_token
agent-mailbox show <ID>
# ... do the task in the exact Repo path from the header, per that repo's AGENTS.md/CLAUDE.md ...
agent-mailbox respond <ID> --token <claim_token> --file response.md   # write-once
```

## Guarantees

- No shared "pending" slot: creators never clobber each other (atomic `mkdir`
  reservation, IDs stay reserved across `archive/`).
- Claude never sees a half-written prompt (`draft` is invisible; `publish`
  freezes the hash; a later edit makes the exchange non-pending and unclaimable).
- Two responders can't both answer (atomic claim + token; `respond` is
  write-once via `link(2)`); stale claims can be taken over after
  `AGENT_MAILBOX_STALE_CLAIM_SECS` (default 1800) with `--takeover`.
- `read-response`/`wait` succeed only when Exchange-ID, prompt hash, and
  response hash all validate — never by mtime.
- Strict ID grammar (no path traversal); a symlinked exchange directory,
  `.lock`, `meta`, `claim/`, `prompt.md`, or `response.md` is refused by every
  command; `umask 077` (store `0700`, files `0600`, published prompt `0400`);
  `wait` always has a finite timeout.
- Interrupted operations are retry-safe: an orphan `claim/` does not block a
  fresh claim, a linked-but-unfinalized `response.md` rolls forward on the next
  `respond`, and an interrupted `archive` completes (or restores state) on
  retry. `respond` snapshots the candidate file before validating it, so a
  file swapped underneath cannot change what is published.

## Threat model

The store is private to one user (`0700`/`0600`). Integrity checks (Exchange-ID,
prompt SHA-256, response SHA-256, write-once response, one-use claim tokens)
protect against mistakes and races between cooperating agents and sessions.
They are NOT a defence against a process running as the same UID that edits
`meta` or reads claim tokens directly — such a process can do anything the tool
can. Metadata values are rejected if they contain newlines/control characters
so they cannot corrupt `meta` or the JSON output.

## Environment

`AGENT_MAILBOX_DIR` (store), `AGENT_MAILBOX_OWNER` (default claim owner),
`AGENT_MAILBOX_STALE_CLAIM_SECS`.

## Tests

```bash
tests/run.sh
```
