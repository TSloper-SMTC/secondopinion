#!/bin/bash
# Tests for install.sh — runs against a throwaway HOME. The fast suite uses the
# --skills form (no plugin CLIs); real plugin installs live in test_plugin.sh.
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
PLUGIN="$ROOT/plugins/secondopinion"
PASS=0; FAIL=0; CURRENT=""
t() { CURRENT="$1"; }
ok() { PASS=$((PASS+1)); }
fail() { FAIL=$((FAIL+1)); echo "FAIL [$CURRENT] $*" >&2; }
assert_link() { [ -L "$1" ] && [ "$(readlink -f "$1")" = "$(readlink -f "$2")" ] && ok || fail "$1 is not a symlink to $2"; }
assert_rc() { local want="$1"; shift; "$@" >/dev/null 2>&1; local rc=$?; [ "$rc" = "$want" ] && ok || fail "rc=$rc want=$want: $*"; }
assert_eq() { [ "$1" = "$2" ] && ok || fail "expected '$2' got '$1'"; }

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
export HOME="$TMP/home"; mkdir -p "$HOME"
unset SECONDOPINION_DIR   # install.sh honours the override; these assertions target the default $HOME store
export PATH="$HOME/.local/bin:$PATH"
export SECONDOPINION_BACKUP_DIR="$TMP/backups"

t "--skills install creates the CLI + Codex skill symlinks and touches NOTHING on the Claude side"
assert_rc 0 "$PLUGIN/scripts/install.sh" --skills
assert_link "$HOME/.local/bin/secondopinion" "$PLUGIN/bin/secondopinion"
assert_link "$HOME/.codex/skills/secondopinion-request" "$PLUGIN/skills/secondopinion-request"
[ ! -e "$HOME/.claude" ] && ok || fail "--skills created something under ~/.claude (nothing may be installed in Claude by default)"

t "--skills --claude adds the Claude respond skill; dropping --claude retires it again"
assert_rc 0 "$PLUGIN/scripts/install.sh" --skills --claude
assert_link "$HOME/.claude/skills/secondopinion-respond" "$PLUGIN/skills/secondopinion-respond"
assert_rc 0 "$PLUGIN/scripts/install.sh" --skills --claude --check
assert_rc 0 "$PLUGIN/scripts/install.sh" --skills
[ ! -e "$HOME/.claude/skills/secondopinion-respond" ] && [ ! -L "$HOME/.claude/skills/secondopinion-respond" ] && ok || fail "Claude skill symlink not retired when --claude was dropped"

t "default (Codex plugin) mode requires the codex CLI: fails before any mutation and points at --skills"
DH0="$TMP/home-nocodex"; mkdir -p "$DH0"
out="$(cd "$DH0" && env HOME="$DH0" PATH=/usr/bin:/bin SECONDOPINION_DIR="$DH0/store" "$PLUGIN/scripts/install.sh" 2>&1)"; rc=$?
assert_eq "$rc" 1 "(default mode without codex)"
echo "$out" | grep -q "codex" && ok || fail "error does not name the codex CLI: $out"
echo "$out" | grep -q -- "--skills" && ok || fail "error does not point at --skills: $out"
[ ! -e "$DH0/.local/bin/secondopinion" ] && [ ! -e "$DH0/.codex" ] && [ ! -e "$DH0/store" ] && ok || fail "default mode mutated HOME before the codex prerequisite failed"

t "install is idempotent"
assert_rc 0 "$PLUGIN/scripts/install.sh" --skills
assert_link "$HOME/.local/bin/secondopinion" "$PLUGIN/bin/secondopinion"

t "an existing real directory is backed up, not deleted"
rm "$HOME/.codex/skills/secondopinion-request"
mkdir -p "$HOME/.codex/skills/secondopinion-request"; echo legacy > "$HOME/.codex/skills/secondopinion-request/SKILL.md"
assert_rc 0 "$PLUGIN/scripts/install.sh" --skills
assert_link "$HOME/.codex/skills/secondopinion-request" "$PLUGIN/skills/secondopinion-request"
ls -d "$SECONDOPINION_BACKUP_DIR/secondopinion-request.bak-"* >/dev/null 2>&1 && grep -q legacy "$SECONDOPINION_BACKUP_DIR"/secondopinion-request.bak-*/SKILL.md && ok || fail "legacy dir not backed up under \$SECONDOPINION_BACKUP_DIR"
# the backup must NOT remain anywhere under the skills dir (it would be discovered as a duplicate skill)
[ -z "$(find "$HOME/.codex/skills" -name 'SKILL.md' -path '*bak*' 2>/dev/null)" ] && ok || fail "backup left inside skills dir"

