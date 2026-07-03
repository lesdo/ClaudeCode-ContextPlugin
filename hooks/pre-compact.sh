#!/bin/bash
# pre-compact.sh — PreCompact hook: snapshot context state to DB
CLAUDE_PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
source "${CLAUDE_PLUGIN_ROOT}/hooks/lib/_common.sh"
detect_project_dir "$1"
MCP_CLI="${CLAUDE_PLUGIN_ROOT}/scripts/mcp-cli.sh"
if [ -x "$MCP_CLI" ] 2>/dev/null; then
  bash "$MCP_CLI" "$PROJECT_DIR" briefing_generate 2>/dev/null || true
fi
exit 0
