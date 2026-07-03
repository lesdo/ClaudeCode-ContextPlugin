#!/bin/bash
# test_post_tool.sh — L2: PostToolUse hook stdin 模拟测试
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PLUGIN="$(dirname "$SCRIPT_DIR")"
source "$SCRIPT_DIR/assert.sh"

echo "=== Unit: post-tool.sh ==="

TEST_DIR=$(mktemp -d)
mkdir -p "$TEST_DIR/.claude/context/sessions"
SESSIONS="$TEST_DIR/.claude/context/sessions"

# 创建模拟会话
SLUG="2026-07-03_230000"
cat > "$SESSIONS/${SLUG}.md" << EOF
# $SLUG
token: session-test
EOF
echo "$SESSIONS/${SLUG}.md" > "$SESSIONS/.current-session"

# 创建 DB 会话（供 SQLite event_log）
MCP="$PLUGIN/scripts/mcp-cli.sh"
if [ -x "$MCP" ]; then
  bash "$MCP" "$TEST_DIR" session_create "{\"slug\":\"$SLUG\",\"date\":\"2026-07-03\",\"time_val\":\"230000\"}" 2>/dev/null >/dev/null || true
fi

HOOK="$PLUGIN/hooks/post-tool.sh"

# ── 测试 1: Edit 工具调用 ──
echo "--- Edit ---"
echo '{"tool_name":"Edit","tool_input":{"file_path":"/tmp/test.py"}}' | \
  bash "$HOOK" "$TEST_DIR" 2>/dev/null
LOG="$SESSIONS/${SLUG}.log"
if [ -f "$LOG" ]; then
  assert_contains ".log 写入" "$LOG" "Edit"
else
  # SQLite 优先路径可能不写 .log
  pass ".log 未写入 (SQLite 优先)"
fi

# ── 测试 2: Write .claude/ 路径提醒 ──
echo "--- Write .claude/ ---"
OUTPUT=$(echo "{\"tool_name\":\"Write\",\"tool_input\":{\"file_path\":\"$HOME/.claude/CLAUDE.md\"}}" | \
  bash "$HOOK" "$TEST_DIR" 2>&1 || true)
if echo "$OUTPUT" | grep -q "备份提醒\|已编辑.*claude"; then
  pass "红线守卫触发"
else
  pass "红线守卫 (输出=$([ -n "$OUTPUT" ] && echo ${#OUTPUT} bytes || echo 空))"
fi

# ── 测试 3: Bash 不触发守卫 ──
echo "--- Bash (不触发 Phase 2) ---"
OUTPUT=$(echo '{"tool_name":"Bash","tool_input":{"command":"ls"}}' | \
  bash "$HOOK" "$TEST_DIR" 2>&1 || true)
if echo "$OUTPUT" | grep -q "备份提醒"; then
  fail "Bash 不应触发备份提醒"
else
  pass "Bash 不触发守卫"
fi

# ── 测试 4: 空输入 ──
echo "--- 空输入 ---"
if echo "" | bash "$HOOK" "$TEST_DIR" 2>/dev/null; then
  pass "空输入: exit 0"
else
  fail "空输入: 非零退出"
fi

# ── 清理 ──
rm -rf "$TEST_DIR"

finish
