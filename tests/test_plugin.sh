#!/bin/bash
# Tests for the Claude Code / Codex plugin packaging of secondopinion.
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
PLUGIN="$ROOT/plugins/secondopinion"
PASS=0; FAIL=0; CURRENT=""
t() { CURRENT="$1"; }
ok() { PASS=$((PASS+1)); }
fail() { FAIL=$((FAIL+1)); echo "FAIL [$CURRENT] $*" >&2; }
assert_eq() { [ "$1" = "$2" ] && ok || fail "expected '$2' got '$1' ${3:-}"; }
assert_rc() { local want="$1"; shift; "$@" >/dev/null 2>&1; local rc=$?; [ "$rc" = "$want" ] && ok || fail "rc=$rc want=$want: $*"; }
json() { python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); print(eval("d"+sys.argv[2]))' "$1" "$2" 2>/dev/null; }

TOOL_VERSION="$(sed -n 's/^VERSION="\(.*\)"$/\1/p' "$PLUGIN/bin/secondopinion")"

t "manifests exist and parse; names/versions agree with the tool"
for m in plugins/secondopinion/.claude-plugin/plugin.json plugins/secondopinion/.codex-plugin/plugin.json .claude-plugin/marketplace.json .agents/plugins/marketplace.json; do
  python3 -c "import json;json.load(open('$ROOT/$m'))" 2>/dev/null && ok || fail "$m missing or invalid JSON"
done
assert_eq "$(json "$PLUGIN/.claude-plugin/plugin.json" "['name']")" "secondopinion"
assert_eq "$(json "$PLUGIN/.codex-plugin/plugin.json" "['name']")" "secondopinion"
assert_eq "$(json "$PLUGIN/.claude-plugin/plugin.json" "['version']")" "$TOOL_VERSION" "(claude plugin version vs bin VERSION)"
assert_eq "$(json "$PLUGIN/.codex-plugin/plugin.json" "['version']")" "$TOOL_VERSION" "(codex plugin version vs bin VERSION)"
assert_eq "$(json "$ROOT/.claude-plugin/marketplace.json" "['plugins'][0]['version']")" "$TOOL_VERSION" "(marketplace version vs bin VERSION)"
assert_eq "$(json "$ROOT/.claude-plugin/marketplace.json" "['plugins'][0]['name']")" "secondopinion"
assert_eq "$(json "$ROOT/.claude-plugin/marketplace.json" "['plugins'][0]['source']")" "./plugins/secondopinion"
assert_eq "$(json "$ROOT/.agents/plugins/marketplace.json" "['plugins'][0]['source']['path']")" "./plugins/secondopinion"
assert_eq "$(json "$ROOT/.agents/plugins/marketplace.json" "['plugins'][0]['name']")" "secondopinion"

t "each plugin exposes exactly its own side's skill; skill dir names match frontmatter"
[ "$(json "$PLUGIN/.claude-plugin/plugin.json" "['skills']")" = "" ] || [ "$(json "$PLUGIN/.claude-plugin/plugin.json" "['skills']")" = "None" ] && ok || fail "Claude manifest should rely on the default skills/ scan"
[ -f "$PLUGIN/skills/secondopinion-respond/SKILL.md" ] && [ -f "$PLUGIN/skills/secondopinion-request/SKILL.md" ] && ok || fail "skills not at the standard skills/<name>/SKILL.md location"
for d in "$PLUGIN"/skills/*/; do
  name="$(basename "$d")"
  fm="$(sed -n '2,6p' "$d/SKILL.md" | sed -n 's/^name: *//p' | head -1)"
  assert_eq "$fm" "$name" "(frontmatter name vs directory $d)"
done