t "--check reports status without changing anything and exits 0 when installed"
assert_rc 0 "$PLUGIN/scripts/install.sh" --check
rm "$HOME/.local/bin/secondopinion"
assert_rc 1 "$PLUGIN/scripts/install.sh" --check
"$PLUGIN/scripts/install.sh" --skills >/dev/null 2>&1
assert_rc 1 env PATH=/usr/bin:/bin "$PLUGIN/scripts/install.sh" --check      # PATH without ~/.local/bin => not installed
assert_rc 0 env PATH=/usr/bin:/bin "$PLUGIN/scripts/install.sh" --skills     # but install itself still succeeds (warns)

t "codex sandbox: install adds writable_roots for the store to ~/.codex/config.toml (created if missing)"
rm -f "$HOME/.codex/config.toml"
assert_rc 0 "$PLUGIN/scripts/install.sh" --skills
grep -q '^\[sandbox_workspace_write\]' "$HOME/.codex/config.toml" && ok || fail "table missing"
grep -q "writable_roots = \[\"$HOME/.secondopinion\"\]" "$HOME/.codex/config.toml" && ok || fail "writable_roots missing"
[ -d "$HOME/.secondopinion" ] && [ "$(stat -c %a "$HOME/.secondopinion")" = "700" ] && ok || fail "store dir not created 0700"

t "codex sandbox: existing config without the table gets the block appended once (idempotent)"
printf 'model = "x"\n[tui]\nfoo = 1\n' > "$HOME/.codex/config.toml"
"$PLUGIN/scripts/install.sh" --skills >/dev/null 2>&1; "$PLUGIN/scripts/install.sh" --skills >/dev/null 2>&1
assert_eq "$(grep -c '^\[sandbox_workspace_write\]' "$HOME/.codex/config.toml")" "1"
grep -q '^model = "x"' "$HOME/.codex/config.toml" && ok || fail "existing config clobbered"
assert_rc 0 "$PLUGIN/scripts/install.sh" --check

t "codex sandbox: table present with a single-line array lacking the store -> install extends it once (backup kept), --check then passes"
printf 'model = "x"\n[sandbox_workspace_write]\nwritable_roots = ["/somewhere/else"]\n' > "$HOME/.codex/config.toml"
assert_rc 0 "$PLUGIN/scripts/install.sh" --skills
assert_eq "$(sed -n 's/^writable_roots = //p' "$HOME/.codex/config.toml")" "[\"/somewhere/else\", \"$HOME/.secondopinion\"]"
grep -q '^model = "x"$' "$HOME/.codex/config.toml" && ok || fail "unrelated config line lost"
ls "$SECONDOPINION_BACKUP_DIR"/config.toml.bak-* >/dev/null 2>&1 && ok || fail "no backup of config.toml before editing"
assert_rc 0 "$PLUGIN/scripts/install.sh" --check
assert_rc 0 "$PLUGIN/scripts/install.sh" --skills
assert_eq "$(grep -o "$HOME/.secondopinion" "$HOME/.codex/config.toml" | wc -l)" "1"

t "installed tool runs through the symlink"
"$PLUGIN/scripts/install.sh" --skills >/dev/null 2>&1
out="$("$HOME/.local/bin/secondopinion" --version)"; [[ "$out" == secondopinion* ]] && ok || fail "version via symlink: '$out'"

t "env: HOME unset gives one clear error, not a bash trace"
out="$(env -u HOME "$PLUGIN/scripts/install.sh" --check 2>&1)"; rc=$?
assert_eq "$rc" 1
echo "$out" | grep -q "unbound variable" && fail "bash trace leaked: $out" || ok
echo "$out" | grep -q "HOME" && ok || fail "error does not mention HOME: $out"

