#!/bin/bash
# install.sh — link the agent-mailbox tool and skills into the user's home.
#   install.sh           skill mode: symlink the CLI and BOTH skills (Claude skill = /codex-mailbox)
#   install.sh --plugin  plugin mode: symlink the CLI and the Codex skill; install the Claude side as
#                        the Claude Code plugin agent-mailbox@agent-mailbox (/agent-mailbox:codex-mailbox)
#                        via `claude plugin marketplace add` + `claude plugin install`, and retire a
#                        user-level ~/.claude/skills/codex-mailbox symlink so the skill is not duplicated
#   install.sh --check   report status; exit 0 if fully installed (either mode), 1 otherwise
set -euo pipefail

if [ -z "${HOME:-}" ]; then
    echo "ERROR: HOME is not set; cannot locate ~/.local/bin, ~/.claude/skills or ~/.codex/skills." >&2
    exit 1
fi
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Backups of replaced real dirs/files go OUTSIDE the skills trees, otherwise a
# backed-up SKILL.md is discovered as a duplicate skill.
BACKUP_DIR="${AGENT_MAILBOX_BACKUP_DIR:-$ROOT/backups}"
CHECK=0; PLUGIN=0
case "$#:${1:-}" in
    0:) ;;
    1:--check) CHECK=1;;
    1:--plugin) PLUGIN=1;;
    1:-h|1:--help) sed -n '2,8p' "$0"; exit 0;;
    *) echo "usage: install.sh [--check|--plugin]   (unknown or surplus argument: '$*')" >&2; exit 1;;
