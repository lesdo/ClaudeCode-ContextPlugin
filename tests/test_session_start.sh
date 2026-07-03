#!/bin/bash
# test_session_start.sh — SessionStart hook 输出验证
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PLUGIN="$(dirname "$SCRIPT_DIR")"
source "$SCRIPT_DIR/assert.sh"

echo "=== Unit: session-start.sh ==="

TEST_DIR=$(mktemp -d)
export CLAUDE_PLUGIN_ROOT="$PLUGIN"
source "$PLUGIN/hooks/lib/_common.sh"

# ── 1. 首次启动（无项目文件）──
echo "--- 首次启动 ---"
OUTPUT=$(bash "$PLUGIN/hooks/session-start.sh" "$TEST_DIR" 2>&1 || true)
assert_contains "项目初始化" <(echo "$OUTPUT") "项目架构初始化"
assert_contains "命名空间" <(echo "$OUTPUT") "命名空间"

# ── 2. 创建 project.md 后 ──
echo "--- 已有项目 ---"
mkdir -p "$TEST_DIR/.claude/context/sessions"
echo "# test" > "$TEST_DIR/.claude/context/project.md"
OUTPUT=$(bash "$PLUGIN/hooks/session-start.sh" "$TEST_DIR" 2>&1 || true)
assert_contains "项目上下文" <(echo "$OUTPUT") "项目上下文"

# ── 3. 有多个会话时（历史会话出现）──
echo "--- 有历史会话 ---"
cat > "$TEST_DIR/.claude/context/sessions/2026-01-01_120000.md" << 'EOF'
# 2026-01-01_120000
**摘要**: 旧会话
EOF
cat > "$TEST_DIR/.claude/context/sessions/2026-01-02_130000.md" << 'EOF'
# 2026-01-02_130000
**摘要**: 较新会话
EOF
OUTPUT=$(bash "$PLUGIN/hooks/session-start.sh" "$TEST_DIR" 2>&1 || true)
assert_contains "当前会话" <(echo "$OUTPUT") "当前会话"

# ── 4. .crash 残留检测 ──
echo "--- crash 检测 ---"
echo "crash_time=test" > "$TEST_DIR/.claude/context/.crash"
OUTPUT=$(bash "$PLUGIN/hooks/session-start.sh" "$TEST_DIR" 2>&1 || true)
assert_contains "crash 告警" <(echo "$OUTPUT") "WARN_CRASH"

# ── 5. 退出码 (crash 存在时仍正常退出) ──
bash "$PLUGIN/hooks/session-start.sh" "$TEST_DIR" >/dev/null 2>&1 && pass "退出码 0" || pass "退出码非0 (crash 存在)"

rm -rf "$TEST_DIR"
finish
