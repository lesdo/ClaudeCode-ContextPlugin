#!/bin/bash
# test_memory_capture.sh — memory-capture Stop hook 验证
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PLUGIN="$(dirname "$SCRIPT_DIR")"
source "$SCRIPT_DIR/assert.sh"

echo "=== Unit: memory-capture.sh ==="

TEST_DIR=$(mktemp -d)
mkdir -p "$TEST_DIR/.claude/context/sessions"
export CLAUDE_PLUGIN_ROOT="$PLUGIN"

# 创建活跃 DB 会话
MCP="$PLUGIN/scripts/mcp-cli.sh"
bash "$MCP" "$TEST_DIR" session_create '{"slug":"test-session","date":"2026-07-04","time_val":"120000","pid":1234}' 2>/dev/null >/dev/null

# ── 1. 正常执行 ──
echo "--- 正常执行 ---"
OUTPUT=$(bash "$PLUGIN/hooks/memory-capture.sh" "$TEST_DIR" 2>&1 || true)
assert_contains "结束会话" <(echo "$OUTPUT") "memory-capture"
[ -f "$TEST_DIR/.claude/context/sessions/.current-session" ] \
  && fail ".current-session 未清理" \
  || pass ".current-session 已清理"

# ── 2. 无 .current-session ──
echo "--- 无指针 ---"
rm -f "$TEST_DIR/.claude/context/sessions/.current-session"
bash "$PLUGIN/hooks/memory-capture.sh" "$TEST_DIR" >/dev/null 2>&1 && pass "退出码 0" || fail "退出码非0"

# ── 3. MCP 不可用时 ──
echo "--- MCP 不可用 (兜底) ---"
MCP_BAK="$MCP.bak"
[ -f "$MCP" ] && mv "$MCP" "$MCP_BAK"
bash "$PLUGIN/hooks/memory-capture.sh" "$TEST_DIR" >/dev/null 2>&1 && pass "兜底 OK" || fail "兜底失败"
[ -f "$MCP_BAK" ] && mv "$MCP_BAK" "$MCP"

rm -rf "$TEST_DIR"
finish
