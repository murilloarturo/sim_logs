#!/usr/bin/env bash
# install-skill.sh — install the sim-console Claude Code skill.
#
# Symlinks $REPO/.claude/skill/SKILL.md to ~/.claude/skills/sim-console/SKILL.md
# so any Claude Code session can invoke /sim-console.
#
# Idempotent — safe to re-run after a `git pull`.

set -euo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
SRC="$REPO/.claude/skill/SKILL.md"
DEST_DIR="$HOME/.claude/skills/sim-console"
DEST="$DEST_DIR/SKILL.md"

if [ ! -f "$SRC" ]; then
  echo "✗ source skill not found at $SRC" >&2
  echo "  (are you running this from a sim_logs checkout?)" >&2
  exit 1
fi

mkdir -p "$DEST_DIR"

if [ -L "$DEST" ]; then
  current=$(readlink "$DEST")
  if [ "$current" = "$SRC" ]; then
    echo "✓ skill already installed → $DEST"
    echo "  source: $SRC"
    exit 0
  fi
  echo "→ replacing existing symlink ($current)"
  rm "$DEST"
elif [ -e "$DEST" ]; then
  echo "✗ $DEST exists and is not a symlink." >&2
  echo "  back it up and remove it, then re-run." >&2
  exit 1
fi

ln -s "$SRC" "$DEST"
echo "✓ installed skill → $DEST"
echo "  source: $SRC"
echo ""
echo "Use it with /sim-console in any Claude Code session."