if command -v claude >/dev/null 2>&1; then
  t "official Codex plugin validator (plugin-creator skill) accepts the plugin, when available"
  CV="$HOME/.codex/skills/.system/plugin-creator/scripts/validate_plugin.py"
  if [ -f "$CV" ]; then python3 "$CV" "$PLUGIN" >/dev/null 2>&1 && ok || fail "Codex validate_plugin.py rejected the plugin: $(python3 "$CV" "$PLUGIN" 2>&1 | tail -3)"; else echo "note: Codex plugin-creator validator not present; skipped"; fi

  t "claude plugin validate accepts plugin and marketplace manifests (strict)"
  assert_rc 0 claude plugin validate --strict "$PLUGIN/.claude-plugin/plugin.json"
  assert_rc 0 claude plugin validate --strict "$ROOT/.claude-plugin/marketplace.json"

  t "throwaway HOME: marketplace add + install work from the local repo and expose both skills from the standard skills/ dir"
  TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
  export HOME="$TMP/home"; mkdir -p "$HOME"
  export CODEX_HOME="$HOME/.codex"; mkdir -p "$CODEX_HOME"     # codex plugin state stays inside the throwaway HOME
  ( cd "$HOME" && claude plugin marketplace add "$ROOT" >/dev/null 2>&1 ) && ok || fail "marketplace add failed"
  ( cd "$HOME" && claude plugin install secondopinion@secondopinion >/dev/null 2>&1 ) && ok || fail "plugin install failed"
  cached="$(find "$HOME/.claude/plugins/cache" -path '*/skills/secondopinion-respond/SKILL.md' 2>/dev/null | head -1)"
  [ -n "$cached" ] && ok || fail "installed plugin lacks skills/secondopinion-respond/SKILL.md"
  details="$(cd "$HOME" && claude plugin details secondopinion@secondopinion 2>&1)"
  echo "$details" | grep -q "secondopinion-respond" && ok || fail "details do not list secondopinion-respond: $details"
  echo "$details" | grep -q "secondopinion-request" && ok || fail "standard skills/ scan should expose secondopinion-request too: $details"
  assert_eq "$(cd "$HOME" && claude plugin list 2>&1 | sed -n 's/^ *Version: *//p' | head -1)" "$TOOL_VERSION" "(installed version)"

  t "install.sh --plugin: CLI + Codex skill symlinks, Claude side via plugin, no duplicate user-level skill"
  export PATH="$HOME/.local/bin:$PATH"; export SECONDOPINION_BACKUP_DIR="$TMP/backups"
  # pre-existing skill symlink from an older install must be retired to avoid a duplicate skill
  mkdir -p "$HOME/.claude/skills"; ln -sfn "$PLUGIN/skills/secondopinion-respond" "$HOME/.claude/skills/secondopinion-respond"
  ( cd "$HOME" && "$PLUGIN/scripts/install.sh" --plugin >/dev/null 2>&1 ) && ok || fail "install.sh --plugin failed"
  [ -L "$HOME/.local/bin/secondopinion" ] && ok || fail "CLI symlink missing after --plugin"
  if command -v codex >/dev/null 2>&1; then
    [ ! -L "$HOME/.codex/skills/secondopinion-request" ] && ok || fail "with the codex CLI present, --plugin must use the Codex plugin, not the skill symlink"
  else
    [ -L "$HOME/.codex/skills/secondopinion-request" ] && ok || fail "Codex skill symlink missing after --plugin (no codex CLI)"
  fi
  [ ! -e "$HOME/.claude/skills/secondopinion-respond" ] && ok || fail "user-level secondopinion-respond skill still present (duplicate of plugin skill)"
  ( cd "$HOME" && "$PLUGIN/scripts/install.sh" --check >/dev/null 2>&1 ) && ok || fail "--check does not accept the plugin-mode install"

  t "install.sh --plugin without the claude CLI fails BEFORE any mutation"
  NH="$TMP/home-noclaude"; mkdir -p "$NH"
  ( cd "$NH" && env HOME="$NH" PATH="/usr/bin:/bin" SECONDOPINION_DIR="$NH/store" "$PLUGIN/scripts/install.sh" --plugin >/dev/null 2>&1 ); rc=$?
  assert_eq "$rc" 1 "(rc --plugin without claude)"
  [ ! -e "$NH/.local/bin/secondopinion" ] && [ ! -e "$NH/.codex" ] && [ ! -e "$NH/store" ] && ok || fail "--plugin mutated HOME before the claude prerequisite failed"

  t "install.sh --plugin repairs a stale marketplace/older plugin and verifies version + enabled; --check is state-aware"
  SH="$TMP/home-stale"; mkdir -p "$SH"; OLD="$TMP/old-copy"; cp -r "$ROOT" "$OLD"; rm -rf "$OLD/.git"
  for f in plugins/secondopinion/bin/secondopinion plugins/secondopinion/.claude-plugin/plugin.json plugins/secondopinion/.codex-plugin/plugin.json .claude-plugin/marketplace.json .agents/plugins/marketplace.json; do sed -i "s/$TOOL_VERSION/1.0.0/g" "$OLD/$f"; done
  ( cd "$SH" && HOME="$SH" claude plugin marketplace add "$OLD" >/dev/null 2>&1 && HOME="$SH" claude plugin install secondopinion@secondopinion >/dev/null 2>&1 ) && ok || fail "could not seed the older install"
  assert_eq "$(cd "$SH" && HOME="$SH" claude plugin list 2>&1 | sed -n 's/^ *Version: *//p' | head -1)" "1.0.0" "(seeded older version)"
  rm -rf "$OLD"                                                     # stale marketplace source
  ( cd "$SH" && HOME="$SH" PATH="$SH/.local/bin:$PATH" SECONDOPINION_BACKUP_DIR="$TMP/backups" "$PLUGIN/scripts/install.sh" --check >/dev/null 2>&1 ); rc=$?
  assert_eq "$rc" 1 "(--check must not accept a stale/older plugin)"
  ( cd "$SH" && HOME="$SH" PATH="$SH/.local/bin:$PATH" SECONDOPINION_BACKUP_DIR="$TMP/backups" "$PLUGIN/scripts/install.sh" --plugin >/dev/null 2>&1 ) && ok || fail "install.sh --plugin failed to repair a stale marketplace"
  assert_eq "$(cd "$SH" && HOME="$SH" claude plugin marketplace list --json 2>/dev/null | python3 -c 'import json,sys; print([m["path"] for m in json.load(sys.stdin) if m["name"]=="secondopinion"][0])')" "$ROOT" "(marketplace path repointed to ROOT)"
  assert_eq "$(cd "$SH" && HOME="$SH" claude plugin list --json 2>/dev/null | python3 -c 'import json,sys; p=[x for x in json.load(sys.stdin) if x["id"]=="secondopinion@secondopinion"][0]; print(p["version"], p["enabled"])')" "$TOOL_VERSION True" "(version + enabled after repair)"
  ( cd "$SH" && HOME="$SH" PATH="$SH/.local/bin:$PATH" "$PLUGIN/scripts/install.sh" --check >/dev/null 2>&1 ) && ok || fail "--check rejects a correct plugin install"
  # a disabled plugin is not an installed one: --check fails, --plugin re-enables
  ( cd "$SH" && HOME="$SH" claude plugin disable --scope user secondopinion@secondopinion >/dev/null 2>&1 )
  ( cd "$SH" && HOME="$SH" PATH="$SH/.local/bin:$PATH" "$PLUGIN/scripts/install.sh" --check >/dev/null 2>&1 ); rc=$?
  assert_eq "$rc" 1 "(--check must not accept a disabled plugin)"
  ( cd "$SH" && HOME="$SH" PATH="$SH/.local/bin:$PATH" SECONDOPINION_BACKUP_DIR="$TMP/backups" "$PLUGIN/scripts/install.sh" --plugin >/dev/null 2>&1 ) && ok || fail "install.sh --plugin failed on a disabled plugin"
  assert_eq "$(cd "$SH" && HOME="$SH" claude plugin list --json 2>/dev/null | python3 -c 'import json,sys; print([x["enabled"] for x in json.load(sys.stdin) if x["id"]=="secondopinion@secondopinion"][0])')" "True" "(re-enabled)"

  t "switching plugin -> skill mode is symmetric: plain install.sh removes the plugin; --check rejects a duplicate state"
  XH="$TMP/home-switch"; mkdir -p "$XH"
  ( cd "$XH" && HOME="$XH" PATH="$XH/.local/bin:$PATH" SECONDOPINION_BACKUP_DIR="$TMP/backups" "$PLUGIN/scripts/install.sh" --plugin >/dev/null 2>&1 ) && ok || fail "--plugin failed in switch fixture"
  ( cd "$XH" && HOME="$XH" PATH="$XH/.local/bin:$PATH" SECONDOPINION_BACKUP_DIR="$TMP/backups" "$PLUGIN/scripts/install.sh" >/dev/null 2>&1 ) && ok || fail "plain install.sh failed after --plugin"
  [ -L "$XH/.claude/skills/secondopinion-respond" ] && ok || fail "skill symlink missing after switching back to skill mode"
  assert_eq "$(cd "$XH" && HOME="$XH" claude plugin list --json 2>/dev/null | python3 -c 'import json,sys; print(len([x for x in json.load(sys.stdin) if x["id"]=="secondopinion@secondopinion"]))')" "0" "(plugin removed when switching to skill mode)"
  ( cd "$XH" && HOME="$XH" PATH="$XH/.local/bin:$PATH" "$PLUGIN/scripts/install.sh" --check >/dev/null 2>&1 ) && ok || fail "--check rejects a clean skill-mode install after the switch"
  # force a duplicate: skill symlink present AND plugin installed -> --check must fail and name it
  ( cd "$XH" && HOME="$XH" claude plugin install secondopinion@secondopinion >/dev/null 2>&1 )
  out="$(cd "$XH" && HOME="$XH" PATH="$XH/.local/bin:$PATH" "$PLUGIN/scripts/install.sh" --check 2>&1)"; rc=$?
  assert_eq "$rc" 1 "(--check must reject skill symlink + plugin both active)"
  echo "$out" | grep -qi "duplicate\|both" && ok || fail "--check does not name the duplicate state: $out"

  t "plugin inspection fails CLOSED: a broken claude CLI (nonzero exit / malformed JSON) blocks skill-mode mutation and --check"
  BH="$TMP/home-broken"; mkdir -p "$BH"
  ( cd "$BH" && HOME="$BH" PATH="$BH/.local/bin:$PATH" SECONDOPINION_BACKUP_DIR="$TMP/backups" "$PLUGIN/scripts/install.sh" --plugin >/dev/null 2>&1 ) && ok || fail "--plugin failed in broken-cli fixture"
  STUB="$TMP/stubbin"; mkdir -p "$STUB"; printf '#!/bin/bash\nexit 47\n' > "$STUB/claude"; chmod +x "$STUB/claude"
  ( cd "$BH" && HOME="$BH" PATH="$STUB:$BH/.local/bin:$PATH" SECONDOPINION_BACKUP_DIR="$TMP/backups" "$PLUGIN/scripts/install.sh" >/dev/null 2>&1 ); rc=$?
  assert_eq "$rc" 1 "(skill mode must refuse when plugin state cannot be inspected)"
  [ ! -e "$BH/.claude/skills/secondopinion-respond" ] && ok || fail "skill symlink was created although the plugin state was uninspectable (duplicate risk)"
  ( cd "$BH" && HOME="$BH" PATH="$STUB:$BH/.local/bin:$PATH" "$PLUGIN/scripts/install.sh" --check >/dev/null 2>&1 ); rc=$?
  assert_eq "$rc" 1 "(--check must fail when plugin state cannot be inspected)"
  printf '#!/bin/bash\necho "not json"\n' > "$STUB/claude"      # malformed JSON variant
  ( cd "$BH" && HOME="$BH" PATH="$STUB:$BH/.local/bin:$PATH" "$PLUGIN/scripts/install.sh" --check >/dev/null 2>&1 ); rc=$?
  assert_eq "$rc" 1 "(--check must fail on malformed plugin JSON)"
  # with the real CLI back, the state is still a clean plugin install
  ( cd "$BH" && HOME="$BH" PATH="$BH/.local/bin:$PATH" "$PLUGIN/scripts/install.sh" --check >/dev/null 2>&1 ) && ok || fail "real CLI --check failed after the broken-cli attempts"

  t "duplicate detection: a REAL directory at ~/.claude/skills/secondopinion-respond next to a current plugin fails --check"
  DH="$TMP/home-realdir"; mkdir -p "$DH"
  ( cd "$DH" && HOME="$DH" PATH="$DH/.local/bin:$PATH" SECONDOPINION_BACKUP_DIR="$TMP/backups" "$PLUGIN/scripts/install.sh" --plugin >/dev/null 2>&1 ) && ok || fail "--plugin failed in realdir fixture"
  mkdir -p "$DH/.claude/skills/secondopinion-respond"; echo legacy > "$DH/.claude/skills/secondopinion-respond/SKILL.md"
  ( cd "$DH" && HOME="$DH" PATH="$DH/.local/bin:$PATH" "$PLUGIN/scripts/install.sh" --check >/dev/null 2>&1 ); rc=$?
  assert_eq "$rc" 1 "(real skill dir + plugin must be a duplicate)"

  t "plugin -> skill switch: the skill symlink is created only after the plugin is confirmed absent by a successful re-inspection"
  SH2="$TMP/home-stateful"; mkdir -p "$SH2"
  ( cd "$SH2" && HOME="$SH2" PATH="$SH2/.local/bin:$PATH" SECONDOPINION_BACKUP_DIR="$TMP/backups" "$PLUGIN/scripts/install.sh" --plugin >/dev/null 2>&1 ) && ok || fail "--plugin failed in stateful fixture"
  REAL_CLAUDE="$(command -v claude)"; SSTUB="$TMP/stateful-stub"; mkdir -p "$SSTUB"
  # stub: passes every call through to the real CLI, except that after an uninstall it makes the next `plugin list --json` fail
  cat > "$SSTUB/claude" <<STUB
