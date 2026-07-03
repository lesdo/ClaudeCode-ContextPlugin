#!/bin/bash
# pre-compact.sh — PreCompact hook: 简报快照到 DB + 落盘到文件
set -euo pipefail
# 文件落盘确保 compaction 后上下文存活（即使 DB 不可用）
CLAUDE_PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
source "${CLAUDE_PLUGIN_ROOT}/hooks/lib/_common.sh"
detect_project_dir "$1"

MCP_CLI="${CLAUDE_PLUGIN_ROOT}/scripts/mcp-cli.sh"
BRIEFING_DIR="$PROJECT_DIR/.claude/context/briefing"
BRIEFING_FILE="$BRIEFING_DIR/active.md"

mkdir -p "$BRIEFING_DIR"

# 优先从 DB 生成简报
if [ -x "$MCP_CLI" ] 2>/dev/null; then
  BRIEFING=$(bash "$MCP_CLI" "$PROJECT_DIR" briefing_generate 2>/dev/null || echo "")
  if [ -n "$BRIEFING" ] && [ "$BRIEFING" != "null" ]; then
    echo "$BRIEFING" > "$BRIEFING_FILE"
    exit 0
  fi
fi

# DB 不可用时的最小 fallback: 从文件系统生成摘要
{
  echo "Project: $(basename "$PROJECT_DIR")"
  echo ""
  echo "Stats: 简报生成于 $(date +%Y-%m-%dT%H:%M:%S)"
  echo ""
  echo "> DB 不可用，此为文件系统最小摘要。"
} > "$BRIEFING_FILE"

exit 0
