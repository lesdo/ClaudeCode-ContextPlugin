#!/bin/bash
# test_compact.sh — pre-compact + post-compact hook 验证
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PLUGIN="$(dirname "$SCRIPT_DIR")"
source "$SCRIPT_DIR/assert.sh"

echo "=== Unit: compact hooks ==="

TEST_DIR=$(mktemp -d)
mkdir -p "$TEST_DIR/.context/briefing"
export CLAUDE_PLUGIN_ROOT="$PLUGIN"
source "$PLUGIN/hooks/lib/_common.sh"

MCP="$PLUGIN/scripts/mcp-cli.sh"

# ── 1. pre-compact: 生成简报 → 文件 ──
echo "--- pre-compact ---"
bash "$MCP" "$TEST_DIR" session_create '{"slug":"test","date":"2026-07-04","time_val":"120000"}' 2>/dev/null >/dev/null
OUTPUT=$(bash "$PLUGIN/hooks/pre-compact.sh" "$TEST_DIR" 2>&1 || true)
BRIEFING_FILE="$TEST_DIR/.context/briefing/active.md"
if [ -f "$BRIEFING_FILE" ] && [ -s "$BRIEFING_FILE" ]; then
  pass "简报落盘: $(wc -c < "$BRIEFING_FILE") bytes"
else
  fail "简报未落盘"
fi

# ── 2. post-compact: 读简报 → echo ──
echo "--- post-compact ---"
echo "Test briefing content" > "$BRIEFING_FILE"
OUTPUT=$(bash "$PLUGIN/hooks/post-compact.sh" "$TEST_DIR" 2>&1 || true)
assert_contains "简报恢复" <(echo "$OUTPUT") "Test briefing"
assert_contains "memory_search 提示" <(echo "$OUTPUT") "memory_search"

# ── 3. post-compact: 无简报文件 ──
echo "--- post-compact (无文件) ---"
rm -f "$BRIEFING_FILE"
OUTPUT=$(bash "$PLUGIN/hooks/post-compact.sh" "$TEST_DIR" 2>&1 || true)
assert_contains "缺失提示" <(echo "$OUTPUT") "简报文件缺失"

rm -rf "$TEST_DIR"
finish
