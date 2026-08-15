#!/bin/bash
# install.sh — link the agent-mailbox tool and both skills into the user's home.
#   install.sh          install/refresh symlinks (existing real dirs are backed up, never deleted)
#   install.sh --check  report status; exit 0 if fully installed, 1 otherwise
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
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
        bak="$dest.bak-$(date -u +%Y%m%dT%H%M%SZ)"
        mv -- "$dest" "$bak"
        echo "backed-up $dest -> $bak"
    fi
    ln -s "$src" "$dest"
    echo "linked    $dest -> $src"
done

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
