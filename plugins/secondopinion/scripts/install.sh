#!/bin/bash
# install.sh — install secondopinion for Codex (and, optionally, Claude Code).
#   install.sh           default: the Codex PLUGIN (codex plugin marketplace add + codex plugin add),
#                        the CLI symlink, the store and the Codex sandbox config. NOTHING is installed
#                        in Claude: `secondopinion ask` carries the respond instructions inline and
#                        needs only the `claude` CLI on PATH (the mirror of the Claude->Codex plugin,
#                        which installs nothing in Codex).
#   install.sh --claude  additionally install the Claude Code plugin secondopinion@secondopinion, for
#                        interactive responding (/secondopinion:secondopinion-respond). Optional.
#   install.sh --skills  symlink form instead of plugins: ~/.codex/skills/secondopinion-request
#                        (with --claude: ~/.claude/skills/secondopinion-respond). For setups without
#                        plugin support. Mutually exclusive with the plugin form; switching retires
#                        the other form.
#   install.sh --plugin  deprecated alias for --claude.
#   install.sh --check   report status; exit 0 if fully installed (the Codex side in exactly one
#                        current form; the Claude side may be absent, but must be current if present).
#   install.sh --uninstall  COMPLETE removal: plugins, marketplaces, skill symlinks, CLI
#                        symlinks, sandbox config edits, the store (all exchanges/archives),
#                        the default state dir and any leftover plugin cache. Only a custom
#                        SECONDOPINION_BACKUP_DIR location is left alone.
set -euo pipefail

if [ -z "${HOME:-}" ]; then
    echo "ERROR: HOME is not set; cannot locate ~/.local/bin, ~/.claude/skills or ~/.codex/skills." >&2
    exit 1
fi
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"          # plugin root (plugins/secondopinion)
REPO_ROOT="$(cd "$ROOT/../.." && pwd)"                               # marketplace root (the git checkout)
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
CHECK=0; SKILLS=0; CLAUDE=0; UNINSTALL=0
for arg in "$@"; do
    case "$arg" in
        --check) CHECK=1;;
        --uninstall) UNINSTALL=1;;
        --skills) SKILLS=1;;
        --claude) CLAUDE=1;;
        --plugin) CLAUDE=1; echo "note      --plugin is deprecated; it now means --claude (the Codex plugin is always installed by default)" >&2;;
        -h|--help) sed -n '2,20p' "$0"; exit 0;;
        *) echo "usage: install.sh [--check] [--claude] [--skills] [--uninstall]   (unknown argument: '$arg')" >&2; exit 1;;
    esac
done
PLUGIN_ID="secondopinion@secondopinion"
MARKETPLACE="secondopinion"
CLAUDE_SKILL_LINK="$HOME/.claude/skills/secondopinion-respond"
STORE_DIR="${SECONDOPINION_DIR:-$HOME/.secondopinion}"
OLD_STORE="$HOME/.agent-mailbox"                       # legacy agent-mailbox store; migrated once (see below)
CODEX_CFG="$HOME/.codex/config.toml"

