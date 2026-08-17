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

Two mutually exclusive forms: a successful install leaves exactly one Claude-side
form, as `--check` verifies. Skill mode uninstalls the plugin and creates the
user-level skill symlink only after a successful re-inspection confirms the
plugin is gone; plugin mode retires (or backs up) anything at
`~/.claude/skills/codex-mailbox`. Switching fails before changing anything if an
existing Claude plugin registry cannot be inspected (`claude plugin list --json`
failing, malformed, or schema-invalid).

**Skill mode (default)** — symlinks the CLI and both skills into `$HOME`:
```bash
~/tools/agent-mailbox/install.sh        # ~/.local/bin/agent-mailbox, ~/.claude/skills/codex-mailbox, ~/.codex/skills/claude-mailbox
~/tools/agent-mailbox/install.sh --check
```
Claude Code invokes the skill as `/codex-mailbox [ID]`.

**Plugin mode** — the repo is also a Claude Code plugin *and* its own
marketplace (`.claude-plugin/plugin.json`, `.claude-plugin/marketplace.json`;
a `.codex-plugin/plugin.json` is included for Codex's plugin format):
```bash
~/tools/agent-mailbox/install.sh --plugin
#  = symlink CLI + Codex skill, then
#    claude plugin marketplace add ~/tools/agent-mailbox && claude plugin install agent-mailbox@agent-mailbox
#    (retires a user-level ~/.claude/skills/codex-mailbox symlink so the skill is not listed twice)
```
Claude Code then invokes the skill as `/agent-mailbox:codex-mailbox [ID]`.
After pulling the repo, re-run `install.sh --plugin` (it repoints a stale
marketplace, updates or reinstalls to the checkout's version, re-enables a
disabled plugin, and fails — before touching anything — if `claude`/`python3`
are missing or the store path cannot be written into TOML); `--check` passes
only when the marketplace points at this checkout and the plugin is exactly this
version and enabled. `claude plugin validate --strict .claude-plugin/plugin.json` and the
marketplace manifest pass. The `agent-mailbox` CLI itself is not part of the
plugin model (plugins cannot manage PATH), which is why install.sh still
symlinks it.

`install.sh --check` never modifies HOME (it does not even start the `claude`
CLI on a pristine HOME) and fails on missing, stale, disabled, wrong-version,
duplicate (a current plugin plus anything at `~/.claude/skills/codex-mailbox`)
or uninspectable plugin state; the store must be a real member of
`[sandbox_workspace_write].writable_roots` (comments ignored, multiline arrays
understood); otherwise it reports which form is installed.

A non-check installation creates the store (0700) and adds it to Codex's
sandbox as a writable root (`[sandbox_workspace_write] writable_roots` in
`~/.codex/config.toml`) — without that, Codex's workspace-write sandbox sees
`$HOME` read-only and `agent-mailbox new` fails. Restart sessions to load
skills. Replaced real files and directories are moved, without clobbering (same-second
safe), to `$HOME/.local/state/agent-mailbox/backups/` (override with
`AGENT_MAILBOX_BACKUP_DIR`) — outside the skills trees, so a backup can never
be discovered as a duplicate skill, and outside the plugin source, so a plugin
install never copies it.

## Flow

Codex (any checkout):
```bash
agent-mailbox new --topic "h1 review"      # -> exchange_id, prompt_path (records Repo, Git-Common-Dir, Branch, Commit, CODEX_THREAD_ID)
$EDITOR <prompt_path>                       # fill in Task:
agent-mailbox publish <ID>                  # freeze; now visible as pending
agent-mailbox wait <ID> --timeout 600 &     # or poll `status <ID>`; exit 0 answered / 124 timeout / 2 archived / 1 error
agent-mailbox read-response <ID>            # validated (ID + prompt hash + response hash)
agent-mailbox archive <ID>
```

Claude Code (`/codex-mailbox [ID]` in skill mode, or `/agent-mailbox:codex-mailbox [ID]` in plugin mode, in any checkout of that repo):
```bash
agent-mailbox list --pending --here         # exchanges for this repo (matched by git common dir → all worktrees)
agent-mailbox show <ID>                     # read first: verify Repo/Branch/Commit, read that repo's AGENTS.md/CLAUDE.md
agent-mailbox claim <ID> --owner claude:...  # claim immediately before substantive work -> claim_token
# ... do the task in the exact Repo path from the header, per that repo's policy ...
tmp="$(mktemp)"; chmod 600 "$tmp"           # write the response OUTSIDE the target repository
agent-mailbox respond <ID> --token <claim_token> --file "$tmp" && rm -f "$tmp"   # write-once; a failed respond keeps the file for retry
```

## Guarantees

- No shared "pending" slot: creators never clobber each other (atomic `mkdir`
  reservation, IDs stay reserved across `archive/`).
- Claude never sees a half-written prompt (`draft` is invisible; `publish`
  freezes the hash; a later edit makes the exchange non-pending and unclaimable).
  `publish` refuses a prompt whose `Task:` placeholder is still untouched.
- Every header/meta value is validated before an exchange is reserved: explicit
  options, the derived repository path/branch/commit and `CODEX_THREAD_ID` must
  be free of newlines and control characters (nothing can inject header or
  `meta` lines). A response's `Responder:` value must be nonempty and control-free.
- Every command that addresses an exchange accepts exactly one exchange ID; a
  second positional argument is an error rather than silently replacing the first.
- Prompt and response headers end at the first blank line (or EOF); every line in
  that block is byte-validated and header values (`Exchange-ID:`, `Responder:`) are
  taken only from it. Header records 1–64 are accepted; record 65 is refused
  whether the block ends with a blank line, EOF, or an unterminated final line.
  CRLF line endings and TAB are allowed; any other control byte (embedded CR, NUL,
  ESC...) is refused (byte-level check in the C locale; UTF-8 text is fine). A
  rejected candidate changes nothing: the exchange stays `draft`/`claimed` (status
  shows `n/a`) and can be retried; a stored, hash-bound prompt/response that later
  fails validation reports `prompt_ok`/`response_ok=no`, and re-running `publish`
  on such a prompt is an error, not a no-op.
- Two responders can't both answer (atomic claim + token; `respond` is
  write-once via `link(2)`); stale claims can be taken over after
  `AGENT_MAILBOX_STALE_CLAIM_SECS` (default 1800) with `--takeover`.
