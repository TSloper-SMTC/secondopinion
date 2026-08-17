#!/bin/bash
# install.sh — link the secondopinion tool and skills into the user's home.
#   install.sh           skill mode: symlink the CLI and BOTH skills (Claude skill = /secondopinion-respond)
#   install.sh --plugin  plugin mode: symlink the CLI and the Codex skill; install the Claude side as
#                        the Claude Code plugin secondopinion@secondopinion (/secondopinion:secondopinion-respond)
#                        via `claude plugin marketplace add` + `claude plugin install`, and retire a
#                        user-level ~/.claude/skills/secondopinion-respond symlink so the skill is not duplicated
#   install.sh --check   report status; exit 0 if fully installed (either mode), 1 otherwise
set -euo pipefail

if [ -z "${HOME:-}" ]; then
    echo "ERROR: HOME is not set; cannot locate ~/.local/bin, ~/.claude/skills or ~/.codex/skills." >&2
    exit 1
fi
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VERSION="$(sed -n 's/^VERSION="\(.*\)"$/\1/p' "$ROOT/bin/secondopinion")"
# Backups of replaced real dirs/files go OUTSIDE the skills trees (a backed-up SKILL.md would be
# discovered as a duplicate skill) and OUTSIDE the plugin source (a plugin install copies the tree).
[ -z "${SECONDOPINION_BACKUP_DIR:-}" ] && [ -n "${AGENT_MAILBOX_BACKUP_DIR:-}" ] && SECONDOPINION_BACKUP_DIR="$AGENT_MAILBOX_BACKUP_DIR"
[ -z "${SECONDOPINION_DIR:-}" ] && [ -n "${AGENT_MAILBOX_DIR:-}" ] && SECONDOPINION_DIR="$AGENT_MAILBOX_DIR"
BACKUP_DIR="${SECONDOPINION_BACKUP_DIR:-$HOME/.local/state/secondopinion/backups}"
backup_path() { # basename -> a fresh, non-clobbering path under BACKUP_DIR (same-second safe)
    local base="$BACKUP_DIR/$1.bak-$(date -u +%Y%m%dT%H%M%SZ)" cand n=1
    cand="$base"
    while [ -e "$cand" ] || [ -L "$cand" ]; do cand="$base-$n"; n=$((n+1)); done
    echo "$cand"
}
CHECK=0; PLUGIN=0
case "$#:${1:-}" in
    0:) ;;
    1:--check) CHECK=1;;
    1:--plugin) PLUGIN=1;;
    1:-h|1:--help) sed -n '2,8p' "$0"; exit 0;;
    *) echo "usage: install.sh [--check|--plugin]   (unknown or surplus argument: '$*')" >&2; exit 1;;
esac
PLUGIN_ID="secondopinion@secondopinion"
MARKETPLACE="secondopinion"
CLAUDE_SKILL_LINK="$HOME/.claude/skills/secondopinion-respond"
STORE_DIR="${SECONDOPINION_DIR:-$HOME/.secondopinion}"
OLD_STORE="$HOME/.agent-mailbox"                       # 1.x store; migrated once (see below)
CODEX_CFG="$HOME/.codex/config.toml"

