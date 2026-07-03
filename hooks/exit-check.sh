#!/bin/bash
# 退出前检查 — 查询会话完整性，输出状态事实
set -euo pipefail
# 纯查询，无副作用，始终 exit 0
# 用法: bash ~/.claude/tools/exit-check.sh [项目目录]
# 测试: bash ~/.claude/tools/exit-check.sh [项目目录]

CLAUDE_PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
source "${CLAUDE_PLUGIN_ROOT}/hooks/lib/_common.sh"
detect_project_dir "$1"

# 守护: 位于 .claude/context/ 下的目录是数据目录
case "$PROJECT_DIR" in
  *"/.claude/context/"*)
    echo "STATE: guard_skip"
    echo "REASON: data_directory"
    exit 0
    ;;
esac

SESSIONS_DIR="$PROJECT_DIR/.claude/context/sessions"

# ── 无会话目录 ──────────────────────────────
if [ ! -d "$SESSIONS_DIR" ]; then
  echo "STATE: no_sessions"
  echo "SESSION_DIR: ${SESSIONS_DIR}"
  exit 0
fi

# ── 最新会话文件 ────────────────────────────
# 优先从 .current-session 指针读取（session-start.sh 已写入），O(1)
CURRENT_PTR="$SESSIONS_DIR/.current-session"
if [ -f "$CURRENT_PTR" ]; then
  LATEST=$(cat "$CURRENT_PTR" 2>/dev/null)
fi
# 回退：指针不存在时用 ls（兼容旧会话目录）
if [ -z "$LATEST" ] || [ ! -f "$LATEST" ]; then
  LATEST=$(ls -t "$SESSIONS_DIR"/*.md 2>/dev/null | grep -E '/[0-9]{4}-[0-9]{2}-[0-9]{2}_[0-9]{4,6}\.md$' | head -1)
fi

if [ -z "$LATEST" ]; then
  echo "STATE: no_sessions"
  echo "SESSION_DIR: ${SESSIONS_DIR}"
  exit 0
fi

SESSION_NAME=$(basename "$LATEST")
echo "SESSION_FILE: ${SESSION_NAME}"

# ── 检查取证日志（新:.log 优先，旧:.md 内 grep 兼容）──
AUTO_LOG="no"
SESSION_LOG="${LATEST%.md}.log"
if [ -s "$SESSION_LOG" ]; then
  AUTO_LOG="yes"
elif grep -qE '^- [0-9]{2}:[0-9]{2}:[0-9]{2} (Edit|Write|Bash) ' "$LATEST" 2>/dev/null; then
  AUTO_LOG="yes"
fi
echo "AUTO_LOG: ${AUTO_LOG}"

# ── 检查摘要 ────────────────────────────────
if grep -qE '^\*\*摘要\*\*: （待填充）$' "$LATEST" 2>/dev/null; then
  SUMMARY_STATE="empty"
else
  # 也检查旧格式
  if grep -qE '^（待填充）$' "$LATEST" 2>/dev/null; then
    SUMMARY_STATE="empty"
  else
    SUMMARY_STATE="filled"
  fi
fi
echo "SUMMARY: ${SUMMARY_STATE}"

# ── 汇总状态 ────────────────────────────────
if [ "$AUTO_LOG" = "no" ] && [ "$SUMMARY_STATE" = "empty" ]; then
  echo "STATE: skeleton"
elif [ "$SUMMARY_STATE" = "empty" ]; then
  echo "STATE: needs_summary"
else
  echo "STATE: complete"
fi

# Phase B: SQLite 补充检查（并行读取，不影响现有逻辑）
MCP_CLI="${CLAUDE_PLUGIN_ROOT}/scripts/mcp-cli.sh"
if [ -x "$MCP_CLI" ] 2>/dev/null; then
  DB_STATS=$(bash "$MCP_CLI" "$PROJECT_DIR" stats_overview 2>/dev/null || echo "")
  if [ -n "$DB_STATS" ] && [ "$DB_STATS" != "null" ]; then
    echo "DB_CHECK: available"
    echo "DB_STATS: $(echo "$DB_STATS" | python3 -c "import sys,json; d=json.load(sys.stdin); print(f'sessions={d.get(\"total_sessions\",\"?\")},memories={d.get(\"total_memories\",\"?\")},events={d.get(\"total_events\",\"?\")}')" 2>/dev/null || echo "?")"
  else
    echo "DB_CHECK: unavailable"
  fi
fi
