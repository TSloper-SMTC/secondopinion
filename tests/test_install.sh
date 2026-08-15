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

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
export HOME="$TMP/home"; mkdir -p "$HOME"
export PATH="$HOME/.local/bin:$PATH"

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
ls -d "$HOME/.codex/skills/claude-mailbox.bak-"* >/dev/null 2>&1 && grep -q legacy "$HOME"/.codex/skills/claude-mailbox.bak-*/SKILL.md && ok || fail "legacy dir not backed up"

t "--check reports status without changing anything and exits 0 when installed"
assert_rc 0 "$ROOT/install.sh" --check
rm "$HOME/.local/bin/agent-mailbox"
assert_rc 1 "$ROOT/install.sh" --check
"$ROOT/install.sh" >/dev/null 2>&1
assert_rc 1 env PATH=/usr/bin:/bin "$ROOT/install.sh" --check      # PATH without ~/.local/bin => not installed
assert_rc 0 env PATH=/usr/bin:/bin "$ROOT/install.sh"              # but install itself still succeeds (warns)

t "installed tool runs through the symlink"
"$ROOT/install.sh" >/dev/null 2>&1
out="$("$HOME/.local/bin/agent-mailbox" --version)"; [[ "$out" == agent-mailbox* ]] && ok || fail "version via symlink: '$out'"

echo "passed=$PASS failed=$FAIL"
[ "$FAIL" -eq 0 ]