t "unknown or surplus arguments are rejected before anything is installed"
FRESH="$TMP/home-args"; mkdir -p "$FRESH"
assert_rc 1 env HOME="$FRESH" "$PLUGIN/scripts/install.sh" --checkk
[ ! -e "$FRESH/.local/bin/secondopinion" ] && [ ! -e "$FRESH/.codex/config.toml" ] && ok || fail "install.sh --checkk installed something"
assert_rc 1 env HOME="$FRESH" "$PLUGIN/scripts/install.sh" --check extra
assert_rc 1 env HOME="$FRESH" "$PLUGIN/scripts/install.sh" extra
[ ! -e "$FRESH/.local/bin/secondopinion" ] && ok || fail "install.sh with surplus argument installed something"

t "a store path containing a double quote or backslash is refused before any mutation (no malformed TOML)"
QH="$TMP/home-quote"; mkdir -p "$QH"
assert_rc 1 env HOME="$QH" SECONDOPINION_DIR="$TMP/store\"quoted" "$PLUGIN/scripts/install.sh" --skills
[ ! -e "$QH/.codex/config.toml" ] && [ ! -e "$QH/.local/bin/secondopinion" ] && ok || fail "install mutated HOME despite unsafe store path"
assert_rc 1 env HOME="$QH" SECONDOPINION_DIR="$TMP/store\\back" "$PLUGIN/scripts/install.sh" --check
assert_rc 1 env HOME="$QH" SECONDOPINION_DIR="$TMP/store\"quoted" "$PLUGIN/scripts/install.sh" --check

t "--check matches the writable_roots entry as a fixed string, not a regex"
RH="$TMP/home-regex"; mkdir -p "$RH/.codex"
printf '[sandbox_workspace_write]\nwritable_roots = ["%s"]\n' "$TMP/store-XYZ" > "$RH/.codex/config.toml"
out="$(env HOME="$RH" SECONDOPINION_DIR="$TMP/store-X.Z" "$PLUGIN/scripts/install.sh" --check 2>&1)"; rc=$?
assert_eq "$rc" 1
echo "$out" | grep -q "MISSING.*writable_roots\|ACTION" && ok || fail "regex '.' matched a different store path in --check: $out"

t "--check on an empty HOME is side-effect-free (does not let the claude CLI create its config)"
EH="$TMP/home-empty"; mkdir -p "$EH"
before="$(cd "$EH" && find . | sort | md5sum)"
( cd "$EH" && env HOME="$EH" PATH="$EH/.local/bin:$PATH" SECONDOPINION_DIR="$EH/store" "$PLUGIN/scripts/install.sh" --check >/dev/null 2>&1 ); rc=$?
assert_eq "$rc" 1
after="$(cd "$EH" && find . | sort | md5sum)"
[ "$before" = "$after" ] && ok || fail "--check mutated an empty HOME: $(cd "$EH" && find . | head -5 | tr '\n' ' ')"

t "--check requires the store inside the [sandbox_workspace_write] table, not any writable_roots line"
TH2="$TMP/home-toml"; mkdir -p "$TH2/.codex" "$TH2/.local/bin" "$TH2/.claude/skills" "$TH2/.codex/skills"
ln -sfn "$PLUGIN/bin/secondopinion" "$TH2/.local/bin/secondopinion"; ln -sfn "$PLUGIN/skills/secondopinion-respond" "$TH2/.claude/skills/secondopinion-respond"; ln -sfn "$PLUGIN/skills/secondopinion-request" "$TH2/.codex/skills/secondopinion-request"
printf '[unrelated]\nwritable_roots = ["%s"]\n\n[sandbox_workspace_write]\nnetwork_access = true\nwritable_roots = ["/somewhere/else"]\n' "$TH2/.secondopinion" > "$TH2/.codex/config.toml"
( cd "$TH2" && env HOME="$TH2" PATH="$TH2/.local/bin:$PATH" "$PLUGIN/scripts/install.sh" --check >/dev/null 2>&1 ); rc=$?
assert_eq "$rc" 1 "(store only in an unrelated table must not pass)"
printf '[sandbox_workspace_write]\nnetwork_access = true\nwritable_roots = ["/somewhere/else", "%s"]\n' "$TH2/.secondopinion" > "$TH2/.codex/config.toml"
( cd "$TH2" && env HOME="$TH2" PATH="$TH2/.local/bin:$PATH" "$PLUGIN/scripts/install.sh" --check >/dev/null 2>&1 ) && ok || fail "store present in the right table (second array member) must pass"

