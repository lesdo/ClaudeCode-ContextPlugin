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

# ── session_find_file (Phase D: SQLite替代.session-index, 仅保留.md查找) ──
echo "--- session_find_file ---"
touch "$SESSIONS/2026-01-01_120000.md"
touch "$SESSIONS/2026-01-02_130000.md"
FOUND=$(session_find_file "$SESSIONS" "2026-01-01" "120000")
assert_eq "find md" "$SESSIONS/2026-01-01_120000.md" "$FOUND"
NOTFOUND=$(session_find_file "$SESSIONS" "2099-01-01" "000000" || true)
assert_eq "find unknown" "" "$NOTFOUND"

# ── detect_project_dir ──
detect_project_dir "/tmp/test-proj"
assert_eq "detect explicit" "/tmp/test-proj" "$PROJECT_DIR"

# ── snapshot_config ──
SNAP="$TEST_DIR/snapshot.txt"
snapshot_config "$SNAP"
assert_file "snapshot 生成" "$SNAP"

# ── crash_diagnose (无数据→L3) ──
read CD_DC CD_DS CD_FLAGS <<< $(crash_diagnose "no-such-slug" "$TEST_DIR" "skeleton")
assert_eq "diagnose 无数据:tool_count" "0" "$CD_DC"
assert_eq "diagnose 无数据:severity" "L3" "$CD_DS"
assert_contains "diagnose 无数据:flags含no_data" <(echo "$CD_FLAGS") "no_data"

# ── 清理 ──
rm -rf "$TEST_DIR"

finish
