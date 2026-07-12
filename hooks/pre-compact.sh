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
MCP_HEALTH=$(mcp_health_check "$PROJECT_DIR" "$MCP_CLI")
if [ "$MCP_HEALTH" = "ok" ]; then
  BRIEFING=$(bash "$MCP_CLI" "$PROJECT_DIR" briefing_generate 2>/dev/null)
  BRIEF_EXIT=$?
  if [ $BRIEF_EXIT -ne 0 ]; then
    echo "pre-compact: 简报生成失败 (exit=$BRIEF_EXIT)，降级到最小摘要"
  elif [ -n "$BRIEFING" ] && [ "$BRIEFING" != "null" ]; then
    echo "$BRIEFING" > "$BRIEFING_FILE"
    exit 0
  fi
else
  echo "pre-compact: MCP 不可用（${MCP_HEALTH}），降级到文件系统摘要"
fi

# Fallback: 文件系统最小摘要（标注降级原因）
{
  echo "Project: $(basename "$PROJECT_DIR")"
  echo ""
  echo "Stats: 简报生成于 $(date +%Y-%m-%dT%H:%M:%S)"
  echo "Health: MCP=${MCP_HEALTH:-unknown}"
  echo ""
  echo "> DB 不可用或简报生成失败，此为文件系统最小摘要。post-compact 将使用此文件恢复。"
} > "$BRIEFING_FILE"

exit 0