t "a '|' inside HOME does not corrupt the link table (links land at the right paths)"
PH="$TMP/home|pipe"; mkdir -p "$PH"
( cd "$PH" && env HOME="$PH" PATH="$PH/.local/bin:$PATH" SECONDOPINION_BACKUP_DIR="$TMP/backups" "$PLUGIN/scripts/install.sh" --skills --claude >/dev/null 2>&1 ) && ok || fail "install failed with '|' in HOME"
assert_link "$PH/.local/bin/secondopinion" "$PLUGIN/bin/secondopinion"
assert_link "$PH/.claude/skills/secondopinion-respond" "$PLUGIN/skills/secondopinion-respond"
[ ! -L "$TMP/home" ] && ok || fail "a stray symlink was created outside HOME (pipe split the tuple)"
( cd "$PH" && env HOME="$PH" PATH="$PH/.local/bin:$PATH" "$PLUGIN/scripts/install.sh" --check >/dev/null 2>&1 ) && ok || fail "--check failed with '|' in HOME"

t "backups never clobber each other, even within the same second"
BH2="$TMP/home-bak"; mkdir -p "$BH2/.local/bin"; BK="$TMP/bak-collide"
DSTUB="$TMP/datestub"; mkdir -p "$DSTUB"; printf '#!/bin/bash\nif [ "$1" = "-u" ]; then echo 20260101T000000Z; else exec /bin/date "$@"; fi\n' > "$DSTUB/date"; chmod +x "$DSTUB/date"
echo FIRST-BACKUP > "$BH2/.local/bin/secondopinion"
( cd "$BH2" && env HOME="$BH2" PATH="$DSTUB:$BH2/.local/bin:$PATH" SECONDOPINION_BACKUP_DIR="$BK" "$PLUGIN/scripts/install.sh" --skills >/dev/null 2>&1 ) && ok || fail "first install failed"
rm -f "$BH2/.local/bin/secondopinion"; echo SECOND-BACKUP > "$BH2/.local/bin/secondopinion"
( cd "$BH2" && env HOME="$BH2" PATH="$DSTUB:$BH2/.local/bin:$PATH" SECONDOPINION_BACKUP_DIR="$BK" "$PLUGIN/scripts/install.sh" --skills >/dev/null 2>&1 ) && ok || fail "second install failed"
grep -rl FIRST-BACKUP "$BK" >/dev/null 2>&1 && ok || fail "FIRST-BACKUP was clobbered by a same-second backup"
grep -rl SECOND-BACKUP "$BK" >/dev/null 2>&1 && ok || fail "SECOND-BACKUP missing"

t "--check parses the writable_roots array semantically: a commented-out path does not count, a multiline array does"
TH3="$TMP/home-toml2"; mkdir -p "$TH3/.codex" "$TH3/.local/bin" "$TH3/.claude/skills" "$TH3/.codex/skills"
ln -sfn "$PLUGIN/bin/secondopinion" "$TH3/.local/bin/secondopinion"; ln -sfn "$PLUGIN/skills/secondopinion-respond" "$TH3/.claude/skills/secondopinion-respond"; ln -sfn "$PLUGIN/skills/secondopinion-request" "$TH3/.codex/skills/secondopinion-request"
printf '[sandbox_workspace_write]\nnetwork_access = true\nwritable_roots = ["/not-the-store"] # "%s" only in a comment\n' "$TH3/.secondopinion" > "$TH3/.codex/config.toml"
( cd "$TH3" && env HOME="$TH3" PATH="$TH3/.local/bin:$PATH" "$PLUGIN/scripts/install.sh" --check >/dev/null 2>&1 ); rc=$?
assert_eq "$rc" 1 "(path only in a comment must not pass)"
printf '[sandbox_workspace_write]\nnetwork_access = true\nwritable_roots = [\n  "/first",\n  "%s",\n]\n' "$TH3/.secondopinion" > "$TH3/.codex/config.toml"
( cd "$TH3" && env HOME="$TH3" PATH="$TH3/.local/bin:$PATH" "$PLUGIN/scripts/install.sh" --check >/dev/null 2>&1 ) && ok || fail "multiline array containing the store must pass"