# ---- every precondition is checked BEFORE any mutation ------------------------------------
# The store path is written into TOML as a quoted string: refuse anything that
# cannot be represented verbatim (quotes, backslashes, control characters).
case "$STORE_DIR" in
    *[\"\\]*|*[[:cntrl:]]*) printf 'ERROR: store path %q contains a quote, backslash or control character; choose another SECONDOPINION_DIR.\n' "$STORE_DIR" >&2; exit 1;;
esac
have_claude() { command -v claude >/dev/null 2>&1 && command -v python3 >/dev/null 2>&1; }
if [ "$PLUGIN" = 1 ] && ! have_claude; then
    echo "ERROR: --plugin needs the 'claude' CLI and python3 on PATH (nothing was installed)." >&2; exit 1
fi

# ---- Codex sandbox config: semantic membership of the store in
# [sandbox_workspace_write].writable_roots (comments and multiline arrays handled) ------------
store_in_sandbox_roots() {
    if command -v python3 >/dev/null 2>&1; then
        python3 - "$CODEX_CFG" "$STORE_DIR" <<'PY'
import re, sys
path, store = sys.argv[1], sys.argv[2]
def strip_comment(line):
    out, q = [], False
    i = 0
    while i < len(line):
        c = line[i]
        if q:
            out.append(c)
            if c == "\\" and i + 1 < len(line): out.append(line[i+1]); i += 2; continue
            if c == '"': q = False
        else:
            if c == "#": break
            out.append(c)
            if c == '"': q = True
        i += 1
    return "".join(out)
table, buf, roots = None, None, None
try:
    for raw in open(path, encoding="utf-8", errors="replace"):
        line = strip_comment(raw.rstrip("\n"))
        if buf is not None:
            buf += " " + line
            if "]" in line: roots = buf; buf = None
            continue
        m = re.match(r"^\s*\[\s*([^\]]+?)\s*\]\s*$", line)
        if m: table = m.group(1).strip(); continue
        if table == "sandbox_workspace_write":
            m = re.match(r"^\s*writable_roots\s*=\s*(.*)$", line)
            if m:
                rest = m.group(1)
                if "]" in rest: roots = rest
                else: buf = rest
    if roots is None: sys.exit(1)
    vals = [v.encode().decode("unicode_escape") if "\\" in v else v for v in re.findall(r'"((?:[^"\\]|\\.)*)"', roots)]
    sys.exit(0 if store in vals else 1)
except Exception:
    sys.exit(1)
PY
    else  # degraded textual check when python3 is unavailable
        awk '/^\[sandbox_workspace_write\]/{f=1; next} /^\[/{f=0} f' "$CODEX_CFG" | grep -E '^writable_roots *=' | grep -Fq "\"$STORE_DIR\""
    fi
}

# Extend a SINGLE-LINE `writable_roots = [...]` in [sandbox_workspace_write] with the store
# (backing the file up first). Anything else (multi-line array, odd formatting) is left for the
# user (ACTION) — the file is theirs.
extend_sandbox_roots() {
    command -v python3 >/dev/null 2>&1 || return 1
    mkdir -p "$BACKUP_DIR"; local bak; bak="$(backup_path config.toml)"
    cp -p -- "$CODEX_CFG" "$bak" || return 1
    python3 - "$CODEX_CFG" "$STORE_DIR" <<'PY' || { rm -f -- "$bak"; return 1; }
import re, sys
path, store = sys.argv[1], sys.argv[2]
lines = open(path, encoding="utf-8").read().split("\n")
table = None; done = False
for i, line in enumerate(lines):
    m = re.match(r"^\s*\[\s*([^\]]+?)\s*\]\s*$", line)
    if m: table = m.group(1).strip(); continue
    if table != "sandbox_workspace_write": continue
    m = re.match(r'^(\s*writable_roots\s*=\s*\[)(.*)(\]\s*(#.*)?)$', line)
    if not m: continue
    inner = m.group(2).strip()
    entry = '"' + store + '"'
    inner = (inner.rstrip(",") + ", " + entry) if inner else entry
    lines[i] = m.group(1) + inner + m.group(3)
    done = True; break
if not done: sys.exit(1)
open(path, "w", encoding="utf-8").write("\n".join(lines))
PY
}

# ---- plugin state (JSON, never text grep; tri-state: present / absent / error) --------------
# Running the claude CLI creates ~/.claude.json etc. on a pristine HOME, so it is consulted only
# when a plugin registry already exists. If the registry exists but cannot be inspected (CLI
# failure, malformed JSON), the state is ERROR and every mode-changing or approving path fails
# closed rather than assuming "absent".
PLUGIN_STATE=""; MARKET_PATH=""; PLUGIN_INSPECT="absent"
inspect_plugins() {
    [ -e "$HOME/.claude/plugins" ] || { PLUGIN_INSPECT="absent"; return 0; }
    have_claude || { PLUGIN_INSPECT="error"; return 0; }
    local out
    out="$( { claude plugin list --json 2>/dev/null; echo "RC=$?"; } | python3 -c '
import json, sys
data = sys.stdin.read()
body, _, rc = data.rpartition("RC=")
try:
    if rc.strip() != "0": raise ValueError("cli")
    data = json.loads(body)
    if not isinstance(data, list): raise ValueError("shape")
    hits = [p for p in data if isinstance(p, dict) and p.get("id") == sys.argv[1]]
    if len(hits) > 1: raise ValueError("duplicate ids")
    if hits:
        p = hits[0]
        if not isinstance(p.get("version"), str) or not isinstance(p.get("enabled"), bool): raise ValueError("schema")
        print("OK", p["version"], "true" if p["enabled"] else "false")
    else:
        print("OK")
except Exception:
    print("ERR")' "$PLUGIN_ID" 2>/dev/null )" || out="ERR"
    case "$out" in
        OK) PLUGIN_STATE="";;
        OK\ *) PLUGIN_STATE="${out#OK }";;
        *) PLUGIN_INSPECT="error"; return 0;;
    esac
    out="$( { claude plugin marketplace list --json 2>/dev/null; echo "RC=$?"; } | python3 -c '
