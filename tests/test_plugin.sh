#!/bin/bash
# Tests for the Claude Code / Codex plugin packaging of agent-mailbox.
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
PASS=0; FAIL=0; CURRENT=""
t() { CURRENT="$1"; }
ok() { PASS=$((PASS+1)); }
fail() { FAIL=$((FAIL+1)); echo "FAIL [$CURRENT] $*" >&2; }
assert_eq() { [ "$1" = "$2" ] && ok || fail "expected '$2' got '$1' ${3:-}"; }
assert_rc() { local want="$1"; shift; "$@" >/dev/null 2>&1; local rc=$?; [ "$rc" = "$want" ] && ok || fail "rc=$rc want=$want: $*"; }
json() { python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); print(eval("d"+sys.argv[2]))' "$1" "$2" 2>/dev/null; }

TOOL_VERSION="$(sed -n 's/^VERSION="\(.*\)"$/\1/p' "$ROOT/bin/agent-mailbox")"

t "manifests exist and parse; names/versions agree with the tool"
for m in .claude-plugin/plugin.json .codex-plugin/plugin.json .claude-plugin/marketplace.json; do
  python3 -c "import json;json.load(open('$ROOT/$m'))" 2>/dev/null && ok || fail "$m missing or invalid JSON"
done
assert_eq "$(json "$ROOT/.claude-plugin/plugin.json" "['name']")" "agent-mailbox"
assert_eq "$(json "$ROOT/.codex-plugin/plugin.json" "['name']")" "agent-mailbox"
assert_eq "$(json "$ROOT/.claude-plugin/plugin.json" "['version']")" "$TOOL_VERSION" "(claude plugin version vs bin VERSION)"
assert_eq "$(json "$ROOT/.codex-plugin/plugin.json" "['version']")" "$TOOL_VERSION" "(codex plugin version vs bin VERSION)"
assert_eq "$(json "$ROOT/.claude-plugin/marketplace.json" "['plugins'][0]['version']")" "$TOOL_VERSION" "(marketplace version vs bin VERSION)"
assert_eq "$(json "$ROOT/.claude-plugin/marketplace.json" "['plugins'][0]['name']")" "agent-mailbox"
assert_eq "$(json "$ROOT/.claude-plugin/marketplace.json" "['plugins'][0]['source']")" "./"

t "each plugin exposes exactly its own side's skill; skill dir names match frontmatter"
assert_eq "$(json "$ROOT/.claude-plugin/plugin.json" "['skills']")" "['./skills/claude']"
assert_eq "$(json "$ROOT/.codex-plugin/plugin.json" "['skills']")" "['./skills/codex']"
for d in "$ROOT"/skills/*/*/; do
  name="$(basename "$d")"
  fm="$(sed -n '2,6p' "$d/SKILL.md" | sed -n 's/^name: *//p' | head -1)"
  assert_eq "$fm" "$name" "(frontmatter name vs directory $d)"
done

if command -v claude >/dev/null 2>&1; then
  t "claude plugin validate accepts plugin and marketplace manifests (strict)"
  assert_rc 0 claude plugin validate --strict "$ROOT/.claude-plugin/plugin.json"
  assert_rc 0 claude plugin validate --strict "$ROOT/.claude-plugin/marketplace.json"

  t "throwaway HOME: marketplace add + install work from the local repo and expose only codex-mailbox"
  TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
  export HOME="$TMP/home"; mkdir -p "$HOME"
  ( cd "$HOME" && claude plugin marketplace add "$ROOT" >/dev/null 2>&1 ) && ok || fail "marketplace add failed"
  ( cd "$HOME" && claude plugin install agent-mailbox@agent-mailbox >/dev/null 2>&1 ) && ok || fail "plugin install failed"
  cached="$(find "$HOME/.claude/plugins/cache" -path '*/skills/claude/codex-mailbox/SKILL.md' 2>/dev/null | head -1)"
  [ -n "$cached" ] && ok || fail "installed plugin lacks skills/claude/codex-mailbox/SKILL.md"
  details="$(cd "$HOME" && claude plugin details agent-mailbox@agent-mailbox 2>&1)"
  echo "$details" | grep -q "codex-mailbox" && ok || fail "details do not list codex-mailbox: $details"
  echo "$details" | grep -q "claude-mailbox" && fail "Claude plugin exposes the Codex-side skill" || ok
  assert_eq "$(cd "$HOME" && claude plugin list 2>&1 | sed -n 's/^ *Version: *//p' | head -1)" "$TOOL_VERSION" "(installed version)"

  t "install.sh --plugin: CLI + Codex skill symlinks, Claude side via plugin, no duplicate user-level skill"
  export PATH="$HOME/.local/bin:$PATH"; export AGENT_MAILBOX_BACKUP_DIR="$TMP/backups"
  # pre-existing skill symlink from an older install must be retired to avoid a duplicate skill
  mkdir -p "$HOME/.claude/skills"; ln -sfn "$ROOT/skills/claude/codex-mailbox" "$HOME/.claude/skills/codex-mailbox"
  ( cd "$HOME" && "$ROOT/install.sh" --plugin >/dev/null 2>&1 ) && ok || fail "install.sh --plugin failed"
  [ -L "$HOME/.local/bin/agent-mailbox" ] && ok || fail "CLI symlink missing after --plugin"
  [ -L "$HOME/.codex/skills/claude-mailbox" ] && ok || fail "Codex skill symlink missing after --plugin"
  [ ! -e "$HOME/.claude/skills/codex-mailbox" ] && ok || fail "user-level codex-mailbox skill still present (duplicate of plugin skill)"
  ( cd "$HOME" && "$ROOT/install.sh" --check >/dev/null 2>&1 ) && ok || fail "--check does not accept the plugin-mode install"
else
  echo "note: 'claude' CLI not on PATH; plugin validate/install tests skipped"
fi

echo "passed=$PASS failed=$FAIL"
[ "$FAIL" -eq 0 ]