t "default backup directory lives outside the plugin source tree"
DB="$TMP/home-defbak"; mkdir -p "$DB/.local/bin"; echo OLD > "$DB/.local/bin/secondopinion"
( cd "$DB" && env -u SECONDOPINION_BACKUP_DIR HOME="$DB" PATH="$DB/.local/bin:$PATH" "$PLUGIN/scripts/install.sh" --skills >/dev/null 2>&1 ) && ok || fail "install with default backup dir failed"
[ -z "$(find "$ROOT/backups" -newer "$PLUGIN/scripts/install.sh" -type f 2>/dev/null)" ] && ok || fail "a backup was written inside $ROOT/backups"
grep -rl OLD "$DB/.local/state/secondopinion/backups" >/dev/null 2>&1 && ok || fail "backup not found under \$HOME/.local/state/secondopinion/backups"

t "agent-mailbox migration: an old layout is converted (store moved + old path symlinked, old links retired, compat alias, writable_roots extended)"
MH="$TMP/home-migrate"; mkdir -p "$MH/.agent-mailbox/exchanges/2026-01-01T000000Z-keep" "$MH/.agent-mailbox/archive" "$MH/.local/bin" "$MH/.claude/skills" "$MH/.codex/skills" "$MH/.codex"
echo "state=draft" > "$MH/.agent-mailbox/exchanges/2026-01-01T000000Z-keep/meta"
ln -s "/nonexistent/old-repo/bin/agent-mailbox" "$MH/.local/bin/agent-mailbox"          # dangling old CLI link
ln -s "/nonexistent/old-repo/skills/claude/codex-mailbox" "$MH/.claude/skills/codex-mailbox"
ln -s "/nonexistent/old-repo/skills/codex/claude-mailbox" "$MH/.codex/skills/claude-mailbox"
printf '[sandbox_workspace_write]\nwritable_roots = ["%s/.agent-mailbox"]\n' "$MH" > "$MH/.codex/config.toml"
( cd "$MH" && env -u SECONDOPINION_DIR -u AGENT_MAILBOX_DIR HOME="$MH" PATH="$MH/.local/bin:$PATH" SECONDOPINION_BACKUP_DIR="$TMP/backups" "$PLUGIN/scripts/install.sh" --skills --claude >/dev/null 2>&1 ) && ok || fail "install.sh failed on a legacy layout"
[ -d "$MH/.secondopinion/exchanges/2026-01-01T000000Z-keep" ] && ok || fail "store contents were not migrated"
[ -L "$MH/.agent-mailbox" ] && [ "$(readlink -f "$MH/.agent-mailbox")" = "$(readlink -f "$MH/.secondopinion")" ] && ok || fail "old store path is not a symlink to the new store"
assert_link "$MH/.local/bin/secondopinion" "$PLUGIN/bin/secondopinion"
assert_link "$MH/.local/bin/agent-mailbox" "$PLUGIN/bin/secondopinion"                       # deprecated alias
[ ! -e "$MH/.claude/skills/codex-mailbox" ] && [ ! -L "$MH/.claude/skills/codex-mailbox" ] && ok || fail "old Claude skill link not retired"
[ ! -e "$MH/.codex/skills/claude-mailbox" ] && [ ! -L "$MH/.codex/skills/claude-mailbox" ] && ok || fail "old Codex skill link not retired"
assert_link "$MH/.claude/skills/secondopinion-respond" "$PLUGIN/skills/secondopinion-respond"
assert_link "$MH/.codex/skills/secondopinion-request" "$PLUGIN/skills/secondopinion-request"
grep -Fq "\"$MH/.secondopinion\"" "$MH/.codex/config.toml" && ok || fail "new store not added to writable_roots"
grep -Fq "\"$MH/.agent-mailbox\"" "$MH/.codex/config.toml" && fail "symlinked legacy path left in writable_roots (codex bubblewrap cannot enforce .git protection across a symlinked writable root)" || ok
ls "$TMP/backups"/config.toml* >/dev/null 2>&1 && ok || fail "config.toml was edited without a backup"
( cd "$MH" && env -u SECONDOPINION_DIR -u AGENT_MAILBOX_DIR HOME="$MH" PATH="$MH/.local/bin:$PATH" "$PLUGIN/scripts/install.sh" --check >/dev/null 2>&1 ) && ok || fail "--check fails after migration"
# idempotent second run
( cd "$MH" && env -u SECONDOPINION_DIR -u AGENT_MAILBOX_DIR HOME="$MH" PATH="$MH/.local/bin:$PATH" SECONDOPINION_BACKUP_DIR="$TMP/backups" "$PLUGIN/scripts/install.sh" --skills --claude >/dev/null 2>&1 ) && ok || fail "second install.sh run failed"
assert_eq "$(grep -o "$MH/.secondopinion" "$MH/.codex/config.toml" | wc -l)" "1"