import json, sys
data = sys.stdin.read()
body, _, rc = data.rpartition("RC=")
try:
    if rc.strip() != "0": raise ValueError("cli")
    data = json.loads(body)
    if not isinstance(data, list): raise ValueError("shape")
    hits = [m for m in data if isinstance(m, dict) and m.get("name") == sys.argv[1]]
    if len(hits) > 1: raise ValueError("duplicate names")
    if hits:
        if not isinstance(hits[0].get("path"), str): raise ValueError("schema")
        print("OK", hits[0]["path"])
    else:
        print("OK")
except Exception:
    print("ERR")' "$MARKETPLACE" 2>/dev/null )" || out="ERR"
    case "$out" in
        OK) MARKET_PATH="";;
        OK\ *) MARKET_PATH="${out#OK }";;
        *) PLUGIN_INSPECT="error"; return 0;;
    esac
    PLUGIN_INSPECT="ok"
}
inspect_plugins
if [ "$PLUGIN_INSPECT" = "error" ]; then
    if [ "$CHECK" = 1 ]; then
        echo "UNINSPECTABLE  ~/.claude/plugins exists but 'claude plugin list --json' / 'marketplace list --json' could not be read; cannot approve the Claude side" >&2
        # fall through: symlink/config checks still run, but the check will fail
        INSPECT_FAILED=1
    else
        echo "ERROR: ~/.claude/plugins exists but the Claude plugin state cannot be inspected (claude CLI failed or returned malformed JSON); refusing to change install mode." >&2; exit 1
    fi
fi
plugin_present() { [ "$PLUGIN_INSPECT" = "ok" ] && [ -n "$PLUGIN_STATE" ]; }
plugin_current() { plugin_present && [ "$MARKET_PATH" = "$ROOT" ] && [ "$PLUGIN_STATE" = "$VERSION true" ]; }
marketplace_path() { echo "$MARKET_PATH"; }
plugin_state() { echo "$PLUGIN_STATE"; }
refresh_plugins() { PLUGIN_INSPECT="absent"; PLUGIN_STATE=""; MARKET_PATH=""; inspect_plugins; }

# --- skill mode: the plugin form must not stay active alongside the user-level skill --------
# Done BEFORE any symlink is created: the skill symlink is only added once the plugin is
# confirmed absent by a successful re-inspection (a stateful CLI failure must not leave both).
if [ "$PLUGIN" = 0 ] && [ "$CHECK" = 0 ] && plugin_present; then
    claude plugin uninstall --scope user "$PLUGIN_ID" >/dev/null 2>&1 || claude plugin uninstall "$PLUGIN_ID" >/dev/null 2>&1 \
        || { echo "ERROR: could not uninstall $PLUGIN_ID; skill mode would duplicate the plugin skill. Run: claude plugin uninstall $PLUGIN_ID" >&2; exit 1; }
    refresh_plugins
    if [ "$PLUGIN_INSPECT" != "ok" ] || plugin_present; then
        echo "ERROR: could not confirm that $PLUGIN_ID is absent after uninstall (inspection=$PLUGIN_INSPECT, state='$PLUGIN_STATE'); refusing to create the user-level skill. Re-run install.sh." >&2; exit 1
    fi
    echo "removed   plugin $PLUGIN_ID (skill mode uses the user-level /secondopinion-respond skill instead)"
fi

# ---- symlinks -----------------------------------------------------------------------------
# Parallel arrays (a delimiter inside HOME must not be able to split a tuple).
DESTS=("$HOME/.local/bin/secondopinion" "$HOME/.codex/skills/secondopinion-request")
SRCS=("$ROOT/bin/secondopinion" "$ROOT/skills/codex/secondopinion-request")
# ~/.local/bin/agent-mailbox is the deprecated 1.x alias (same binary; prints a warning). It is
# created on install so old scripts/skills keep working, but --check does not require it.
if [ "$CHECK" != 1 ]; then DESTS+=("$HOME/.local/bin/agent-mailbox"); SRCS+=("$ROOT/bin/secondopinion"); fi
# 1.x skill links point at names that no longer exist; retire them (they are symlinks we made).
if [ "$CHECK" != 1 ]; then
    for old in "$HOME/.claude/skills/codex-mailbox" "$HOME/.codex/skills/claude-mailbox"; do
        if [ -L "$old" ]; then rm -f -- "$old"; echo "retired   $old (1.x skill name)"; fi
    done
