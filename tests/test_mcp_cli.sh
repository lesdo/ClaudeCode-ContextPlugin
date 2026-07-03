#!/bin/bash
# test_mcp_cli.sh — mcp-cli.sh 参数传递验证
# 验证修复的 ${3:-{}} 嵌套花括号 bug
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PLUGIN="$(dirname "$SCRIPT_DIR")"
source "$SCRIPT_DIR/assert.sh"

echo "=== Unit: mcp-cli.sh ==="

MCP="$PLUGIN/scripts/mcp-cli.sh"
TEST_DIR=$(mktemp -d)

# ── 1. 参数传递 (核心 — 验证 JSON args 不被破坏) ──
echo "--- 参数传递 ---"
RESULT=$(bash "$MCP" "$TEST_DIR" session_create '{"slug":"test-slug-123","date":"2026-07-04","time_val":"120000"}' 2>/dev/null)
SLUG=$(echo "$RESULT" | python3 -c "import sys,json; print(json.load(sys.stdin).get('slug','?'))" 2>/dev/null)
assert_eq "slug 传递" "test-slug-123" "$SLUG"

# ── 2. 无参数 (默认 {}) ──
echo "--- 无参数 ---"
RESULT=$(bash "$MCP" "$TEST_DIR" ensure_schema 2>/dev/null)
if [ -n "$RESULT" ]; then
  pass "无参数调用 OK"
else
  fail "无参数调用失败"
fi

# ── 3. 特殊字符 ──
echo "--- 特殊字符 ---"
bash "$MCP" "$TEST_DIR" memory_store '{"content":"测试: 中文 + special chars /\\\"quote","mem_type":"semantic"}' 2>/dev/null >/dev/null \
  && pass "特殊字符" || fail "特殊字符传递失败"

# ── 4. 缺失 command ──
echo "--- 缺失 command ---"
OUTPUT=$(bash "$MCP" "$TEST_DIR" "" 2>&1 || true)
assert_contains "错误处理" <(echo "$OUTPUT") "Usage"

rm -rf "$TEST_DIR"
finish
