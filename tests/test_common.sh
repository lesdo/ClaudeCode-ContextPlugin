#!/bin/bash
# test_common.sh — L2: _common.sh 函数单元测试
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PLUGIN="$(dirname "$SCRIPT_DIR")"
source "$SCRIPT_DIR/assert.sh"
export CLAUDE_PLUGIN_ROOT="$PLUGIN"
source "$PLUGIN/hooks/lib/_common.sh"

echo "=== Unit: _common.sh ==="

TEST_DIR=$(mktemp -d)
mkdir -p "$TEST_DIR/.claude/context/sessions"
SESSIONS="$TEST_DIR/.claude/context/sessions"

# ── session_index_append + read ──
echo "--- session_index ---"
session_index_append "$SESSIONS" "2026-01-01" "120000" "complete"
session_index_append "$SESSIONS" "2026-01-02" "130000" "skeleton"
session_index_append "$SESSIONS" "2026-01-03" "140000" "complete"
assert_file "index 创建" "$SESSIONS/.session-index"

read TOTAL COMP SKEL <<< $(session_index_read "$SESSIONS")
assert_eq "total" "3" "$TOTAL"
assert_eq "complete" "2" "$COMP"
assert_eq "skeleton" "1" "$SKEL"

# ── session_index_find ──
STATUS=$(session_index_find "$SESSIONS" "2026-01-02" "130000")
assert_eq "find skeleton" "skeleton" "$STATUS"
STATUS=$(session_index_find "$SESSIONS" "2026-01-01" "120000")
assert_eq "find complete" "complete" "$STATUS"
STATUS=$(session_index_find "$SESSIONS" "2099-01-01" "000000")
assert_eq "find unknown" "unknown" "$STATUS"

# ── session_index_tail ──
TAIL=$(session_index_tail "$SESSIONS" 1)
assert_contains "tail" <(echo "$TAIL") "2026-01-03"

# ── detect_project_dir ──
detect_project_dir "/tmp/test-proj"
assert_eq "detect explicit" "/tmp/test-proj" "$PROJECT_DIR"

# ── snapshot_config ──
SNAP="$TEST_DIR/snapshot.txt"
snapshot_config "$SNAP"
assert_file "snapshot 生成" "$SNAP"

# ── crash_diagnose (无数据→L3) ──
read CD_DC CD_DS <<< $(crash_diagnose "no-such-slug" "$TEST_DIR" "skeleton")
assert_eq "diagnose 无数据" "0 L3" "$CD_DC $CD_DS"

# ── 清理 ──
rm -rf "$TEST_DIR"

finish
