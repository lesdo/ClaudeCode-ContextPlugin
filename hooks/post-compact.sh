#!/bin/bash
# post-compact.sh — PostCompact hook: re-inject critical context after compaction
CLAUDE_PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
source "${CLAUDE_PLUGIN_ROOT}/hooks/lib/_common.sh"
detect_project_dir "$1"
MCP_CLI="${CLAUDE_PLUGIN_ROOT}/scripts/mcp-cli.sh"
if [ -x "$MCP_CLI" ] 2>/dev/null; then
  BRIEFING=$(bash "$MCP_CLI" "$PROJECT_DIR" briefing_get 2>/dev/null || echo "")
  if [ -n "$BRIEFING" ] && [ "$BRIEFING" != "null" ]; then
    echo "=== 恢复上下文 (post-compact) ==="
    echo "$BRIEFING"
    echo "> 使用 memory_search 获取更多细节。"
  fi
fi
exit 0
