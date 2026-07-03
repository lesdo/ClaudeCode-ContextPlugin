#!/bin/bash
# post-compact.sh — PostCompact hook: 从文件 + DB 恢复关键上下文
# 文件优先（compaction 前 pre-compact 写入，compaction 后必然存在）
# DB 作为补充（可能有更新的数据）
CLAUDE_PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
source "${CLAUDE_PLUGIN_ROOT}/hooks/lib/_common.sh"
detect_project_dir "$1"

MCP_CLI="${CLAUDE_PLUGIN_ROOT}/scripts/mcp-cli.sh"
BRIEFING_FILE="$PROJECT_DIR/.claude/context/briefing/active.md"

echo "=== 恢复上下文 (post-compact) ==="
echo ""

# 1. 文件简报（compaction 前保存，必然存在）
if [ -f "$BRIEFING_FILE" ] && [ -s "$BRIEFING_FILE" ]; then
  echo "--- 会话简报 ---"
  cat "$BRIEFING_FILE"
  echo ""
else
  echo "（简报文件缺失）"
  echo ""
fi

# 2. DB 补充（可能有 compaction 期间新写入的数据）
if [ -x "$MCP_CLI" ] 2>/dev/null; then
  DB_BRIEFING=$(bash "$MCP_CLI" "$PROJECT_DIR" briefing_get 2>/dev/null || echo "")
  if [ -n "$DB_BRIEFING" ] && [ "$DB_BRIEFING" != "null" ]; then
    # 仅当 DB 简报与文件简报不同时才输出
    if [ ! -f "$BRIEFING_FILE" ] || ! diff -q <(echo "$DB_BRIEFING") "$BRIEFING_FILE" >/dev/null 2>&1; then
      echo "--- DB 补充 ---"
      echo "$DB_BRIEFING"
      echo ""
    fi
  fi
fi

echo "> 使用 memory_search 获取更多细节。"
exit 0