#!/bin/bash
flag="$SSTUB/after-uninstall"
if [ "\$1 \$2" = "plugin uninstall" ]; then touch "\$flag"; exec "$REAL_CLAUDE" "\$@"; fi
if [ "\$1 \$2 \$3" = "plugin list --json" ] && [ -e "\$flag" ]; then rm -f "\$flag"; exit 47; fi
exec "$REAL_CLAUDE" "\$@"
STUB
  chmod +x "$SSTUB/claude"
  ( cd "$SH2" && HOME="$SH2" PATH="$SSTUB:$SH2/.local/bin:$PATH" SECONDOPINION_BACKUP_DIR="$TMP/backups" "$PLUGIN/scripts/install.sh" >/dev/null 2>&1 ); rc=$?
  assert_eq "$rc" 1 "(switch must fail when the post-uninstall re-inspection fails)"
  [ ! -e "$SH2/.claude/skills/secondopinion-respond" ] && ok || fail "skill symlink created although the plugin's absence was not confirmed"
  # a real retry recovers
  ( cd "$SH2" && HOME="$SH2" PATH="$SH2/.local/bin:$PATH" SECONDOPINION_BACKUP_DIR="$TMP/backups" "$PLUGIN/scripts/install.sh" >/dev/null 2>&1 ) && ok || fail "real retry of skill mode failed"
  ( cd "$SH2" && HOME="$SH2" PATH="$SH2/.local/bin:$PATH" "$PLUGIN/scripts/install.sh" --check >/dev/null 2>&1 ) && ok || fail "--check after recovery failed"

  t "schema-invalid plugin JSON (enabled as a string, non-list) is treated as uninspectable, not as enabled"
  JH="$TMP/home-schema"; mkdir -p "$JH"
  ( cd "$JH" && HOME="$JH" PATH="$JH/.local/bin:$PATH" SECONDOPINION_BACKUP_DIR="$TMP/backups" "$PLUGIN/scripts/install.sh" --plugin >/dev/null 2>&1 ) && ok || fail "--plugin failed in schema fixture"
  ( cd "$JH" && HOME="$JH" claude plugin disable --scope user secondopinion@secondopinion >/dev/null 2>&1 )
  JSTUB="$TMP/schema-stub"; mkdir -p "$JSTUB"
  cat > "$JSTUB/claude" <<STUB