t "an existing multi-line writable_roots array is not edited automatically (ACTION), single-line arrays are extended once"
XH="$TMP/home-multiline"; mkdir -p "$XH/.codex" "$XH/.local/bin"
printf '[sandbox_workspace_write]\nwritable_roots = [\n  "/other",\n]\n' > "$XH/.codex/config.toml"
out="$(cd "$XH" && env -u SECONDOPINION_DIR -u AGENT_MAILBOX_DIR HOME="$XH" PATH="$XH/.local/bin:$PATH" SECONDOPINION_BACKUP_DIR="$TMP/backups" "$PLUGIN/scripts/install.sh" --skills 2>&1)"
echo "$out" | grep -q "ACTION" && ok || fail "multi-line array should produce ACTION, got: $out"
grep -Fq "\"$XH/.secondopinion\"" "$XH/.codex/config.toml" && fail "multi-line array was edited automatically" || ok

t "codex sandbox: network_access = true is set so Codex commands can reach Claude; an explicit false is left alone (ACTION)"
NH2="$TMP/home-net"; mkdir -p "$NH2/.local/bin"
( cd "$NH2" && env -u SECONDOPINION_DIR HOME="$NH2" PATH="$NH2/.local/bin:$PATH" SECONDOPINION_BACKUP_DIR="$TMP/backups" "$PLUGIN/scripts/install.sh" --skills >/dev/null 2>&1 ) && ok || fail "install failed (net fixture)"
grep -q '^network_access = true$' "$NH2/.codex/config.toml" && ok || fail "fresh table lacks network_access = true"
( cd "$NH2" && env -u SECONDOPINION_DIR HOME="$NH2" PATH="$NH2/.local/bin:$PATH" "$PLUGIN/scripts/install.sh" --check >/dev/null 2>&1 ) && ok || fail "--check fails on a fresh network-enabled install"
# existing table without the key: added once (backup kept)
NH3="$TMP/home-net2"; mkdir -p "$NH3/.codex" "$NH3/.local/bin"
printf '[sandbox_workspace_write]\nwritable_roots = ["/x"]\n' > "$NH3/.codex/config.toml"
( cd "$NH3" && env -u SECONDOPINION_DIR HOME="$NH3" PATH="$NH3/.local/bin:$PATH" SECONDOPINION_BACKUP_DIR="$TMP/backups" "$PLUGIN/scripts/install.sh" --skills >/dev/null 2>&1 ) && ok || fail "install failed (net fixture 2)"
assert_eq "$(grep -c '^network_access = true$' "$NH3/.codex/config.toml")" "1"
( cd "$NH3" && env -u SECONDOPINION_DIR HOME="$NH3" PATH="$NH3/.local/bin:$PATH" SECONDOPINION_BACKUP_DIR="$TMP/backups" "$PLUGIN/scripts/install.sh" --skills >/dev/null 2>&1 )
assert_eq "$(grep -c '^network_access = true$' "$NH3/.codex/config.toml")" "1"
# explicit false: never flipped, --check reports ACTION and fails
NH4="$TMP/home-net3"; mkdir -p "$NH4/.codex" "$NH4/.local/bin"
printf '[sandbox_workspace_write]\nnetwork_access = false\nwritable_roots = ["/x"]\n' > "$NH4/.codex/config.toml"
out="$(cd "$NH4" && env -u SECONDOPINION_DIR HOME="$NH4" PATH="$NH4/.local/bin:$PATH" SECONDOPINION_BACKUP_DIR="$TMP/backups" "$PLUGIN/scripts/install.sh" --skills 2>&1)"
grep -q '^network_access = false$' "$NH4/.codex/config.toml" && ok || fail "explicit network_access = false was changed"
echo "$out" | grep -q "ACTION" && ok || fail "no ACTION for explicit network_access = false"
( cd "$NH4" && env -u SECONDOPINION_DIR HOME="$NH4" PATH="$NH4/.local/bin:$PATH" "$PLUGIN/scripts/install.sh" --check >/dev/null 2>&1 ); rc=$?
assert_eq "$rc" 1