# ---- every precondition is checked BEFORE any mutation ------------------------------------
# The store path is written into TOML as a quoted string: refuse anything that
# cannot be represented verbatim (quotes, backslashes, control characters).
case "$STORE_DIR" in
    *[\"\\]*|*[[:cntrl:]]*) printf 'ERROR: store path %q contains a quote, backslash or control character; choose another SECONDOPINION_DIR.\n' "$STORE_DIR" >&2; exit 1;;
esac
have_claude() { command -v claude >/dev/null 2>&1 && command -v python3 >/dev/null 2>&1; }
have_codex_cli() { command -v codex >/dev/null 2>&1 && command -v python3 >/dev/null 2>&1; }
if [ "$CHECK" = 0 ] && [ "$SKILLS" = 0 ] && [ "$UNINSTALL" = 0 ] && ! have_codex_cli; then
    echo "ERROR: the default install form is the Codex plugin and needs the 'codex' CLI and python3 on PATH; use --skills for a symlink-only install (nothing was installed)." >&2; exit 1
fi
if [ "$CHECK" = 0 ] && [ "$CLAUDE" = 1 ] && [ "$SKILLS" = 0 ] && [ "$UNINSTALL" = 0 ] && ! have_claude; then
    echo "ERROR: --claude needs the 'claude' CLI and python3 on PATH (nothing was installed)." >&2; exit 1
fi

# ---- Codex sandbox config: semantic membership of the store in
# [sandbox_workspace_write].writable_roots (comments and multiline arrays handled) ------------
store_in_sandbox_roots() { # [path] -> is path (default: the store) a member of writable_roots?
    local target="${1:-$STORE_DIR}"
    if command -v python3 >/dev/null 2>&1; then
        python3 - "$CODEX_CFG" "$target" <<'PY'
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
        if m:
            table = m.group(1).strip()
            if len(table) >= 2 and table[0] == table[-1] and table[0] in "\"'": table = table[1:-1]
            continue
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
        awk '/^\[sandbox_workspace_write\]/{f=1; next} /^\[/{f=0} f' "$CODEX_CFG" | grep -E '^writable_roots *=' | grep -Fq "\"$target\""
    fi
}

# Remove one member from a SINGLE-LINE writable_roots array (backup first); multi-line or
# odd formatting is left for the user (ACTION).
remove_sandbox_root() { # path
    command -v python3 >/dev/null 2>&1 || return 1
    mkdir -p "$BACKUP_DIR"; local bak; bak="$(backup_path config.toml)"
    cp -p -- "$CODEX_CFG" "$bak" || return 1
    python3 - "$CODEX_CFG" "$1" <<'PY2' || { rm -f -- "$bak"; return 1; }
import re, sys
path, target = sys.argv[1], sys.argv[2]
lines = open(path, encoding="utf-8").read().split("\n")
table = None; done = False
for i, line in enumerate(lines):
    m = re.match(r"^\s*\[\s*([^\]]+?)\s*\]\s*$", line)
    if m:
        table = m.group(1).strip()
        if len(table) >= 2 and table[0] == table[-1] and table[0] in "\"'": table = table[1:-1]
        continue
    if table != "sandbox_workspace_write": continue
    m = re.match(r'^(\s*writable_roots\s*=\s*\[)(.*)(\]\s*(#.*)?)$', line)
    if not m: continue
    vals = re.findall(r'"((?:[^"\\]|\\.)*)"', m.group(2))
    if target not in vals: continue
    inner = ", ".join('"' + v + '"' for v in vals if v != target)
    lines[i] = m.group(1) + inner + m.group(3)
    done = True; break
if not done: sys.exit(1)
open(path, "w", encoding="utf-8").write("\n".join(lines))
PY2
}

# Remove the whole [sandbox_workspace_write] table iff it now holds nothing but our own
# settings (network_access = true and/or an empty writable_roots). A table the user added
# anything to is left alone.
remove_empty_sandbox_section() {
    command -v python3 >/dev/null 2>&1 || return 1
    python3 - "$CODEX_CFG" <<'PY3'
import re, sys
path = sys.argv[1]
lines = open(path, encoding="utf-8").read().split("\n")
start = None; end = None
for i, line in enumerate(lines):
    m = re.match(r"^\s*\[\s*([^\]]+?)\s*\]\s*$", line)
    if m:
        t = m.group(1).strip()
        if len(t) >= 2 and t[0] == t[-1] and t[0] in "\"'": t = t[1:-1]
        if t == "sandbox_workspace_write" and start is None: start = i; continue
        if start is not None and end is None: end = i
if start is None: sys.exit(1)
if end is None: end = len(lines)
body = [l for l in lines[start+1:end] if l.strip() and not l.strip().startswith("#")]
ok = all(re.match(r"^\s*network_access\s*=\s*true\s*$", l) or re.match(r"^\s*writable_roots\s*=\s*\[\s*\]\s*$", l) for l in body)
if not ok: sys.exit(1)
del lines[start:end]
out = re.sub(r"\n{3,}", "\n\n", "\n".join(lines))
open(path, "w", encoding="utf-8").write(out)
PY3
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
    if m:
        table = m.group(1).strip()
        if len(table) >= 2 and table[0] == table[-1] and table[0] in "\"'": table = table[1:-1]
        continue
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

# TOML table headers may quote the key: [sandbox_workspace_write], [ sandbox_workspace_write ],
# ["sandbox_workspace_write"], ['sandbox_workspace_write'] are all the same table.
SANDBOX_TBL_RE="^[[:space:]]*\[[[:space:]]*[\"']?sandbox_workspace_write[\"']?[[:space:]]*\][[:space:]]*(#.*)?\$"
export SANDBOX_TBL_RE
sandbox_network_setting() { # -> true | false | "" (absent) inside [sandbox_workspace_write]
    [ -f "$CODEX_CFG" ] || { echo ""; return 0; }
    awk '/^[[:space:]]*\[/{f=($0 ~ ENVIRON["SANDBOX_TBL_RE"])} f && /^[[:space:]]*network_access[[:space:]]*=/ {sub(/#.*/,""); gsub(/[[:space:]]|network_access|=/,""); print; exit}' "$CODEX_CFG"
}
set_sandbox_network_true() { # insert `network_access = true` right after the table header (backup first)
    mkdir -p "$BACKUP_DIR"; local bak; bak="$(backup_path config.toml)"
    cp -p -- "$CODEX_CFG" "$bak" || return 1
    awk 'BEGIN{done=0} {print} $0 ~ ENVIRON["SANDBOX_TBL_RE"] && !done {print "network_access = true"; done=1}' "$CODEX_CFG" > "$CODEX_CFG.tmp.$$" && mv -f -- "$CODEX_CFG.tmp.$$" "$CODEX_CFG"
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
plugin_current() { plugin_present && [ "$MARKET_PATH" = "$REPO_ROOT" ] && [ "$PLUGIN_STATE" = "$VERSION true" ]; }
marketplace_path() { echo "$MARKET_PATH"; }
plugin_state() { echo "$PLUGIN_STATE"; }
refresh_plugins() { PLUGIN_INSPECT="absent"; PLUGIN_STATE=""; MARKET_PATH=""; inspect_plugins; }

# ---- Codex plugin state (JSON; tri-state) --------------------------------------------------
have_codex() { command -v codex >/dev/null 2>&1 && command -v python3 >/dev/null 2>&1; }
CODEX_STATE=""; CODEX_MARKET_ROOT=""; CODEX_INSPECT="absent"
codex_home() { echo "${CODEX_HOME:-$HOME/.codex}"; }
inspect_codex() {
    [ -e "$(codex_home)/plugins" ] || { CODEX_INSPECT="absent"; return 0; }
    have_codex || { CODEX_INSPECT="error"; return 0; }
    local out
    out="$( { codex plugin list --json 2>/dev/null; echo "RC=$?"; } | python3 -c '
import json, sys
data = sys.stdin.read()
body, _, rc = data.rpartition("RC=")
try:
    if rc.strip() != "0": raise ValueError("cli")
    d = json.loads(body)
    if not isinstance(d, dict) or not isinstance(d.get("installed"), list): raise ValueError("shape")
    hits = [p for p in d["installed"] if isinstance(p, dict) and p.get("pluginId") == sys.argv[1]]
    if len(hits) > 1: raise ValueError("duplicate ids")
    if hits:
        p = hits[0]
        if not isinstance(p.get("version"), str) or not isinstance(p.get("enabled"), bool): raise ValueError("schema")
        src = (p.get("marketplaceSource") or {}).get("source", "")
        if not isinstance(src, str): raise ValueError("schema")
        print("OK", p["version"], "true" if p["enabled"] else "false", src)
    else:
        print("OK")
except Exception:
    print("ERR")' "$PLUGIN_ID" 2>/dev/null )" || out="ERR"
    case "$out" in
        OK) CODEX_STATE=""; CODEX_MARKET_ROOT="";;
        OK\ *) CODEX_STATE="$(printf '%s' "${out#OK }" | cut -d' ' -f1,2)"; CODEX_MARKET_ROOT="$(printf '%s' "${out#OK }" | cut -d' ' -f3-)";;
        *) CODEX_INSPECT="error"; return 0;;
    esac
    CODEX_INSPECT="ok"
}
inspect_codex
if [ "$CODEX_INSPECT" = "error" ]; then
    if [ "$CHECK" = 1 ]; then echo "UNINSPECTABLE  $(codex_home)/plugins exists but 'codex plugin list --json' could not be read; cannot approve the Codex side" >&2; INSPECT_FAILED=1
    else echo "ERROR: $(codex_home)/plugins exists but the Codex plugin state cannot be inspected; refusing to change install mode." >&2; exit 1; fi
fi
codex_plugin_present() { [ "$CODEX_INSPECT" = "ok" ] && [ -n "$CODEX_STATE" ]; }
codex_plugin_current() { codex_plugin_present && [ "$CODEX_MARKET_ROOT" = "$REPO_ROOT" ] && [ "$CODEX_STATE" = "$VERSION true" ]; }
refresh_codex() { CODEX_INSPECT="absent"; CODEX_STATE=""; CODEX_MARKET_ROOT=""; inspect_codex; }
codex_marketplace_root() { # -> root of our marketplace in codex, or ""
    codex plugin marketplace list --json 2>/dev/null | python3 -c '
import json, sys
try:
    for m in json.load(sys.stdin).get("marketplaces", []):
        if m.get("name") == sys.argv[1]: print(m.get("root", "")); break
except Exception:
    pass' "$MARKETPLACE" 2>/dev/null || true
}


# ---- --uninstall: remove every installed piece on both sides; store and backups are KEPT --
if [ "$UNINSTALL" = 1 ]; then
    if [ "$CHECK" = 1 ] || [ "$SKILLS" = 1 ] || [ "$CLAUDE" = 1 ]; then
        echo "usage: install.sh --uninstall   (cannot be combined with other options)" >&2; exit 1
    fi
    # Stop only our notification bridge before touching its store/cache. Codex's
    # shared daemon belongs to Codex and may host unrelated user conversations.
    python3 -B "$ROOT/scripts/wake_service.py" uninstall --store "$STORE_DIR"
    if have_claude; then
        claude plugin uninstall --scope user "$PLUGIN_ID" >/dev/null 2>&1 && echo "removed   Claude plugin $PLUGIN_ID" || true
        claude plugin marketplace remove "$MARKETPLACE" >/dev/null 2>&1 && echo "removed   Claude marketplace $MARKETPLACE" || true
    fi
    if [ -L "$CLAUDE_SKILL_LINK" ]; then rm -f -- "$CLAUDE_SKILL_LINK"; echo "removed   $CLAUDE_SKILL_LINK"; fi
    if have_codex_cli; then
        codex plugin remove "$PLUGIN_ID" >/dev/null 2>&1 && echo "removed   Codex plugin $PLUGIN_ID" || true
        codex plugin marketplace remove "$MARKETPLACE" >/dev/null 2>&1 && echo "removed   Codex marketplace $MARKETPLACE" || true
    fi
    UNINSTALL_CODEX_SKILL="$(codex_home)/skills/secondopinion-request"
    if [ -L "$UNINSTALL_CODEX_SKILL" ]; then rm -f -- "$UNINSTALL_CODEX_SKILL"; echo "removed   $UNINSTALL_CODEX_SKILL"; fi
    # CLI symlinks: only ones that resolve into a secondopinion checkout are ours to remove.
    for l in "$HOME/.local/bin/secondopinion" "$HOME/.local/bin/agent-mailbox"; do
        if [ -L "$l" ]; then
            case "$(readlink -f -- "$l" 2>/dev/null)" in
                */plugins/secondopinion/bin/secondopinion) rm -f -- "$l"; echo "removed   $l";;
                *) echo "kept      $l (does not point at a secondopinion checkout)";;
            esac
        fi
    done
    if [ -L "$HOME/.agent-mailbox" ]; then rm -f -- "$HOME/.agent-mailbox"; echo "removed   $HOME/.agent-mailbox (legacy store symlink)"; fi
    if [ -f "$CODEX_CFG" ] && [ ! -L "$CODEX_CFG" ]; then
        remove_sandbox_root "$STORE_DIR" && echo "config    $CODEX_CFG: removed $STORE_DIR from [sandbox_workspace_write].writable_roots (backup in $BACKUP_DIR)" || true
        remove_empty_sandbox_section && echo "config    $CODEX_CFG: removed the now-empty [sandbox_workspace_write] table" || true
    fi
    # Complete removal: the store (all exchanges/archives/logs), our default state dir,
    # and any leftover plugin cache. A CUSTOM backups location is not ours to delete.
    if { [ -e "$STORE_DIR" ] || [ -L "$STORE_DIR" ]; } && [ -n "$STORE_DIR" ] && [ "$STORE_DIR" != "/" ]; then
        rm -rf -- "$STORE_DIR"; echo "removed   store $STORE_DIR (all exchanges, archives and responder logs)"
    fi
    UNINSTALL_STATE="$HOME/.local/state/secondopinion"
    if [ -e "$UNINSTALL_STATE" ] || [ -L "$UNINSTALL_STATE" ]; then
        rm -rf -- "$UNINSTALL_STATE"; echo "removed   $UNINSTALL_STATE (installer backups/state)"
    fi
    case "$BACKUP_DIR" in
        "$UNINSTALL_STATE"|"$UNINSTALL_STATE"/*) ;;
        *) if [ -e "$BACKUP_DIR" ]; then echo "kept      $BACKUP_DIR (custom SECONDOPINION_BACKUP_DIR location; not ours to delete)"; fi;;
    esac
    UNINSTALL_CACHE="$(codex_home)/plugins/cache/secondopinion"
    if [ -e "$UNINSTALL_CACHE" ] || [ -L "$UNINSTALL_CACHE" ]; then
        rm -rf -- "$UNINSTALL_CACHE"; echo "removed   $UNINSTALL_CACHE (leftover Codex plugin cache)"
    fi
    echo "uninstalled: nothing of secondopinion remains (install, config edits, store and state all removed)"
    exit 0
fi

# --- retire forms the chosen mode does not use. Done BEFORE any symlink is created: a skill
# symlink is only added once the same-side plugin is confirmed absent by a successful
# re-inspection (a stateful CLI failure must not leave both forms active).
# The Claude plugin stays ONLY for `--claude` in plugin form; by default nothing remains
# installed in Claude.
if [ "$CHECK" = 0 ] && { [ "$CLAUDE" = 0 ] || [ "$SKILLS" = 1 ]; } && plugin_present; then
    claude plugin uninstall --scope user "$PLUGIN_ID" >/dev/null 2>&1 || claude plugin uninstall "$PLUGIN_ID" >/dev/null 2>&1 \
        || { echo "ERROR: could not uninstall the Claude plugin $PLUGIN_ID. Run: claude plugin uninstall $PLUGIN_ID" >&2; exit 1; }
    refresh_plugins
    if [ "$PLUGIN_INSPECT" != "ok" ] || plugin_present; then
        echo "ERROR: could not confirm that $PLUGIN_ID is absent after uninstall (inspection=$PLUGIN_INSPECT, state='$PLUGIN_STATE'); stopping before creating anything in its place. Re-run install.sh." >&2; exit 1
    fi
    if [ "$CLAUDE" = 1 ]; then echo "removed   Claude plugin $PLUGIN_ID (--skills uses the user-level /secondopinion-respond skill instead)"
    else echo "removed   Claude plugin $PLUGIN_ID (nothing needs to be installed in Claude; re-add with install.sh --claude)"; fi
fi
# The Claude user-level skill stays ONLY for `--skills --claude`.
if [ "$CHECK" = 0 ] && ! { [ "$SKILLS" = 1 ] && [ "$CLAUDE" = 1 ]; }; then
    if [ -L "$CLAUDE_SKILL_LINK" ]; then
        rm -f -- "$CLAUDE_SKILL_LINK"; echo "retired   $CLAUDE_SKILL_LINK (nothing needs to be installed in Claude; re-add with install.sh --skills --claude)"
    elif [ -e "$CLAUDE_SKILL_LINK" ]; then
        mkdir -p "$BACKUP_DIR"; bak="$(backup_path secondopinion-respond)"
        mv -T -- "$CLAUDE_SKILL_LINK" "$bak"; echo "backed-up $CLAUDE_SKILL_LINK -> $bak"
    fi
fi
# The Codex plugin is removed only in --skills form.
if [ "$SKILLS" = 1 ] && [ "$CHECK" = 0 ] && codex_plugin_present; then
    codex plugin remove "$PLUGIN_ID" >/dev/null 2>&1 || { echo "ERROR: could not remove the Codex plugin $PLUGIN_ID; --skills would duplicate the Codex skill. Run: codex plugin remove $PLUGIN_ID" >&2; exit 1; }
    refresh_codex
    if [ "$CODEX_INSPECT" != "ok" ] || codex_plugin_present; then
        echo "ERROR: could not confirm that the Codex plugin $PLUGIN_ID is absent after removal (inspection=$CODEX_INSPECT, state='$CODEX_STATE'); refusing to create the Codex skill symlink." >&2; exit 1
    fi
    echo "removed   Codex plugin $PLUGIN_ID (--skills uses the ~/.codex/skills symlink instead)"
fi

# ---- symlinks -----------------------------------------------------------------------------
# Parallel arrays (a delimiter inside HOME must not be able to split a tuple).
DESTS=("$HOME/.local/bin/secondopinion")
SRCS=("$ROOT/bin/secondopinion")
CODEX_SKILL_LINK="$(codex_home)/skills/secondopinion-request"
# The Codex skill is a symlink only in --skills form; otherwise it comes from the Codex
# plugin. --check reports the side explicitly below (either form accepted).
if [ "$CHECK" = 0 ] && [ "$SKILLS" = 1 ]; then
    DESTS+=("$CODEX_SKILL_LINK"); SRCS+=("$ROOT/skills/secondopinion-request")
fi
# ~/.local/bin/agent-mailbox is the deprecated legacy alias (same binary; prints a warning). It is
# created on install so old scripts/skills keep working, but --check does not require it.
if [ "$CHECK" != 1 ]; then DESTS+=("$HOME/.local/bin/agent-mailbox"); SRCS+=("$ROOT/bin/secondopinion"); fi
# legacy agent-mailbox skill links point at names that no longer exist; retire them (they are symlinks we made).
if [ "$CHECK" != 1 ]; then
    for old in "$HOME/.claude/skills/codex-mailbox" "$HOME/.codex/skills/claude-mailbox"; do
        if [ -L "$old" ]; then rm -f -- "$old"; echo "retired   $old (legacy agent-mailbox skill name)"; fi
    done
fi
# The Claude skill is a symlink only for --skills --claude; with --claude alone it comes
# from the Claude plugin; by default the Claude side stays empty.
if [ "$CHECK" = 0 ] && [ "$SKILLS" = 1 ] && [ "$CLAUDE" = 1 ]; then
    DESTS+=("$CLAUDE_SKILL_LINK"); SRCS+=("$ROOT/skills/secondopinion-respond")
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

# --- legacy store migration: move ~/.agent-mailbox to the new default once and leave the old
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
if [ -f "$CODEX_CFG" ] && grep -Eq "$SANDBOX_TBL_RE" "$CODEX_CFG"; then
    if store_in_sandbox_roots; then
        echo "ok        $CODEX_CFG: [sandbox_workspace_write] writable_roots includes $STORE_DIR"
    elif [ "$CHECK" != 1 ] && extend_sandbox_roots; then
        echo "config    $CODEX_CFG: added \"$STORE_DIR\" to [sandbox_workspace_write] writable_roots (previous file backed up)"
    else
        echo "ACTION    $CODEX_CFG already has a [sandbox_workspace_write] table whose writable_roots could not be extended automatically; add \"$STORE_DIR\" to that array by hand." >&2
        [ "$CHECK" = 1 ] && status=1
    fi
    # `secondopinion ask` runs Claude Code from inside a Codex command; Codex's workspace-write
    # sandbox has no network unless network_access = true. Set it once when absent; an explicit
    # `false` is the user's decision and is reported, never flipped.
    case "$(sandbox_network_setting)" in
        true)  echo "ok        $CODEX_CFG: [sandbox_workspace_write] network_access = true (Codex commands may reach Claude)";;
        false) echo "ACTION    $CODEX_CFG: [sandbox_workspace_write] network_access = false; 'secondopinion ask' cannot reach Claude from inside Codex until it is true (left unchanged: your choice)." >&2
               [ "$CHECK" = 1 ] && status=1;;
        *)     if [ "$CHECK" = 1 ]; then echo "MISSING   $CODEX_CFG: [sandbox_workspace_write] network_access = true (needed by 'secondopinion ask' from inside Codex)"; status=1
               elif set_sandbox_network_true; then echo "config    $CODEX_CFG: set [sandbox_workspace_write] network_access = true (Codex commands may reach Claude; previous file backed up)"
               else echo "ACTION    $CODEX_CFG: could not set network_access = true in [sandbox_workspace_write]; add it by hand." >&2; fi;;
    esac
    # A writable root that is itself a symlink (the migrated legacy store path) breaks Codex's
    # bubblewrap sandbox: "cannot enforce sandbox read-only path .../.git because it crosses
    # writable symlink ...". The real store is already a root, so the legacy entry just goes.
    if [ -L "$OLD_STORE" ] && store_in_sandbox_roots "$OLD_STORE"; then
        if [ "$CHECK" = 1 ]; then
            echo "ACTION    $CODEX_CFG: writable_roots contains \"$OLD_STORE\", which is a symlink; codex cannot build its bubblewrap sandbox with a symlinked writable root — remove that entry (\"$STORE_DIR\" already covers it)." >&2; status=1
        elif remove_sandbox_root "$OLD_STORE"; then
            echo "config    $CODEX_CFG: removed symlinked legacy root \"$OLD_STORE\" from writable_roots (codex cannot sandbox a symlinked writable root; previous file backed up)"
        else
            echo "ACTION    $CODEX_CFG: could not remove \"$OLD_STORE\" from writable_roots automatically; remove it by hand — codex cannot build its sandbox while a symlinked root is listed." >&2
        fi
    fi
elif [ "$CHECK" = 1 ]; then
    echo "MISSING   $CODEX_CFG: [sandbox_workspace_write] writable_roots for $STORE_DIR"; status=1
else
    mkdir -p "$(dirname "$CODEX_CFG")"
    { [ -f "$CODEX_CFG" ] && [ -n "$(tail -c1 "$CODEX_CFG")" ] && echo; printf '\n[sandbox_workspace_write]\nwritable_roots = ["%s"]\nnetwork_access = true\n' "$STORE_DIR"; } >> "$CODEX_CFG"
    echo "config    $CODEX_CFG: added [sandbox_workspace_write] writable_roots = [\"$STORE_DIR\"] and network_access = true (Codex sandbox may write the store and reach Claude)"
fi

# --- Codex side, default form: the true Codex plugin from this repo's marketplace ----------
if [ "$CHECK" = 0 ] && [ "$SKILLS" = 0 ]; then
    if [ -L "$CODEX_SKILL_LINK" ]; then rm -f -- "$CODEX_SKILL_LINK"; echo "retired   $CODEX_SKILL_LINK (the Codex skill now comes from the plugin)"
    elif [ -e "$CODEX_SKILL_LINK" ]; then
        mkdir -p "$BACKUP_DIR"; bak="$(backup_path secondopinion-request)"
        mv -T -- "$CODEX_SKILL_LINK" "$bak"; echo "backed-up $CODEX_SKILL_LINK -> $bak (the Codex skill now comes from the plugin)"
    fi
    cmr="$(codex_marketplace_root)"
    if [ -n "$cmr" ] && [ "$cmr" != "$REPO_ROOT" ]; then
        codex plugin marketplace remove "$MARKETPLACE" >/dev/null 2>&1 || true; echo "removed   stale Codex marketplace $MARKETPLACE -> $cmr"; cmr=""
    fi
    if [ -z "$cmr" ]; then
        codex plugin marketplace add "$REPO_ROOT" >/dev/null 2>&1 || { echo "ERROR: codex plugin marketplace add $REPO_ROOT failed" >&2; exit 1; }
        echo "added     Codex marketplace $MARKETPLACE -> $REPO_ROOT"
    fi
    refresh_codex
    if ! codex_plugin_current; then
        codex_plugin_present && { codex plugin remove "$PLUGIN_ID" >/dev/null 2>&1 || true; }
        codex plugin add "$PLUGIN_ID" >/dev/null 2>&1 || { echo "ERROR: codex plugin add $PLUGIN_ID failed" >&2; exit 1; }
        refresh_codex
    fi
    if codex_plugin_current; then
        echo "ok        Codex plugin $PLUGIN_ID $VERSION enabled from $REPO_ROOT (restart Codex to apply)"
    else
        echo "ERROR: Codex plugin verification failed: state='$CODEX_STATE' marketplace='$CODEX_MARKET_ROOT' (want '$VERSION true' from $REPO_ROOT)" >&2; exit 1
    fi
fi

# --- Claude side, only with --claude in plugin form: the Claude Code plugin ----------------
if [ "$CHECK" = 0 ] && [ "$CLAUDE" = 1 ] && [ "$SKILLS" = 0 ]; then
    mp="$(marketplace_path)"
    if [ -n "$mp" ] && [ "$mp" != "$REPO_ROOT" ]; then
        # A marketplace of our name pointing elsewhere (moved or stale checkout): replace it.
        claude plugin marketplace remove "$MARKETPLACE" >/dev/null 2>&1 || true
        echo "removed   stale marketplace $MARKETPLACE -> $mp"; mp=""
    fi
    if [ -z "$mp" ]; then
        claude plugin marketplace add "$REPO_ROOT" >/dev/null || { echo "ERROR: claude plugin marketplace add $REPO_ROOT failed" >&2; exit 1; }
        echo "added     marketplace $MARKETPLACE -> $REPO_ROOT"
    else
        claude plugin marketplace update "$MARKETPLACE" >/dev/null || { echo "ERROR: claude plugin marketplace update $MARKETPLACE failed" >&2; exit 1; }
        echo "ok        marketplace $MARKETPLACE ($REPO_ROOT) refreshed"
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
        echo "ok        Claude plugin $PLUGIN_ID $VERSION enabled from $REPO_ROOT (skill: /secondopinion:secondopinion-respond; restart Claude Code to apply)"
    else
        echo "ERROR: plugin verification failed: state='$(plugin_state)' marketplace='$(marketplace_path)' (want '$VERSION true' from $REPO_ROOT)" >&2; exit 1
    fi
fi
if [ "$CHECK" = 1 ]; then
    [ "${INSPECT_FAILED:-0}" = 1 ] && status=1
    # Codex side: REQUIRED, in exactly one current form. A plugin in ANY state next to a
    # skill link/dir is a duplicate; a stale plugin is reported even when a current skill
    # symlink exists (the symlink must not mask it). An uninspectable registry was already
    # reported as UNINSPECTABLE — say nothing contradictory for that side.
    if [ "$CODEX_INSPECT" = "error" ]; then :
    elif codex_plugin_present && { [ -e "$CODEX_SKILL_LINK" ] || [ -L "$CODEX_SKILL_LINK" ]; }; then
        echo "DUPLICATE the Codex plugin $PLUGIN_ID (state='$CODEX_STATE') and the skill path $CODEX_SKILL_LINK are both present; run install.sh (plugin) or install.sh --skills to pick one" >&2; status=1
    elif codex_plugin_current; then echo "ok        Codex side: plugin $PLUGIN_ID $VERSION"
    elif codex_plugin_present; then echo "STALE     Codex plugin $PLUGIN_ID is installed but is not '$VERSION enabled from $REPO_ROOT' (state='$CODEX_STATE', marketplace='$CODEX_MARKET_ROOT'); run install.sh" >&2; status=1
    elif link_ok "$CODEX_SKILL_LINK" "$ROOT/skills/secondopinion-request"; then echo "ok        Codex side: skill symlink $CODEX_SKILL_LINK"
    elif [ -e "$CODEX_SKILL_LINK" ] || [ -L "$CODEX_SKILL_LINK" ]; then
        echo "STALE     Codex side: $CODEX_SKILL_LINK exists but is not a symlink to $ROOT/skills/secondopinion-request; run install.sh or install.sh --skills" >&2; status=1
    else echo "MISSING   Codex side: neither the Codex plugin $PLUGIN_ID nor the skill symlink $CODEX_SKILL_LINK; run install.sh (plugin) or install.sh --skills" >&2; status=1
    fi
    # Claude side: OPTIONAL — absent is fine (headless ask needs only the claude CLI);
    # anything that IS present must be current and unique, with the same masking rules.
    if [ "$PLUGIN_INSPECT" = "error" ]; then :
    elif plugin_present && { [ -e "$CLAUDE_SKILL_LINK" ] || [ -L "$CLAUDE_SKILL_LINK" ]; }; then
        echo "DUPLICATE the Claude plugin $PLUGIN_ID (state='$(plugin_state)') and the user-level skill path $CLAUDE_SKILL_LINK are both present; run install.sh --claude or install.sh --skills --claude to pick one" >&2; status=1
    elif plugin_current; then echo "ok        Claude side: plugin $PLUGIN_ID $VERSION (skill /secondopinion:secondopinion-respond)"
    elif plugin_present; then echo "STALE     Claude plugin $PLUGIN_ID is installed but is not '$VERSION enabled from $REPO_ROOT' (state='$(plugin_state)', marketplace='$(marketplace_path)'); run install.sh --claude (or plain install.sh to remove it)" >&2; status=1
    elif link_ok "$CLAUDE_SKILL_LINK" "$ROOT/skills/secondopinion-respond"; then echo "ok        Claude side: user-level skill $CLAUDE_SKILL_LINK (skill /secondopinion-respond)"
    elif [ -e "$CLAUDE_SKILL_LINK" ] || [ -L "$CLAUDE_SKILL_LINK" ]; then
        echo "STALE     Claude side: $CLAUDE_SKILL_LINK exists but is not a symlink to $ROOT/skills/secondopinion-respond; run install.sh (retires it) or install.sh --skills --claude" >&2; status=1
    else echo "ok        Claude side: nothing installed (optional — headless ask needs only the claude CLI on PATH)"
    fi
fi

case ":$PATH:" in
    *":$HOME/.local/bin:"*) ;;
    *) echo "WARNING: $HOME/.local/bin is not on PATH in this shell; add it so 'secondopinion' resolves." >&2
       [ "$CHECK" = 1 ] && status=1;;
esac

if [ "$CHECK" = 1 ]; then
    python3 -B "$ROOT/scripts/wake_service.py" check --store "$STORE_DIR" || status=1
    [ "$status" = 0 ] && echo "installed=yes" || echo "installed=no"
else
    if [ "$SKILLS" = 0 ]; then
        python3 -B "$ROOT/scripts/wake_service.py" install --store "$STORE_DIR" || status=1
    fi
    echo "done: restart Codex sessions to load the plugin/skill (and Claude Code, if --claude was used)"
fi
exit "$status"
