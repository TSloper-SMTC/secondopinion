#!/bin/bash
# Tests for install.sh — runs against a throwaway HOME.
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
PASS=0; FAIL=0; CURRENT=""
t() { CURRENT="$1"; }
ok() { PASS=$((PASS+1)); }
fail() { FAIL=$((FAIL+1)); echo "FAIL [$CURRENT] $*" >&2; }
assert_link() { [ -L "$1" ] && [ "$(readlink -f "$1")" = "$(readlink -f "$2")" ] && ok || fail "$1 is not a symlink to $2"; }
assert_rc() { local want="$1"; shift; "$@" >/dev/null 2>&1; local rc=$?; [ "$rc" = "$want" ] && ok || fail "rc=$rc want=$want: $*"; }
assert_eq() { [ "$1" = "$2" ] && ok || fail "expected '$2' got '$1'"; }

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
export HOME="$TMP/home"; mkdir -p "$HOME"
export PATH="$HOME/.local/bin:$PATH"
export AGENT_MAILBOX_BACKUP_DIR="$TMP/backups"

t "fresh install creates the three symlinks"
assert_rc 0 "$ROOT/install.sh"
assert_link "$HOME/.local/bin/agent-mailbox" "$ROOT/bin/agent-mailbox"
assert_link "$HOME/.claude/skills/codex-mailbox" "$ROOT/skills/claude/codex-mailbox"
assert_link "$HOME/.codex/skills/claude-mailbox" "$ROOT/skills/codex/claude-mailbox"

t "install is idempotent"
assert_rc 0 "$ROOT/install.sh"
assert_link "$HOME/.local/bin/agent-mailbox" "$ROOT/bin/agent-mailbox"

t "an existing real directory is backed up, not deleted"
rm "$HOME/.codex/skills/claude-mailbox"
mkdir -p "$HOME/.codex/skills/claude-mailbox"; echo legacy > "$HOME/.codex/skills/claude-mailbox/SKILL.md"
assert_rc 0 "$ROOT/install.sh"
assert_link "$HOME/.codex/skills/claude-mailbox" "$ROOT/skills/codex/claude-mailbox"
ls -d "$AGENT_MAILBOX_BACKUP_DIR/claude-mailbox.bak-"* >/dev/null 2>&1 && grep -q legacy "$AGENT_MAILBOX_BACKUP_DIR"/claude-mailbox.bak-*/SKILL.md && ok || fail "legacy dir not backed up under \$AGENT_MAILBOX_BACKUP_DIR"
# the backup must NOT remain anywhere under the skills dir (it would be discovered as a duplicate skill)
[ -z "$(find "$HOME/.codex/skills" -name 'SKILL.md' -path '*bak*' 2>/dev/null)" ] && ok || fail "backup left inside skills dir"

t "--check reports status without changing anything and exits 0 when installed"
assert_rc 0 "$ROOT/install.sh" --check
rm "$HOME/.local/bin/agent-mailbox"
assert_rc 1 "$ROOT/install.sh" --check
"$ROOT/install.sh" >/dev/null 2>&1
assert_rc 1 env PATH=/usr/bin:/bin "$ROOT/install.sh" --check      # PATH without ~/.local/bin => not installed
assert_rc 0 env PATH=/usr/bin:/bin "$ROOT/install.sh"              # but install itself still succeeds (warns)

t "codex sandbox: install adds writable_roots for the store to ~/.codex/config.toml (created if missing)"
rm -f "$HOME/.codex/config.toml"
assert_rc 0 "$ROOT/install.sh"
grep -q '^\[sandbox_workspace_write\]' "$HOME/.codex/config.toml" && ok || fail "table missing"
grep -q "writable_roots = \[\"$HOME/.agent-mailbox\"\]" "$HOME/.codex/config.toml" && ok || fail "writable_roots missing"
[ -d "$HOME/.agent-mailbox" ] && [ "$(stat -c %a "$HOME/.agent-mailbox")" = "700" ] && ok || fail "store dir not created 0700"

t "codex sandbox: existing config without the table gets the block appended once (idempotent)"
printf 'model = "x"\n[tui]\nfoo = 1\n' > "$HOME/.codex/config.toml"
"$ROOT/install.sh" >/dev/null 2>&1; "$ROOT/install.sh" >/dev/null 2>&1
assert_eq "$(grep -c '^\[sandbox_workspace_write\]' "$HOME/.codex/config.toml")" "1"
grep -q '^model = "x"' "$HOME/.codex/config.toml" && ok || fail "existing config clobbered"
assert_rc 0 "$ROOT/install.sh" --check

t "codex sandbox: table present but store path absent -> install warns, --check fails, config untouched"
printf 'model = "x"\n[sandbox_workspace_write]\nwritable_roots = ["/somewhere/else"]\n' > "$HOME/.codex/config.toml"
before="$(cat "$HOME/.codex/config.toml")"
assert_rc 0 "$ROOT/install.sh"
assert_eq "$(cat "$HOME/.codex/config.toml")" "$before"
assert_rc 1 "$ROOT/install.sh" --check
"$ROOT/install.sh" --check 2>&1 | grep -q 'writable_roots' && ok || fail "check output does not explain writable_roots"

t "installed tool runs through the symlink"
"$ROOT/install.sh" >/dev/null 2>&1
out="$("$HOME/.local/bin/agent-mailbox" --version)"; [[ "$out" == agent-mailbox* ]] && ok || fail "version via symlink: '$out'"

echo "passed=$PASS failed=$FAIL"
[ "$FAIL" -eq 0 ]