t "a symlinked legacy store path in writable_roots is removed on install and fails --check (bubblewrap cannot sandbox a symlinked root)"
LH="$TMP/home-symroot"; mkdir -p "$LH/.codex" "$LH/.local/bin" "$LH/.codex/skills" "$LH/.secondopinion"
ln -s "$LH/.secondopinion" "$LH/.agent-mailbox"
ln -sfn "$PLUGIN/bin/secondopinion" "$LH/.local/bin/secondopinion"; ln -sfn "$PLUGIN/skills/secondopinion-request" "$LH/.codex/skills/secondopinion-request"
printf '[sandbox_workspace_write]\nnetwork_access = true\nwritable_roots = ["%s/.agent-mailbox", "%s/.secondopinion"]\n' "$LH" "$LH" > "$LH/.codex/config.toml"
out="$(cd "$LH" && env -u SECONDOPINION_DIR HOME="$LH" PATH="$LH/.local/bin:$PATH" "$PLUGIN/scripts/install.sh" --check 2>&1)"; rc=$?
assert_eq "$rc" 1 "(--check must fail while the symlinked legacy root is listed)"
echo "$out" | grep -q "agent-mailbox" && ok || fail "--check does not name the offending entry: $out"
( cd "$LH" && env -u SECONDOPINION_DIR HOME="$LH" PATH="$LH/.local/bin:$PATH" SECONDOPINION_BACKUP_DIR="$TMP/backups" "$PLUGIN/scripts/install.sh" --skills >/dev/null 2>&1 ) && ok || fail "--skills install failed on the symlinked-root fixture"
grep -Fq "\"$LH/.agent-mailbox\"" "$LH/.codex/config.toml" && fail "legacy symlinked root not removed from writable_roots" || ok
grep -Fq "\"$LH/.secondopinion\"" "$LH/.codex/config.toml" && ok || fail "real store root lost while removing the legacy entry"
( cd "$LH" && env -u SECONDOPINION_DIR HOME="$LH" PATH="$LH/.local/bin:$PATH" "$PLUGIN/scripts/install.sh" --check >/dev/null 2>&1 ) && ok || fail "--check still fails after the legacy root was removed"
# a multi-line array is never edited automatically: ACTION, and --check keeps failing
LH2="$TMP/home-symroot2"; mkdir -p "$LH2/.codex" "$LH2/.local/bin" "$LH2/.codex/skills" "$LH2/.secondopinion"
ln -s "$LH2/.secondopinion" "$LH2/.agent-mailbox"
ln -sfn "$PLUGIN/bin/secondopinion" "$LH2/.local/bin/secondopinion"; ln -sfn "$PLUGIN/skills/secondopinion-request" "$LH2/.codex/skills/secondopinion-request"
printf '[sandbox_workspace_write]\nnetwork_access = true\nwritable_roots = [\n  "%s/.agent-mailbox",\n  "%s/.secondopinion",\n]\n' "$LH2" "$LH2" > "$LH2/.codex/config.toml"
out="$(cd "$LH2" && env -u SECONDOPINION_DIR HOME="$LH2" PATH="$LH2/.local/bin:$PATH" SECONDOPINION_BACKUP_DIR="$TMP/backups" "$PLUGIN/scripts/install.sh" --skills 2>&1)"
echo "$out" | grep -q "ACTION" && ok || fail "multi-line array with the symlinked root should produce ACTION, got: $out"
grep -Fq "\"$LH2/.agent-mailbox\"" "$LH2/.codex/config.toml" && ok || fail "multi-line array was edited automatically"

