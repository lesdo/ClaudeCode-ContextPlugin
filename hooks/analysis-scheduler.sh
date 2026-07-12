#!/bin/bash
# v4.0: 分析调度器 — 每 N 会话触发定量分析 + 画像聚合
# 注册为 SessionStart hook，独立于 session-start.sh
# 不阻塞主流程（快速退出），不做定性分析（零 token 成本）
#
# Phase 1: 每 3 会话触发
# Phase 2: 降为每周（条件: ≥3 轮结果且连续 2 轮无显著变化）

set -euo pipefail

CLAUDE_PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
source "${CLAUDE_PLUGIN_ROOT}/hooks/lib/_common.sh"
detect_project_dir "${1:-}"

# ── 快速门控 ─────────────────────────────────────
CONTEXT_DIR="${PROJECT_DIR}/.claude/context"
STATE_FILE="${CONTEXT_DIR}/.analysis-state"
MCP_CLI="${CLAUDE_PLUGIN_ROOT}/scripts/mcp-cli.sh"

mkdir -p "$CONTEXT_DIR"

# 获取当前会话序号（从 sessions 表总数）
CURRENT_COUNT=$(python3 -c "
import sys, os
sys.path.insert(0, os.path.join(os.path.dirname('${MCP_CLI}'), '..', 'mcp'))
from db_core import get_db
with get_db('${PROJECT_DIR}') as conn:
    c = conn.execute('SELECT COUNT(*) FROM sessions').fetchone()[0]
    print(c)
" 2>/dev/null || echo "0")

CURRENT_COUNT="${CURRENT_COUNT:-0}"
[ "$CURRENT_COUNT" -eq 0 ] 2>/dev/null && exit 0

# ── 检查触发阈值 ─────────────────────────────────
TRIGGER_INTERVAL="${CP_ANALYSIS_INTERVAL:-3}"  # Phase 1: 每 N 会话（默认3）

if [ -f "$STATE_FILE" ]; then
  LAST_COUNT=$(head -1 "$STATE_FILE" 2>/dev/null || echo "0")
  LAST_COUNT="${LAST_COUNT:-0}"
  DELTA=$((CURRENT_COUNT - LAST_COUNT))
  if [ "$DELTA" -lt "$TRIGGER_INTERVAL" ] 2>/dev/null; then
    exit 0
  fi
else
  # 首次运行：如果会话数已 ≥ 3，立即触发
  if [ "$CURRENT_COUNT" -lt "$TRIGGER_INTERVAL" ] 2>/dev/null; then
    exit 0
  fi
fi

# ── 触发分析 ─────────────────────────────────────
START_TS=$(date +%s%3N 2>/dev/null || echo "0")

MCP_HEALTH=$(mcp_health_check "$PROJECT_DIR" "$MCP_CLI")
if [ "$MCP_HEALTH" = "ok" ]; then
  RESULT=$(bash "$MCP_CLI" "$PROJECT_DIR" run_analytics "{}" 2>/dev/null || echo '{"error":"mcp_cli failed"}')
else
  exit 0
fi

END_TS=$(date +%s%3N 2>/dev/null || echo "0")
DURATION=$((END_TS - START_TS))

# 提取状态
DIMS_UPDATED=$(echo "$RESULT" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('dimensions_updated',0))" 2>/dev/null || echo "0")
ERROR=$(echo "$RESULT" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('error',''))" 2>/dev/null || echo "")

# ── 更新状态文件 ─────────────────────────────────
echo "$CURRENT_COUNT" > "$STATE_FILE"
echo "$(date -Iseconds)" >> "$STATE_FILE"

# 输出摘要（仅 stderr，不注入上下文）
if [ -n "$ERROR" ]; then
  echo "[analysis-scheduler] 分析失败: $ERROR" >&2
else
  echo "[analysis-scheduler] 第 ${CURRENT_COUNT} 会话, 更新 ${DIMS_UPDATED} 维度 (${DURATION}ms)" >&2
fi

exit 0
