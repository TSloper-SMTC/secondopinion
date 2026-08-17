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

  t "install.sh --plugin without the claude CLI fails BEFORE any mutation"
  NH="$TMP/home-noclaude"; mkdir -p "$NH"
  ( cd "$NH" && env HOME="$NH" PATH="/usr/bin:/bin" AGENT_MAILBOX_DIR="$NH/store" "$ROOT/install.sh" --plugin >/dev/null 2>&1 ); rc=$?
  assert_eq "$rc" 1 "(rc --plugin without claude)"
  [ ! -e "$NH/.local/bin/agent-mailbox" ] && [ ! -e "$NH/.codex" ] && [ ! -e "$NH/store" ] && ok || fail "--plugin mutated HOME before the claude prerequisite failed"

  t "install.sh --plugin repairs a stale marketplace/older plugin and verifies version + enabled; --check is state-aware"
  SH="$TMP/home-stale"; mkdir -p "$SH"; OLD="$TMP/old-copy"; cp -r "$ROOT" "$OLD"; rm -rf "$OLD/.git"
  for f in bin/agent-mailbox .claude-plugin/plugin.json .codex-plugin/plugin.json .claude-plugin/marketplace.json; do sed -i "s/$TOOL_VERSION/1.0.0/g" "$OLD/$f"; done
  ( cd "$SH" && HOME="$SH" claude plugin marketplace add "$OLD" >/dev/null 2>&1 && HOME="$SH" claude plugin install agent-mailbox@agent-mailbox >/dev/null 2>&1 ) && ok || fail "could not seed the older install"
  assert_eq "$(cd "$SH" && HOME="$SH" claude plugin list 2>&1 | sed -n 's/^ *Version: *//p' | head -1)" "1.0.0" "(seeded older version)"
  rm -rf "$OLD"                                                     # stale marketplace source
  ( cd "$SH" && HOME="$SH" PATH="$SH/.local/bin:$PATH" AGENT_MAILBOX_BACKUP_DIR="$TMP/backups" "$ROOT/install.sh" --check >/dev/null 2>&1 ); rc=$?
  assert_eq "$rc" 1 "(--check must not accept a stale/older plugin)"
  ( cd "$SH" && HOME="$SH" PATH="$SH/.local/bin:$PATH" AGENT_MAILBOX_BACKUP_DIR="$TMP/backups" "$ROOT/install.sh" --plugin >/dev/null 2>&1 ) && ok || fail "install.sh --plugin failed to repair a stale marketplace"
  assert_eq "$(cd "$SH" && HOME="$SH" claude plugin marketplace list --json 2>/dev/null | python3 -c 'import json,sys; print([m["path"] for m in json.load(sys.stdin) if m["name"]=="agent-mailbox"][0])')" "$ROOT" "(marketplace path repointed to ROOT)"
  assert_eq "$(cd "$SH" && HOME="$SH" claude plugin list --json 2>/dev/null | python3 -c 'import json,sys; p=[x for x in json.load(sys.stdin) if x["id"]=="agent-mailbox@agent-mailbox"][0]; print(p["version"], p["enabled"])')" "$TOOL_VERSION True" "(version + enabled after repair)"
  ( cd "$SH" && HOME="$SH" PATH="$SH/.local/bin:$PATH" "$ROOT/install.sh" --check >/dev/null 2>&1 ) && ok || fail "--check rejects a correct plugin install"
  # a disabled plugin is not an installed one: --check fails, --plugin re-enables
  ( cd "$SH" && HOME="$SH" claude plugin disable --scope user agent-mailbox@agent-mailbox >/dev/null 2>&1 )
  ( cd "$SH" && HOME="$SH" PATH="$SH/.local/bin:$PATH" "$ROOT/install.sh" --check >/dev/null 2>&1 ); rc=$?
  assert_eq "$rc" 1 "(--check must not accept a disabled plugin)"
  ( cd "$SH" && HOME="$SH" PATH="$SH/.local/bin:$PATH" AGENT_MAILBOX_BACKUP_DIR="$TMP/backups" "$ROOT/install.sh" --plugin >/dev/null 2>&1 ) && ok || fail "install.sh --plugin failed on a disabled plugin"
  assert_eq "$(cd "$SH" && HOME="$SH" claude plugin list --json 2>/dev/null | python3 -c 'import json,sys; print([x["enabled"] for x in json.load(sys.stdin) if x["id"]=="agent-mailbox@agent-mailbox"][0])')" "True" "(re-enabled)"

  t "switching plugin -> skill mode is symmetric: plain install.sh removes the plugin; --check rejects a duplicate state"
  XH="$TMP/home-switch"; mkdir -p "$XH"
  ( cd "$XH" && HOME="$XH" PATH="$XH/.local/bin:$PATH" AGENT_MAILBOX_BACKUP_DIR="$TMP/backups" "$ROOT/install.sh" --plugin >/dev/null 2>&1 ) && ok || fail "--plugin failed in switch fixture"
  ( cd "$XH" && HOME="$XH" PATH="$XH/.local/bin:$PATH" AGENT_MAILBOX_BACKUP_DIR="$TMP/backups" "$ROOT/install.sh" >/dev/null 2>&1 ) && ok || fail "plain install.sh failed after --plugin"
  [ -L "$XH/.claude/skills/codex-mailbox" ] && ok || fail "skill symlink missing after switching back to skill mode"
  assert_eq "$(cd "$XH" && HOME="$XH" claude plugin list --json 2>/dev/null | python3 -c 'import json,sys; print(len([x for x in json.load(sys.stdin) if x["id"]=="agent-mailbox@agent-mailbox"]))')" "0" "(plugin removed when switching to skill mode)"
  ( cd "$XH" && HOME="$XH" PATH="$XH/.local/bin:$PATH" "$ROOT/install.sh" --check >/dev/null 2>&1 ) && ok || fail "--check rejects a clean skill-mode install after the switch"
  # force a duplicate: skill symlink present AND plugin installed -> --check must fail and name it
  ( cd "$XH" && HOME="$XH" claude plugin install agent-mailbox@agent-mailbox >/dev/null 2>&1 )
  out="$(cd "$XH" && HOME="$XH" PATH="$XH/.local/bin:$PATH" "$ROOT/install.sh" --check 2>&1)"; rc=$?
  assert_eq "$rc" 1 "(--check must reject skill symlink + plugin both active)"
  echo "$out" | grep -qi "duplicate\|both" && ok || fail "--check does not name the duplicate state: $out"

  t "plugin inspection fails CLOSED: a broken claude CLI (nonzero exit / malformed JSON) blocks skill-mode mutation and --check"
  BH="$TMP/home-broken"; mkdir -p "$BH"
  ( cd "$BH" && HOME="$BH" PATH="$BH/.local/bin:$PATH" AGENT_MAILBOX_BACKUP_DIR="$TMP/backups" "$ROOT/install.sh" --plugin >/dev/null 2>&1 ) && ok || fail "--plugin failed in broken-cli fixture"
  STUB="$TMP/stubbin"; mkdir -p "$STUB"; printf '#!/bin/bash\nexit 47\n' > "$STUB/claude"; chmod +x "$STUB/claude"
  ( cd "$BH" && HOME="$BH" PATH="$STUB:$BH/.local/bin:$PATH" AGENT_MAILBOX_BACKUP_DIR="$TMP/backups" "$ROOT/install.sh" >/dev/null 2>&1 ); rc=$?
  assert_eq "$rc" 1 "(skill mode must refuse when plugin state cannot be inspected)"
  [ ! -e "$BH/.claude/skills/codex-mailbox" ] && ok || fail "skill symlink was created although the plugin state was uninspectable (duplicate risk)"
  ( cd "$BH" && HOME="$BH" PATH="$STUB:$BH/.local/bin:$PATH" "$ROOT/install.sh" --check >/dev/null 2>&1 ); rc=$?
  assert_eq "$rc" 1 "(--check must fail when plugin state cannot be inspected)"
  printf '#!/bin/bash\necho "not json"\n' > "$STUB/claude"      # malformed JSON variant
  ( cd "$BH" && HOME="$BH" PATH="$STUB:$BH/.local/bin:$PATH" "$ROOT/install.sh" --check >/dev/null 2>&1 ); rc=$?
  assert_eq "$rc" 1 "(--check must fail on malformed plugin JSON)"
  # with the real CLI back, the state is still a clean plugin install
  ( cd "$BH" && HOME="$BH" PATH="$BH/.local/bin:$PATH" "$ROOT/install.sh" --check >/dev/null 2>&1 ) && ok || fail "real CLI --check failed after the broken-cli attempts"
else
  echo "note: 'claude' CLI not on PATH; plugin validate/install tests skipped"
fi

echo "passed=$PASS failed=$FAIL"
[ "$FAIL" -eq 0 ]
