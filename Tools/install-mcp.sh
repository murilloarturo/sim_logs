#!/usr/bin/env bash
# install-mcp.sh — register the sim_logs MCP server with Claude Code so an
# agent can query the live event buffer (network requests, analytics, logs).
#
# Idempotent — safe to re-run. Requires:
#   - `claude` CLI on PATH (Claude Code)
#   - `uv` on PATH (Homebrew: `brew install uv`) — used by the server's PEP 723
#     shebang to resolve `mcp[cli]` into an isolated env on first run

set -euo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
SERVER="$REPO/Tools/mcp-server/server.py"
NAME="sim-console"

if [ ! -x "$SERVER" ]; then
  echo "✗ server not found or not executable: $SERVER" >&2
  exit 1
fi

if ! command -v claude >/dev/null 2>&1; then
  echo "✗ Claude Code CLI ('claude') not found on PATH." >&2
  echo "  Install it from https://claude.com/claude-code and re-run." >&2
  exit 1
fi

if ! command -v uv >/dev/null 2>&1; then
  echo "✗ 'uv' not found on PATH." >&2
  echo "  Install with: brew install uv" >&2
  exit 1
fi

# Already added? Don't trip over duplicate-add errors — remove first, re-add fresh.
if claude mcp list 2>&1 | grep -qE "^${NAME}: "; then
  echo "→ replacing existing MCP server '$NAME'"
  claude mcp remove "$NAME" >/dev/null 2>&1 || true
fi

claude mcp add "$NAME" -- "$SERVER"

echo ""
echo "✓ Registered MCP server '$NAME' → $SERVER"
echo ""
echo "Tools available to agents:"
echo "  • list_recent_requests(filter, status_min, status_max, method, limit)"
echo "  • get_request(id)"
echo "  • list_recent_analytics(filter, kinds, since_seconds, limit)"
echo "  • list_recent_logs(filter, levels, since_seconds, limit)"
echo "  • stats()"
echo "  • clear()"
echo ""
echo "Open a fresh Claude Code session — the tools surface as mcp__sim_logs__*."
echo ""
echo "Export file: \${SIM_CONSOLE_EXPORT:-~/.sim-console/events.jsonl}"
echo "Populated automatically whenever sim-console runs."