- `read-response`/`wait` succeed only when Exchange-ID, prompt hash, and
  response hash all validate — never by mtime.
- Strict ID grammar (no path traversal). `list` does not follow symlinked
  exchange directories or metadata; every command that accesses an exchange
  refuses a symlinked exchange directory, `.lock`, `meta`, `claim/`, `prompt.md`
  or `response.md`; `umask 077` (store `0700`, files `0600`, published prompt
  `0400`); `wait` always has a finite timeout.
- Interrupted operations are retry-safe: an orphan `claim/` does not block a
  fresh claim, a valid linked-but-unfinalized `response.md` rolls forward on the
  next `respond` (an invalid one is refused for manual inspection: while the
  exchange is still `claimed` and `meta` holds no `response_sha256`, inspect
  `<exchange_dir>/response.md`, remove it if it is not the intended response,
  then re-run `respond`), and an interrupted `archive` completes (or restores
  state) on retry. `respond` snapshots the candidate file before validating it, so a
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
`AGENT_MAILBOX_BACKUP_DIR` (installer backups; default
`$HOME/.local/state/agent-mailbox/backups`),
`AGENT_MAILBOX_STALE_CLAIM_SECS` (non-negative decimal seconds ≤ 4294967295,
leading zeros allowed, the same rule as `wait --timeout`; malformed or
out-of-range values are refused so nothing can wrap in shell arithmetic).

## Tests

```bash
tests/run.sh
```