#!/bin/bash
if [ "\$1 \$2 \$3" = "plugin list --json" ]; then printf '[{"id":"secondopinion@secondopinion","version":"$TOOL_VERSION","enabled":"false"}]\n'; exit 0; fi
exec "$REAL_CLAUDE" "\$@"
STUB
  chmod +x "$JSTUB/claude"
  ( cd "$JH" && HOME="$JH" PATH="$JSTUB:$JH/.local/bin:$PATH" "$PLUGIN/scripts/install.sh" --check >/dev/null 2>&1 ); rc=$?
  assert_eq "$rc" 1 "(--check must not approve a string-typed enabled field)"
  cat > "$JSTUB/claude" <<STUB
#!/bin/bash
if [ "\$1 \$2 \$3" = "plugin list --json" ]; then printf '{"id":"secondopinion@secondopinion"}\n'; exit 0; fi
exec "$REAL_CLAUDE" "\$@"
STUB
  ( cd "$JH" && HOME="$JH" PATH="$JSTUB:$JH/.local/bin:$PATH" "$PLUGIN/scripts/install.sh" --check >/dev/null 2>&1 ); rc=$?
  assert_eq "$rc" 1 "(--check must not approve a non-list plugin JSON)"

  if command -v codex >/dev/null 2>&1; then
    t "install.sh --plugin also installs the Codex plugin from the repo marketplace (no Codex skill symlink); --check accepts it; skill mode removes it"
    CH="$TMP/home-codex"; mkdir -p "$CH"
    ( cd "$CH" && HOME="$CH" CODEX_HOME="$CH/.codex" PATH="$CH/.local/bin:$PATH" SECONDOPINION_BACKUP_DIR="$TMP/backups" "$PLUGIN/scripts/install.sh" --plugin >/dev/null 2>&1 ) && ok || fail "--plugin failed in codex fixture"
    st="$(cd "$CH" && HOME="$CH" CODEX_HOME="$CH/.codex" codex plugin list --json 2>/dev/null | python3 -c 'import json,sys; d=json.load(sys.stdin); p=[x for x in d.get("installed",[]) if x.get("pluginId")=="secondopinion@secondopinion"]; print(p[0]["version"], p[0]["enabled"], p[0]["marketplaceSource"]["source"]) if p else print("absent")')"
    assert_eq "$st" "$TOOL_VERSION True $ROOT" "(codex plugin installed+enabled from the repo marketplace)"
    [ ! -e "$CH/.codex/skills/secondopinion-request" ] && [ ! -L "$CH/.codex/skills/secondopinion-request" ] && ok || fail "Codex skill symlink should not exist in plugin mode"
    ( cd "$CH" && HOME="$CH" CODEX_HOME="$CH/.codex" PATH="$CH/.local/bin:$PATH" "$PLUGIN/scripts/install.sh" --check >/dev/null 2>&1 ) && ok || fail "--check rejects a correct dual plugin install"
    ( cd "$CH" && HOME="$CH" CODEX_HOME="$CH/.codex" PATH="$CH/.local/bin:$PATH" SECONDOPINION_BACKUP_DIR="$TMP/backups" "$PLUGIN/scripts/install.sh" >/dev/null 2>&1 ) && ok || fail "skill mode after --plugin failed"
    st="$(cd "$CH" && HOME="$CH" CODEX_HOME="$CH/.codex" codex plugin list --json 2>/dev/null | python3 -c 'import json,sys; d=json.load(sys.stdin); print(len([x for x in d.get("installed",[]) if x.get("pluginId")=="secondopinion@secondopinion"]))')"
    assert_eq "$st" "0" "(codex plugin removed when switching to skill mode)"
    [ -L "$CH/.codex/skills/secondopinion-request" ] && ok || fail "Codex skill symlink missing in skill mode"
    ( cd "$CH" && HOME="$CH" CODEX_HOME="$CH/.codex" PATH="$CH/.local/bin:$PATH" "$PLUGIN/scripts/install.sh" --check >/dev/null 2>&1 ) && ok || fail "--check rejects a correct skill-mode install (codex fixture)"
    # duplicate on the Codex side: skill symlink + plugin installed by hand -> --check fails naming DUPLICATE
    ( cd "$CH" && HOME="$CH" CODEX_HOME="$CH/.codex" codex plugin add secondopinion@secondopinion >/dev/null 2>&1 )
    out="$(cd "$CH" && HOME="$CH" CODEX_HOME="$CH/.codex" PATH="$CH/.local/bin:$PATH" "$PLUGIN/scripts/install.sh" --check 2>&1)"; rc=$?
    assert_eq "$rc" 1 "(--check must reject Codex skill symlink + Codex plugin both active)"
    echo "$out" | grep -qi "duplicate" && ok || fail "--check does not name the Codex duplicate: $out"
  else
    echo "note: 'codex' CLI not on PATH; Codex plugin-mode tests skipped"
  fi
else
  echo "note: 'claude' CLI not on PATH; plugin validate/install tests skipped"
fi

echo "passed=$PASS failed=$FAIL"
[ "$FAIL" -eq 0 ]
