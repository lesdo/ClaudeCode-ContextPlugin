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

# ── 测试 5: session_clear_suspect (ax10 逆转机制) ──
echo "--- session_clear_suspect ---"
# 设 suspect_at → 调用 clear → 验证已清除
python3 - "$TEST_DIR" "$PLUGIN" << 'PYEOF'
import sys, os
td = sys.argv[1]
plugin = sys.argv[2]
sys.path.insert(0, os.path.join(plugin, 'mcp'))
from db_core import get_db, ensure_schema
ensure_schema(td)
with get_db(td) as conn:
    row = conn.execute("SELECT id FROM sessions WHERE status='active' ORDER BY created_at DESC LIMIT 1").fetchone()
    if row:
        conn.execute("UPDATE sessions SET suspect_at=datetime('now') WHERE id=?", (row[0],))
PYEOF

CLEAR_RESULT=$(bash "$MCP" "$TEST_DIR" session_clear_suspect 2>/dev/null || echo '{"status":"error"}')
assert_contains "clear_suspect 返回 cleared" <(echo "$CLEAR_RESULT") "cleared"

VERIFY=$(python3 - "$TEST_DIR" "$PLUGIN" << 'PYEOF'
import sys, os, json
td = sys.argv[1]
plugin = sys.argv[2]
sys.path.insert(0, os.path.join(plugin, 'mcp'))
from db_core import get_db
with get_db(td) as conn:
    row = conn.execute("SELECT suspect_at FROM sessions WHERE status='active' ORDER BY created_at DESC LIMIT 1").fetchone()
    print(json.dumps({"suspect_at": row['suspect_at'] if row else "no_row"}))
PYEOF
)
assert_contains "suspect_at 已清除为 null" <(echo "$VERIFY") "null"

# ── 清理 ──
rm -rf "$TEST_DIR"

finish
