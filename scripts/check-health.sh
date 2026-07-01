#!/bin/bash
# 系统健康检查 — 验证脚本、配置、目录完整性
# 手动运行，不进 hook 链
# 用法: bash check-health.sh [项目目录]

CLAUDE_PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
source "${CLAUDE_PLUGIN_ROOT}/hooks/lib/_common.sh"
PASS=0
FAIL=0

check() {
  local desc="$1"; shift
  if "$@" >/dev/null 2>&1; then
    echo "  ✓ $desc"
    PASS=$((PASS + 1))
  else
    echo "  ✗ $desc"
    FAIL=$((FAIL + 1))
  fi
}

echo "=== Claude Code 工具链健康检查 ($TOOLS_VERSION) ==="
echo ""

# ── 配置完整性 ────────────────────────────────────
echo "── 配置"
check "CLAUDE.md 存在"        test -f ~/.claude/CLAUDE.md
check "settings.json 存在"    test -f ~/.claude/settings.json
if python3 -c "import sys,json; json.load(sys.stdin)" < "$HOME/.claude/settings.json" 2>/dev/null; then
  echo "  ✓ settings.json 合法JSON"
  PASS=$((PASS + 1))
else
  echo "  ✗ settings.json 合法JSON"
  FAIL=$((FAIL + 1))
fi
check "profile/user.md 存在"   test -f ~/.claude/profile/user.md
check "profile/rules.md 存在"  test -f ~/.claude/profile/rules.md

echo ""
echo "── Hook 脚本"

scripts=(
  session-start.sh
  auto-log.sh
  guard.sh
  exit-check.sh
)
HOOKS_DIR="${CLAUDE_PLUGIN_ROOT}/hooks"

for s in "${scripts[@]}"; do
  path="$HOOKS_DIR/$s"
  if [ -f "$path" ]; then
    check "$s 语法" bash -n "$path"
  else
    echo "  ✗ $s 缺失"
    FAIL=$((FAIL + 1))
  fi
done

echo ""
echo "── Hook 输出验证"

# 验证 session-start.sh 输出含三模块
CTX_OUT=$(bash "${HOOKS_DIR}/session-start.sh" 2>/dev/null)
if echo "$CTX_OUT" | grep -q "用户画像"; then
  echo "  ✓ session-start 输出含用户画像"
  PASS=$((PASS + 1))
else
  echo "  ✗ session-start 缺少用户画像"
  FAIL=$((FAIL + 1))
fi
if echo "$CTX_OUT" | grep -q "行为规则"; then
  echo "  ✓ session-start 输出含行为规则"
  PASS=$((PASS + 1))
else
  echo "  ✗ session-start 缺少行为规则"
  FAIL=$((FAIL + 1))
fi
if echo "$CTX_OUT" | grep -q "会话管理规则"; then
  echo "  ✓ session-start 输出含会话管理规则"
  PASS=$((PASS + 1))
else
  echo "  ✗ session-start 缺少会话管理规则"
  FAIL=$((FAIL + 1))
fi

echo ""
echo "── Hook 链一致性"

# 验证 hooks.json 引用的脚本都存在
HOOKS_JSON="${CLAUDE_PLUGIN_ROOT}/hooks/hooks.json"
	if [ -f "$HOOKS_JSON" ]; then
	  HOOK_REFS=$(grep -oP 'bash ${CLAUDE_PLUGIN_ROOT}/[^"]*' "$HOOKS_JSON" 2>/dev/null)
	  while IFS= read -r ref; do
	    script_full="${CLAUDE_PLUGIN_ROOT}/${script_path}"
	    script_path="${ref#bash ${CLAUDE_PLUGIN_ROOT}/}"
	    check "引用 $script_path" test -f "$script_full"
	  done <<< "$HOOK_REFS"
	fi

echo ""
echo "── 备份"
BACKUP_DIR="${BACKUP_DIR:-$HOME/ClaudecodeBackup}"
if echo "$BACKUP_DIR" | grep -q '^[A-Za-z]:'; then
  BACKUP_DIR_UNIX="/$(echo "$BACKUP_DIR" | cut -c1 | tr '[:upper:]' '[:lower:]')$(echo "$BACKUP_DIR" | cut -c3- | tr '\\' '/')"
else
  BACKUP_DIR_UNIX="$BACKUP_DIR"
fi
BACKUP_PATTERN="claude-backup-[0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9]_[0-9][0-9][0-9][0-9].tar.gz"
check "备份目录存在"   test -d "$BACKUP_DIR_UNIX"
COUNT=$(ls "$BACKUP_DIR_UNIX"/$BACKUP_PATTERN 2>/dev/null | wc -l)
echo "  备份数量: $COUNT"
if [ "$COUNT" -gt 0 ]; then
  LATEST=$(ls -t "$BACKUP_DIR_UNIX"/$BACKUP_PATTERN 2>/dev/null | head -1)
  echo "  最新: $(basename "$LATEST")"
fi

echo ""
echo "── 会话记录"

detect_project_dir "$1"

SESSIONS_DIR="$PROJECT_DIR/.claude/context/sessions"
check "会话目录存在"   test -d "$SESSIONS_DIR"
if [ -d "$SESSIONS_DIR" ]; then
  SESSION_COUNT=$(ls "$SESSIONS_DIR"/*.md 2>/dev/null | wc -l)
  echo "  会话文件: $SESSION_COUNT"
  SKELETON_COUNT=$(grep -l "（待填充）" "$SESSIONS_DIR"/*.md 2>/dev/null | wc -l)
  echo "  已记录: $((SESSION_COUNT - SKELETON_COUNT))"
fi

check "STATUS.md 存在"  test -f "$PROJECT_DIR/.claude/context/STATUS.md"

echo ""
echo "── CLAUDE.md 底线"
LINES=$(wc -l < "$HOME/.claude/CLAUDE.md")
if [ "$LINES" -le 50 ]; then
  echo "  ✓ CLAUDE.md 行数: $LINES ≤ 50"
  PASS=$((PASS + 1))
else
  echo "  ✗ CLAUDE.md 行数: $LINES > 50"
  FAIL=$((FAIL + 1))
fi

echo ""
echo "========================================="
echo "  通过: $PASS  失败: $FAIL"
if [ "$FAIL" -eq 0 ]; then
  echo "  状态: 健康"
else
  echo "  状态: 需修复 $FAIL 项"
fi
echo "========================================="
