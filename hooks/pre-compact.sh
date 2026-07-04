#!/bin/bash
# pre-compact.sh — PreCompact hook: 简报快照
# 在 compaction 销毁上下文前保存会话简报
# 不碰会话状态 — 生杀权归 wrapper
set -uo pipefail  # fail-open: errors logged, always exit 0
CLAUDE_PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
source "${CLAUDE_PLUGIN_ROOT}/hooks/lib/_common.sh"
detect_project_dir "${1:-}"

MCP_CLI="${CLAUDE_PLUGIN_ROOT}/scripts/mcp-cli.sh"
BRIEFING_DIR="$PROJECT_DIR/.context/briefing"
BRIEFING_FILE="$BRIEFING_DIR/active.md"

mkdir -p "$BRIEFING_DIR"

# ── 简报快照到 DB + 落盘文件 ──
if [ -x "$MCP_CLI" ] 2>/dev/null; then
  BRIEFING=$(bash "$MCP_CLI" "$PROJECT_DIR" briefing_generate 2>/dev/null || echo "")
  if [ -n "$BRIEFING" ] && [ "$BRIEFING" != "null" ]; then
    echo "$BRIEFING" > "$BRIEFING_FILE"
    exit 0
  fi
fi

# DB 不可用时的最小 fallback: 文件系统摘要
{
  echo "Project: $(basename "$PROJECT_DIR")"
  echo ""
  echo "Stats: 简报生成于 $(date +%Y-%m-%dT%H:%M:%S)"
  echo ""
  echo "> DB 不可用，此为文件系统最小摘要。"
} > "$BRIEFING_FILE"

exit 0
