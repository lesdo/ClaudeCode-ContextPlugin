#!/bin/bash
# memory-capture.sh — Stop hook: 分析会话→提取记忆→写入 SQLite
set -euo pipefail
# 替代 AI 手动填充会话文件 (bug#6)
# 清理 .current-session 指针 (bug#3)
#
# 用法: bash memory-capture.sh [project_dir]

CLAUDE_PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
source "${CLAUDE_PLUGIN_ROOT}/hooks/lib/_common.sh"
detect_project_dir "$1"

MCP_CLI="${CLAUDE_PLUGIN_ROOT}/scripts/mcp-cli.sh"
SESSIONS_DIR="$PROJECT_DIR/.claude/context/sessions"
POINTER="$SESSIONS_DIR/.current-session"

# ── 1. 结束当前会话 ──────────────────────────────────
SUMMARY="${2:-}"  # 可选：AI 提供的摘要
EXIT_CODE="${3:-0}"

echo "memory-capture: 结束会话..."

if [ -x "$MCP_CLI" ] 2>/dev/null; then
  # 通过 DB 结束会话
  RESULT=$(bash "$MCP_CLI" "$PROJECT_DIR" session_finalize \
    "{\"summary\":\"$SUMMARY\",\"exit_code\":$EXIT_CODE}" 2>/dev/null || echo '{}')
  SESSION_ID=$(echo "$RESULT" | python3 -c "import sys,json; print(json.load(sys.stdin).get('id',''))" 2>/dev/null || echo "")
  DURATION=$(echo "$RESULT" | python3 -c "import sys,json; print(json.load(sys.stdin).get('duration_min',''))" 2>/dev/null || echo "")

  if [ -n "$SESSION_ID" ]; then
    echo "  DB 会话已结束: $SESSION_ID (${DURATION:-?} 分钟)"

    # 提取事件计数
    EVENTS=$(bash "$MCP_CLI" "$PROJECT_DIR" session_events \
      "{\"session_id\":\"$SESSION_ID\",\"limit\":5}" 2>/dev/null || echo '[]')
    EVENT_COUNT=$(echo "$EVENTS" | python3 -c "import sys,json; print(len(json.load(sys.stdin)))" 2>/dev/null || echo "0")
    echo "  事件: ${EVENT_COUNT} 条记录"
  fi
fi

# ── 2. 清理 .current-session (bug#3) ──────────────────
if [ -f "$POINTER" ]; then
  rm -f "$POINTER"
  echo "  .current-session 已清理"
fi

# ── 3. 运行衰减清理 (每次会话结束时) ──────────────────
if [ -x "$MCP_CLI" ] 2>/dev/null; then
  DECAY=$(bash "$MCP_CLI" "$PROJECT_DIR" decay_run 2>/dev/null || echo '{}')
  echo "  衰减清理: $(echo "$DECAY" | python3 -c "import sys,json; d=json.load(sys.stdin); print(f'归档{d.get(\"archived\",0)}/删除{d.get(\"deleted\",0)}')" 2>/dev/null || echo '完成')"
fi

echo "memory-capture: 完成"