t "a whitespace-form TOML header '[ sandbox_workspace_write ]' is recognized: extended in place, never duplicated"
WH="$TMP/home-wsheader"; mkdir -p "$WH/.codex" "$WH/.local/bin"
printf 'model = "x"\n[ sandbox_workspace_write ]\nwritable_roots = ["/elsewhere"]\n' > "$WH/.codex/config.toml"
( cd "$WH" && env -u SECONDOPINION_DIR HOME="$WH" PATH="$WH/.local/bin:$PATH" SECONDOPINION_BACKUP_DIR="$TMP/backups" "$PLUGIN/scripts/install.sh" --skills >/dev/null 2>&1 ) && ok || fail "--skills install failed on whitespace header"
assert_eq "$(grep -c 'sandbox_workspace_write' "$WH/.codex/config.toml")" "1" "(no duplicate table appended)"
grep -Fq "\"$WH/.secondopinion\"" "$WH/.codex/config.toml" && ok || fail "store not added to the whitespace-form table"
grep -q 'network_access = true' "$WH/.codex/config.toml" && ok || fail "network_access not set in the whitespace-form table"
( cd "$WH" && env -u SECONDOPINION_DIR HOME="$WH" PATH="$WH/.local/bin:$PATH" "$PLUGIN/scripts/install.sh" --check >/dev/null 2>&1 ) && ok || fail "--check fails on the whitespace-form table"

t "a QUOTED TOML header '[\"sandbox_workspace_write\"]' is recognized: extended in place, never duplicated"
QT="$TMP/home-quoted"; mkdir -p "$QT/.codex" "$QT/.local/bin"
printf '["sandbox_workspace_write"]\nwritable_roots = ["/elsewhere"]\n' > "$QT/.codex/config.toml"
( cd "$QT" && env -u SECONDOPINION_DIR HOME="$QT" PATH="$QT/.local/bin:$PATH" SECONDOPINION_BACKUP_DIR="$TMP/backups" "$PLUGIN/scripts/install.sh" --skills >/dev/null 2>&1 ) && ok || fail "--skills install failed on quoted header"
assert_eq "$(grep -c 'sandbox_workspace_write' "$QT/.codex/config.toml")" "1" "(no duplicate table appended for quoted header)"
grep -Fq "\"$QT/.secondopinion\"" "$QT/.codex/config.toml" && ok || fail "store not added to the quoted-header table"
grep -q 'network_access = true' "$QT/.codex/config.toml" && ok || fail "network_access not set in the quoted-header table"
( cd "$QT" && env -u SECONDOPINION_DIR HOME="$QT" PATH="$QT/.local/bin:$PATH" "$PLUGIN/scripts/install.sh" --check >/dev/null 2>&1 ) && ok || fail "--check fails on the quoted-header table"

t "--uninstall removes the skills-form install and config edits but KEEPS the store"
UH="$TMP/home-uninstall"; mkdir -p "$UH"
( cd "$UH" && env -u SECONDOPINION_DIR HOME="$UH" PATH="$UH/.local/bin:$PATH" "$PLUGIN/scripts/install.sh" --skills --claude >/dev/null 2>&1 ) && ok || fail "fixture install failed"
mkdir -p "$UH/.secondopinion/archive"; echo keep > "$UH/.secondopinion/archive/marker"
assert_rc 0 env -u SECONDOPINION_DIR HOME="$UH" PATH="$UH/.local/bin:$PATH" "$PLUGIN/scripts/install.sh" --uninstall
[ ! -e "$UH/.local/bin/secondopinion" ] && [ ! -L "$UH/.local/bin/secondopinion" ] && ok || fail "CLI symlink not removed"
[ ! -e "$UH/.local/bin/agent-mailbox" ] && [ ! -L "$UH/.local/bin/agent-mailbox" ] && ok || fail "agent-mailbox alias not removed"
[ ! -e "$UH/.codex/skills/secondopinion-request" ] && [ ! -L "$UH/.codex/skills/secondopinion-request" ] && ok || fail "Codex skill symlink not removed"
[ ! -e "$UH/.claude/skills/secondopinion-respond" ] && [ ! -L "$UH/.claude/skills/secondopinion-respond" ] && ok || fail "Claude skill symlink not removed"
grep -q secondopinion "$UH/.codex/config.toml" 2>/dev/null && fail "config.toml still references the store" || ok
grep -q keep "$UH/.secondopinion/archive/marker" && ok || fail "store was not preserved"
assert_rc 1 env -u SECONDOPINION_DIR HOME="$UH" PATH="$UH/.local/bin:$PATH" "$PLUGIN/scripts/install.sh" --check
assert_rc 0 env -u SECONDOPINION_DIR HOME="$UH" PATH="$UH/.local/bin:$PATH" "$PLUGIN/scripts/install.sh" --uninstall

echo "passed=$PASS failed=$FAIL"
[ "$FAIL" -eq 0 ]
