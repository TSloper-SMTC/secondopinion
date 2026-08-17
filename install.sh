#!/bin/bash
# install.sh — link the agent-mailbox tool and both skills into the user's home.
#   install.sh          install/refresh symlinks (existing real dirs are backed up, never deleted)
#   install.sh --check  report status; exit 0 if fully installed, 1 otherwise
set -euo pipefail

if [ -z "${HOME:-}" ]; then
    echo "ERROR: HOME is not set; cannot locate ~/.local/bin, ~/.claude/skills or ~/.codex/skills." >&2
    exit 1
fi
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Backups of replaced real dirs/files go OUTSIDE the skills trees, otherwise a
# backed-up SKILL.md is discovered as a duplicate skill.
BACKUP_DIR="${AGENT_MAILBOX_BACKUP_DIR:-$ROOT/backups}"
CHECK=0
[ "${1:-}" = "--check" ] && CHECK=1

# dest -> source
LINKS=(
    "$HOME/.local/bin/agent-mailbox|$ROOT/bin/agent-mailbox"
    "$HOME/.claude/skills/codex-mailbox|$ROOT/skills/claude/codex-mailbox"
    "$HOME/.codex/skills/claude-mailbox|$ROOT/skills/codex/claude-mailbox"
)

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
STORE_DIR="${AGENT_MAILBOX_DIR:-$HOME/.agent-mailbox}"
CODEX_CFG="$HOME/.codex/config.toml"
if [ "$CHECK" != 1 ]; then
    mkdir -p "$STORE_DIR"; chmod 700 "$STORE_DIR"
fi
if [ -f "$CODEX_CFG" ] && grep -q '^\[sandbox_workspace_write\]' "$CODEX_CFG"; then
    if grep -q "^writable_roots *=.*\"$STORE_DIR\"" "$CODEX_CFG"; then
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
