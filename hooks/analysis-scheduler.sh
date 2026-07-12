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
# 保留已有的 review 行（第 3-4 行），只更新 analytics 行
_REVIEW_LINE3=$(sed -n '3p' "$STATE_FILE" 2>/dev/null || echo "")
_REVIEW_LINE4=$(sed -n '4p' "$STATE_FILE" 2>/dev/null || echo "")
echo "$CURRENT_COUNT" > "$STATE_FILE"
echo "$(date -Iseconds)" >> "$STATE_FILE"
if [ -n "$_REVIEW_LINE3" ]; then
  echo "$_REVIEW_LINE3" >> "$STATE_FILE"
  echo "${_REVIEW_LINE4:-}" >> "$STATE_FILE"
fi

# 输出摘要（仅 stderr，不注入上下文）
if [ -n "$ERROR" ]; then
  echo "[analysis-scheduler] 分析失败: $ERROR" >&2
else
  echo "[analysis-scheduler] 第 ${CURRENT_COUNT} 会话, 更新 ${DIMS_UPDATED} 维度 (${DURATION}ms)" >&2
fi

# ── outcome_review 触发 (ax5: 决策反馈闭环) ────────
# 独立计数：每 CP_REVIEW_INTERVAL 会话触发一次
# 只审查 ≥ CP_REVIEW_MIN_AGE 天前的决策
REVIEW_INTERVAL="${CP_REVIEW_INTERVAL:-10}"

# 从状态文件第 3 行读取上次 review 的会话序号
LAST_REVIEW_COUNT=$(sed -n '3p' "$STATE_FILE" 2>/dev/null || echo "0")
LAST_REVIEW_COUNT="${LAST_REVIEW_COUNT:-0}"
REVIEW_DELTA=$((CURRENT_COUNT - LAST_REVIEW_COUNT))

if [ "$REVIEW_DELTA" -ge "$REVIEW_INTERVAL" ] 2>/dev/null; then
  if [ "$MCP_HEALTH" = "ok" ]; then
    REVIEW_START=$(date +%s%3N 2>/dev/null || echo "0")
    REVIEW_RESULT=$(bash "$MCP_CLI" "$PROJECT_DIR" outcome_review \
      "{\"min_age_days\":${CP_REVIEW_MIN_AGE:-7}}" 2>/dev/null || echo '{"error":"mcp_cli failed"}')
    REVIEW_END=$(date +%s%3N 2>/dev/null || echo "0")
    REVIEW_DURATION=$((REVIEW_END - REVIEW_START))

    REVIEWED=$(echo "$REVIEW_RESULT" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('reviewed',0))" 2>/dev/null || echo "0")
    VERIFIED=$(echo "$REVIEW_RESULT" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('verified',0))" 2>/dev/null || echo "0")
    NEEDS=$(echo "$REVIEW_RESULT" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('needs_review',0))" 2>/dev/null || echo "0")
    REVIEW_ERR=$(echo "$REVIEW_RESULT" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('error',''))" 2>/dev/null || echo "")

    # 更新状态文件第 3-4 行（review 计数 + 时间戳）
    # 用读-写模式，兼容 Windows（避免 sed -i）
    _ANALYTICS_LINE1=$(sed -n '1p' "$STATE_FILE" 2>/dev/null || echo "0")
    _ANALYTICS_LINE2=$(sed -n '2p' "$STATE_FILE" 2>/dev/null || echo "")
    {
      echo "${_ANALYTICS_LINE1:-0}"
      echo "${_ANALYTICS_LINE2:-}"
      echo "$CURRENT_COUNT"
      echo "$(date -Iseconds)"
    } > "$STATE_FILE"

    if [ -n "$REVIEW_ERR" ]; then
      echo "[analysis-scheduler] outcome_review 失败: $REVIEW_ERR" >&2
    elif [ "${REVIEWED:-0}" -gt 0 ] 2>/dev/null; then
      echo "[analysis-scheduler] outcome_review: 审查 ${REVIEWED} 决策, 确认 ${VERIFIED}, 需人工 ${NEEDS} (${REVIEW_DURATION}ms)" >&2
    fi
  fi
fi

# ── Opus 对抗式审查准备 (ax10: Red/Blue/Auditor) ──
# 独立计数：每 CP_OPUS_INTERVAL 会话准备一次审查上下文
# Phase A: 调度器准备 diff 上下文（不消耗 LLM token）
# Phase B: Agent 读取 briefing 后执行实际审查
OPUS_INTERVAL="${CP_OPUS_INTERVAL:-20}"

# 从状态文件第 5 行读取上次 opus prep 的会话序号
LAST_OPUS_COUNT=$(sed -n '5p' "$STATE_FILE" 2>/dev/null || echo "0")
LAST_OPUS_COUNT="${LAST_OPUS_COUNT:-0}"
OPUS_DELTA=$((CURRENT_COUNT - LAST_OPUS_COUNT))

if [ "$OPUS_DELTA" -ge "$OPUS_INTERVAL" ] 2>/dev/null; then
  if [ "$MCP_HEALTH" = "ok" ]; then
    OPUS_START=$(date +%s%3N 2>/dev/null || echo "0")
    OPUS_RESULT=$(bash "$MCP_CLI" "$PROJECT_DIR" opus_review_prep \
      '{"base_ref":"HEAD~1"}' 2>/dev/null || echo '{"ready":false,"error":"mcp_cli failed"}')
    OPUS_END=$(date +%s%3N 2>/dev/null || echo "0")
    OPUS_DURATION=$((OPUS_END - OPUS_START))

    OPUS_READY=$(echo "$OPUS_RESULT" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('ready','false'))" 2>/dev/null || echo "false")
    OPUS_FILES=$(echo "$OPUS_RESULT" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('total_changed',0))" 2>/dev/null || echo "0")
    OPUS_ERR=$(echo "$OPUS_RESULT" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('error',''))" 2>/dev/null || echo "")

    # 更新状态文件第 5-6 行
    # 保留已有 1-4 行（analytics + review）
    _LINE1=$(sed -n '1p' "$STATE_FILE" 2>/dev/null || echo "0")
    _LINE2=$(sed -n '2p' "$STATE_FILE" 2>/dev/null || echo "")
    _LINE3=$(sed -n '3p' "$STATE_FILE" 2>/dev/null || echo "0")
    _LINE4=$(sed -n '4p' "$STATE_FILE" 2>/dev/null || echo "")
    {
      echo "${_LINE1:-0}"
      echo "${_LINE2:-}"
      echo "${_LINE3:-0}"
      echo "${_LINE4:-}"
      echo "$CURRENT_COUNT"
      echo "$(date -Iseconds)"
    } > "$STATE_FILE"

    if [ -n "$OPUS_ERR" ]; then
      echo "[analysis-scheduler] opus_review_prep 失败: $OPUS_ERR" >&2
    elif [ "$OPUS_READY" = "true" ]; then
      echo "[analysis-scheduler] opus_review_prep: ${OPUS_FILES} 文件待审查 (${OPUS_DURATION}ms)" >&2
      # 将审查提示注入 briefing（通过 stderr 输出，SessionStart 会捕获）
      REVIEW_PROMPT=$(echo "$OPUS_RESULT" | python3 -c "
import sys,json
d=json.load(sys.stdin)
print(d.get('review_prompt',''))" 2>/dev/null || echo "")
      if [ -n "$REVIEW_PROMPT" ]; then
        echo "[opus-review-prompt] $REVIEW_PROMPT" >&2
      fi
    fi
  fi
fi

exit 0