fi
# The Claude skill is a symlink in skill mode; in plugin mode it comes from the plugin.
# --check accepts either form.
if [ "$PLUGIN" = 0 ] && ! { [ "$CHECK" = 1 ] && plugin_current; }; then
    DESTS+=("$CLAUDE_SKILL_LINK"); SRCS+=("$ROOT/skills/claude/secondopinion-respond")
fi
link_ok() { # dest src -> both resolve and to the same target
    local d s
    [ -L "$1" ] && d="$(readlink -f -- "$1")" && s="$(readlink -f -- "$2")" && [ -n "$d" ] && [ "$d" = "$s" ]
}

status=0
for i in "${!DESTS[@]}"; do
    dest="${DESTS[$i]}"; src="${SRCS[$i]}"
    if link_ok "$dest" "$src"; then
        echo "ok        $dest -> $src"
        continue
    fi
    if [ "$CHECK" = 1 ]; then
        echo "MISSING   $dest (want -> $src)"; status=1; continue
    fi
    mkdir -p "$(dirname "$dest")"
    if [ -L "$dest" ]; then
        rm -f "$dest"
    elif [ -e "$dest" ]; then
        mkdir -p "$BACKUP_DIR"; bak="$(backup_path "$(basename "$dest")")"
        mv -T -- "$dest" "$bak"
        echo "backed-up $dest -> $bak"
    fi
    ln -s -- "$src" "$dest"
    echo "linked    $dest -> $src"
done

# --- 1.x store migration: move ~/.agent-mailbox to the new default once and leave the old
# path as a symlink so running Codex/Claude sessions (and their sandbox roots) keep working.
if [ "$CHECK" != 1 ] && [ -z "${SECONDOPINION_DIR:-}" ] && [ -d "$OLD_STORE" ] && [ ! -L "$OLD_STORE" ] && [ ! -e "$STORE_DIR" ]; then
    mv -T -- "$OLD_STORE" "$STORE_DIR" && ln -s -- "$STORE_DIR" "$OLD_STORE"
    echo "migrated  $OLD_STORE -> $STORE_DIR (old path kept as a symlink for running sessions)"
fi

# --- Codex sandbox: the store must be a writable root, or Codex's workspace-write
# sandbox sees $HOME read-only and `secondopinion new` fails ("Read-only file system").
if [ "$CHECK" != 1 ]; then
    mkdir -p "$STORE_DIR"; chmod 700 "$STORE_DIR"
fi
if [ -f "$CODEX_CFG" ] && grep -q '^\[sandbox_workspace_write\]' "$CODEX_CFG"; then
    if store_in_sandbox_roots; then
        echo "ok        $CODEX_CFG: [sandbox_workspace_write] writable_roots includes $STORE_DIR"
    elif [ "$CHECK" != 1 ] && extend_sandbox_roots; then
        echo "config    $CODEX_CFG: added \"$STORE_DIR\" to [sandbox_workspace_write] writable_roots (previous file backed up)"
    else
        echo "ACTION    $CODEX_CFG already has a [sandbox_workspace_write] table whose writable_roots could not be extended automatically; add \"$STORE_DIR\" to that array by hand." >&2
        [ "$CHECK" = 1 ] && status=1
    fi
elif [ "$CHECK" = 1 ]; then
    echo "MISSING   $CODEX_CFG: [sandbox_workspace_write] writable_roots for $STORE_DIR"; status=1
else
    mkdir -p "$(dirname "$CODEX_CFG")"
    { [ -f "$CODEX_CFG" ] && [ -n "$(tail -c1 "$CODEX_CFG")" ] && echo; printf '\n[sandbox_workspace_write]\nwritable_roots = ["%s"]\n' "$STORE_DIR"; } >> "$CODEX_CFG"
    echo "config    $CODEX_CFG: added [sandbox_workspace_write] writable_roots = [\"$STORE_DIR\"] (Codex sandbox may write the store)"
fi

