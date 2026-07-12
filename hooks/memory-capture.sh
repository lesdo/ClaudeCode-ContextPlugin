#!/bin/bash
# memory-capture.sh — Stop hook: 衰减清理 + transcript解析 + 指针清理
# 不终结 DB 会话 — 会话生杀权归 wrapper (claude-monitored.sh)
# compaction 时 Stop 也会触发，若在此关库会导致后续事件丢失
set -uo pipefail  # fail-open: errors logged, always exit 0
#
# 用法: bash memory-capture.sh [project_dir]

CLAUDE_PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
source "${CLAUDE_PLUGIN_ROOT}/hooks/lib/_common.sh"
detect_project_dir "${1:-}"

MCP_CLI="${CLAUDE_PLUGIN_ROOT}/scripts/mcp-cli.sh"
SESSIONS_DIR="$PROJECT_DIR/.context/sessions"
POINTER="$SESSIONS_DIR/.current-session"

# ── 0. transcript 解析 (v5.2) ──────────────────
INPUT=$(cat 2>/dev/null)
TRANSCRIPT_PATH=""
if [ -n "$INPUT" ]; then
  TRANSCRIPT_PATH=$(echo "$INPUT" | python3 -c "
import sys,json
try:
    d=json.load(sys.stdin)
    print(d.get('transcript_path',''))
except Exception: pass
" 2>/dev/null)
fi

if [ -n "$TRANSCRIPT_PATH" ] && [ -f "$TRANSCRIPT_PATH" ]; then
  MCP_HEALTH=$(mcp_health_check "$PROJECT_DIR" "$MCP_CLI")
  if [ "$MCP_HEALTH" = "ok" ]; then
    ENRICH=$(bash "$MCP_CLI" "$PROJECT_DIR" enrich_briefing \
      "{\"transcript_path\":\"$TRANSCRIPT_PATH\"}" 2>/dev/null)
    if [ -n "$ENRICH" ] && [ "$ENRICH" != "null" ]; then
      echo "memory-capture: transcript $(echo "$ENRICH" | python3 -c "
import sys,json
d=json.load(sys.stdin)
print(f'keywords={d.get(\"keywords\",[])} msgs={d.get(\"messages\",0)} tools={d.get(\"tools\",0)}')
" 2>/dev/null || echo 'parsed')"
    fi
  fi
fi

# ── 1. 清理 .current-session 指针 ──────────────────
if [ -f "$POINTER" ]; then
  rm -f "$POINTER"
  echo "memory-capture: .current-session 已清理"
fi

# ── 2. 衰减清理 ──────────────────────────────────
MCP_HEALTH=$(mcp_health_check "$PROJECT_DIR" "$MCP_CLI")
if [ "$MCP_HEALTH" = "ok" ]; then
  DECAY=$(bash "$MCP_CLI" "$PROJECT_DIR" decay_run 2>/dev/null)
  DECAY_EXIT=$?
  if [ $DECAY_EXIT -ne 0 ]; then
    echo "memory-capture: 衰减失败 (exit=$DECAY_EXIT)"
  elif [ -n "$DECAY" ] && [ "$DECAY" != "null" ]; then
    echo "memory-capture: 衰减 $(echo "$DECAY" | python3 -c "import sys,json; d=json.load(sys.stdin); print(f'归档{d.get(\"archived\",0)}/删除{d.get(\"deleted\",0)}/检查{d.get(\"examined\",0)}/延长{d.get(\"extended\",0)}')" 2>/dev/null || echo '完成')"
  fi
else
  echo "memory-capture: 衰减跳过（MCP=${MCP_HEALTH}）"
fi

echo "memory-capture: 完成"
