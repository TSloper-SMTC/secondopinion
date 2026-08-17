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
unset AGENT_MAILBOX_DIR   # install.sh honours the override; these assertions target the default $HOME store
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

t "env: HOME unset gives one clear error, not a bash trace"
out="$(env -u HOME "$ROOT/install.sh" --check 2>&1)"; rc=$?
assert_eq "$rc" 1
echo "$out" | grep -q "unbound variable" && fail "bash trace leaked: $out" || ok
echo "$out" | grep -q "HOME" && ok || fail "error does not mention HOME: $out"

t "unknown or surplus arguments are rejected before anything is installed"
FRESH="$TMP/home-args"; mkdir -p "$FRESH"
assert_rc 1 env HOME="$FRESH" "$ROOT/install.sh" --checkk
[ ! -e "$FRESH/.local/bin/agent-mailbox" ] && [ ! -e "$FRESH/.codex/config.toml" ] && ok || fail "install.sh --checkk installed something"
assert_rc 1 env HOME="$FRESH" "$ROOT/install.sh" --check extra
assert_rc 1 env HOME="$FRESH" "$ROOT/install.sh" extra
[ ! -e "$FRESH/.local/bin/agent-mailbox" ] && ok || fail "install.sh with surplus argument installed something"

t "a store path containing a double quote or backslash is refused before any mutation (no malformed TOML)"
QH="$TMP/home-quote"; mkdir -p "$QH"
assert_rc 1 env HOME="$QH" AGENT_MAILBOX_DIR="$TMP/store\"quoted" "$ROOT/install.sh"
[ ! -e "$QH/.codex/config.toml" ] && [ ! -e "$QH/.local/bin/agent-mailbox" ] && ok || fail "install mutated HOME despite unsafe store path"
assert_rc 1 env HOME="$QH" AGENT_MAILBOX_DIR="$TMP/store\\back" "$ROOT/install.sh" --check
assert_rc 1 env HOME="$QH" AGENT_MAILBOX_DIR="$TMP/store\"quoted" "$ROOT/install.sh" --check

t "--check matches the writable_roots entry as a fixed string, not a regex"
RH="$TMP/home-regex"; mkdir -p "$RH/.codex"
printf '[sandbox_workspace_write]\nwritable_roots = ["%s"]\n' "$TMP/store-XYZ" > "$RH/.codex/config.toml"
out="$(env HOME="$RH" AGENT_MAILBOX_DIR="$TMP/store-X.Z" "$ROOT/install.sh" --check 2>&1)"; rc=$?
assert_eq "$rc" 1
echo "$out" | grep -q "MISSING.*writable_roots\|ACTION" && ok || fail "regex '.' matched a different store path in --check: $out"

t "--check on an empty HOME is side-effect-free (does not let the claude CLI create its config)"
EH="$TMP/home-empty"; mkdir -p "$EH"
before="$(cd "$EH" && find . | sort | md5sum)"
( cd "$EH" && env HOME="$EH" PATH="$EH/.local/bin:$PATH" AGENT_MAILBOX_DIR="$EH/store" "$ROOT/install.sh" --check >/dev/null 2>&1 ); rc=$?
assert_eq "$rc" 1
after="$(cd "$EH" && find . | sort | md5sum)"
[ "$before" = "$after" ] && ok || fail "--check mutated an empty HOME: $(cd "$EH" && find . | head -5 | tr '\n' ' ')"

t "--check requires the store inside the [sandbox_workspace_write] table, not any writable_roots line"
TH2="$TMP/home-toml"; mkdir -p "$TH2/.codex" "$TH2/.local/bin" "$TH2/.claude/skills" "$TH2/.codex/skills"
ln -sfn "$ROOT/bin/agent-mailbox" "$TH2/.local/bin/agent-mailbox"; ln -sfn "$ROOT/skills/claude/codex-mailbox" "$TH2/.claude/skills/codex-mailbox"; ln -sfn "$ROOT/skills/codex/claude-mailbox" "$TH2/.codex/skills/claude-mailbox"
printf '[unrelated]\nwritable_roots = ["%s"]\n\n[sandbox_workspace_write]\nwritable_roots = ["/somewhere/else"]\n' "$TH2/.agent-mailbox" > "$TH2/.codex/config.toml"
( cd "$TH2" && env HOME="$TH2" PATH="$TH2/.local/bin:$PATH" "$ROOT/install.sh" --check >/dev/null 2>&1 ); rc=$?
assert_eq "$rc" 1 "(store only in an unrelated table must not pass)"
printf '[sandbox_workspace_write]\nwritable_roots = ["/somewhere/else", "%s"]\n' "$TH2/.agent-mailbox" > "$TH2/.codex/config.toml"
( cd "$TH2" && env HOME="$TH2" PATH="$TH2/.local/bin:$PATH" "$ROOT/install.sh" --check >/dev/null 2>&1 ) && ok || fail "store present in the right table (second array member) must pass"

echo "passed=$PASS failed=$FAIL"
[ "$FAIL" -eq 0 ]