esac
PLUGIN_ID="agent-mailbox@agent-mailbox"
CLAUDE_SKILL_LINK="$HOME/.claude/skills/codex-mailbox"
STORE_DIR="${AGENT_MAILBOX_DIR:-$HOME/.agent-mailbox}"
CODEX_CFG="$HOME/.codex/config.toml"
# The store path is written into TOML as a quoted string: refuse anything that
# cannot be represented verbatim (quotes, backslashes, control characters).
case "$STORE_DIR" in
    *[\"\\]*|*[[:cntrl:]]*) echo "ERROR: store path '$STORE_DIR' contains a quote, backslash or control character; choose another AGENT_MAILBOX_DIR." >&2; exit 1;;
esac

plugin_installed() { command -v claude >/dev/null 2>&1 && claude plugin list 2>/dev/null | grep -q "^ *❯ *$PLUGIN_ID\b\|$PLUGIN_ID"; }
marketplace_present() { claude plugin marketplace list 2>/dev/null | grep -q "agent-mailbox"; }

# dest -> source
LINKS=(
    "$HOME/.local/bin/agent-mailbox|$ROOT/bin/agent-mailbox"
    "$HOME/.codex/skills/claude-mailbox|$ROOT/skills/codex/claude-mailbox"
)
# The Claude skill is a symlink in skill mode; in plugin mode it comes from the plugin.
# --check accepts either form.
if [ "$PLUGIN" = 0 ] && ! { [ "$CHECK" = 1 ] && plugin_installed; }; then
    LINKS+=("$CLAUDE_SKILL_LINK|$ROOT/skills/claude/codex-mailbox")
fi

status=0
for pair in "${LINKS[@]}"; do
    dest="${pair%%|*}"; src="${pair#*|}"
    if [ -L "$dest" ] && [ "$(readlink -f "$dest")" = "$(readlink -f "$src")" ]; then
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
        mkdir -p "$BACKUP_DIR"
        bak="$BACKUP_DIR/$(basename "$dest").bak-$(date -u +%Y%m%dT%H%M%SZ)"
        mv -- "$dest" "$bak"
        echo "backed-up $dest -> $bak"
    fi
    ln -s "$src" "$dest"
    echo "linked    $dest -> $src"
done

# --- Codex sandbox: the store must be a writable root, or Codex's workspace-write
# sandbox sees $HOME read-only and `agent-mailbox new` fails ("Read-only file system").
if [ "$CHECK" != 1 ]; then
    mkdir -p "$STORE_DIR"; chmod 700 "$STORE_DIR"
fi
if [ -f "$CODEX_CFG" ] && grep -q '^\[sandbox_workspace_write\]' "$CODEX_CFG"; then
    if grep -E '^writable_roots *=' "$CODEX_CFG" | grep -Fq "\"$STORE_DIR\""; then
        echo "ok        $CODEX_CFG: [sandbox_workspace_write] writable_roots includes $STORE_DIR"
    else
        echo "ACTION    $CODEX_CFG already has a [sandbox_workspace_write] table; add \"$STORE_DIR\" to its writable_roots array by hand (not edited automatically)." >&2
        [ "$CHECK" = 1 ] && status=1
    fi
elif [ "$CHECK" = 1 ]; then
    echo "MISSING   $CODEX_CFG: [sandbox_workspace_write] writable_roots for $STORE_DIR"; status=1
else
    mkdir -p "$(dirname "$CODEX_CFG")"
    { [ -f "$CODEX_CFG" ] && [ -n "$(tail -c1 "$CODEX_CFG")" ] && echo; printf '\n[sandbox_workspace_write]\nwritable_roots = ["%s"]\n' "$STORE_DIR"; } >> "$CODEX_CFG"
    echo "config    $CODEX_CFG: added [sandbox_workspace_write] writable_roots = [\"$STORE_DIR\"] (Codex sandbox may write the store)"
fi

# --- plugin mode: Claude side through the plugin system --------------------------------
if [ "$PLUGIN" = 1 ]; then
    command -v claude >/dev/null 2>&1 || { echo "ERROR: --plugin needs the 'claude' CLI on PATH." >&2; exit 1; }
    if [ -L "$CLAUDE_SKILL_LINK" ]; then
        rm -f "$CLAUDE_SKILL_LINK"; echo "retired   $CLAUDE_SKILL_LINK (user-level skill would duplicate the plugin skill)"
    elif [ -e "$CLAUDE_SKILL_LINK" ]; then
        mkdir -p "$BACKUP_DIR"; bak="$BACKUP_DIR/codex-mailbox.bak-$(date -u +%Y%m%dT%H%M%SZ)"
        mv -- "$CLAUDE_SKILL_LINK" "$bak"; echo "backed-up $CLAUDE_SKILL_LINK -> $bak"
    fi
    if marketplace_present; then
        claude plugin marketplace update agent-mailbox >/dev/null 2>&1 || true
        echo "ok        marketplace agent-mailbox ($ROOT) refreshed"
    else
        claude plugin marketplace add "$ROOT" >/dev/null || { echo "ERROR: claude plugin marketplace add $ROOT failed" >&2; exit 1; }
        echo "added     marketplace agent-mailbox -> $ROOT"
    fi
    if plugin_installed; then
        claude plugin update "$PLUGIN_ID" >/dev/null 2>&1 || true
        echo "ok        plugin $PLUGIN_ID updated (restart Claude Code to apply)"
    else
        claude plugin install "$PLUGIN_ID" >/dev/null || { echo "ERROR: claude plugin install $PLUGIN_ID failed" >&2; exit 1; }
        echo "installed plugin $PLUGIN_ID (skill: /agent-mailbox:codex-mailbox)"
    fi
fi
if [ "$CHECK" = 1 ]; then
    if plugin_installed; then echo "ok        Claude side: plugin $PLUGIN_ID (skill /agent-mailbox:codex-mailbox)"
    elif [ -L "$CLAUDE_SKILL_LINK" ]; then echo "ok        Claude side: user-level skill $CLAUDE_SKILL_LINK (skill /codex-mailbox)"
    fi
fi

case ":$PATH:" in
    *":$HOME/.local/bin:"*) ;;
    *) echo "WARNING: $HOME/.local/bin is not on PATH in this shell; add it so 'agent-mailbox' resolves." >&2
       [ "$CHECK" = 1 ] && status=1;;
esac

if [ "$CHECK" = 1 ]; then
    [ "$status" = 0 ] && echo "installed=yes" || echo "installed=no"
else
    echo "done: restart Claude Code / Codex sessions to load the skills"
fi
exit "$status"