# --- plugin mode: Claude side through the plugin system ------------------------------------
if [ "$PLUGIN" = 1 ]; then
    if [ -L "$CLAUDE_SKILL_LINK" ]; then
        rm -f "$CLAUDE_SKILL_LINK"; echo "retired   $CLAUDE_SKILL_LINK (user-level skill would duplicate the plugin skill)"
    elif [ -e "$CLAUDE_SKILL_LINK" ]; then
        mkdir -p "$BACKUP_DIR"; bak="$(backup_path secondopinion-respond)"
        mv -T -- "$CLAUDE_SKILL_LINK" "$bak"; echo "backed-up $CLAUDE_SKILL_LINK -> $bak"
    fi
    mp="$(marketplace_path)"
    if [ -n "$mp" ] && [ "$mp" != "$ROOT" ]; then
        # A marketplace of our name pointing elsewhere (moved or stale checkout): replace it.
        claude plugin marketplace remove "$MARKETPLACE" >/dev/null 2>&1 || true
        echo "removed   stale marketplace $MARKETPLACE -> $mp"; mp=""
    fi
    if [ -z "$mp" ]; then
        claude plugin marketplace add "$ROOT" >/dev/null || { echo "ERROR: claude plugin marketplace add $ROOT failed" >&2; exit 1; }
        echo "added     marketplace $MARKETPLACE -> $ROOT"
    else
        claude plugin marketplace update "$MARKETPLACE" >/dev/null || { echo "ERROR: claude plugin marketplace update $MARKETPLACE failed" >&2; exit 1; }
        echo "ok        marketplace $MARKETPLACE ($ROOT) refreshed"
    fi
    state="$(plugin_state)"
    if [ -z "$state" ]; then
        claude plugin install "$PLUGIN_ID" >/dev/null || { echo "ERROR: claude plugin install $PLUGIN_ID failed" >&2; exit 1; }
        echo "installed plugin $PLUGIN_ID $VERSION"
    else
        ver="${state%% *}"
        if [ "$ver" != "$VERSION" ]; then
            claude plugin update --scope user "$PLUGIN_ID" >/dev/null 2>&1 || true
            refresh_plugins
            if [ "$(plugin_state | cut -d' ' -f1)" != "$VERSION" ]; then
                # update could not reach this version (e.g. stale cache): reinstall from the repointed marketplace
                claude plugin uninstall --scope user "$PLUGIN_ID" >/dev/null 2>&1 || true
                claude plugin install "$PLUGIN_ID" >/dev/null || { echo "ERROR: claude plugin (re)install $PLUGIN_ID failed" >&2; exit 1; }
            fi
            echo "updated   plugin $PLUGIN_ID $ver -> $VERSION"
        fi
        refresh_plugins
        if [ "$(plugin_state | cut -d' ' -f2)" != "true" ]; then
            claude plugin enable --scope user "$PLUGIN_ID" >/dev/null || { echo "ERROR: claude plugin enable $PLUGIN_ID failed" >&2; exit 1; }
            echo "enabled   plugin $PLUGIN_ID"
        fi
    fi
    refresh_plugins
    if plugin_current; then
        echo "ok        plugin $PLUGIN_ID $VERSION enabled from $ROOT (skill: /secondopinion:secondopinion-respond; restart Claude Code to apply)"
    else
        echo "ERROR: plugin verification failed: state='$(plugin_state)' marketplace='$(marketplace_path)' (want '$VERSION true' from $ROOT)" >&2; exit 1
    fi
fi
if [ "$CHECK" = 1 ]; then
    [ "${INSPECT_FAILED:-0}" = 1 ] && status=1
    if plugin_current && { [ -e "$CLAUDE_SKILL_LINK" ] || [ -L "$CLAUDE_SKILL_LINK" ]; }; then
        echo "DUPLICATE both the plugin $PLUGIN_ID and the user-level skill $CLAUDE_SKILL_LINK are active; run install.sh (skill mode) or install.sh --plugin to pick one" >&2; status=1
    elif plugin_current; then echo "ok        Claude side: plugin $PLUGIN_ID $VERSION (skill /secondopinion:secondopinion-respond)"
    elif [ -L "$CLAUDE_SKILL_LINK" ]; then echo "ok        Claude side: user-level skill $CLAUDE_SKILL_LINK (skill /secondopinion-respond)"
    elif plugin_present; then echo "STALE     plugin $PLUGIN_ID is installed but is not '$VERSION enabled from $ROOT' (state='$(plugin_state)', marketplace='$(marketplace_path)'); run install.sh --plugin" >&2; status=1
    fi
fi

case ":$PATH:" in
    *":$HOME/.local/bin:"*) ;;
    *) echo "WARNING: $HOME/.local/bin is not on PATH in this shell; add it so 'secondopinion' resolves." >&2
       [ "$CHECK" = 1 ] && status=1;;
esac

if [ "$CHECK" = 1 ]; then
    [ "$status" = 0 ] && echo "installed=yes" || echo "installed=no"
else
    echo "done: restart Claude Code / Codex sessions to load the skills"
fi
exit "$status"
