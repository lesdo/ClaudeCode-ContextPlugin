#!/bin/bash
# ============================================================
set -uo pipefail  # fail-open: errors logged, always exit 0
# claude-monitored.sh — 带崩溃监视的 Claude 启动器（备份检测已剥离至 backup skill）
# ============================================================

# ── 递归防护：防 command claude 回环调用 wrapper ──
# 当 CLAUDE_BIN 未设置时，command claude 会找到此脚本自身 → 死循环。
# 这里跳过程序包裹，直接定位 _claude.exe 打破循环。
if [ "${_CC_WRAPPER_DEPTH:-0}" -ge 1 ] 2>/dev/null; then
  echo "[wrapper] 检测到递归调用（_CC_WRAPPER_DEPTH=${_CC_WRAPPER_DEPTH}），跳过 wrapper 直接执行 claude" >&2

  # 确保 CLAUDE_PLUGIN_ROOT 已初始化（复刻下方逻辑）
  if [ -z "${CLAUDE_PLUGIN_ROOT:-}" ]; then
    CLAUDE_PLUGIN_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
  fi
  PLUGIN_ROOT_UNIX=$(echo "$CLAUDE_PLUGIN_ROOT" | sed 's|^\([A-Z]\):|/\1|' | tr '[:upper:]' '[:lower:]' | tr '\\' '/')

  # 定位真正的 Claude 二进制
  if [ -n "${CLAUDE_BIN:-}" ]; then
    CLAUDE_BIN_UNIX=$(echo "$CLAUDE_BIN" | sed 's|^\([A-Z]\):|/\1|' | tr '[:upper:]' '[:lower:]' | tr '\\' '/')
    exec "$CLAUDE_BIN_UNIX" --plugin-dir "$PLUGIN_ROOT_UNIX" "${1:-.}"
  elif [ -f "$HOME/.local/bin/_claude.exe" ]; then
    exec "$HOME/.local/bin/_claude.exe" --plugin-dir "$PLUGIN_ROOT_UNIX" "${1:-.}"
  else
    echo "[wrapper] 错误: 无法定位 Claude 二进制 — CLAUDE_BIN 未设置且 ~/.local/bin/_claude.exe 不存在" >&2
    exit 127
  fi
fi
export _CC_WRAPPER_DEPTH=$(( ${_CC_WRAPPER_DEPTH:-0} + 1 ))

# ── 注入 Git Bash 路径（Windows Claude Code 需此环境变量定位正确的 bash）──
export CLAUDE_CODE_GIT_BASH_PATH="${CLAUDE_CODE_GIT_BASH_PATH:-/usr/bin/bash}"

CLAUDE_PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
source "${CLAUDE_PLUGIN_ROOT}/hooks/lib/_common.sh"
# 用法:
#   bash ~/.claude/tools/claude-monitored.sh [项目目录]
#
# 功能:
#   1. 启动前：创建会话文件骨架（sessions/）
#   2. 启动 Claude，作为父进程 wait
#   3. 退出后：自动捕获文件变更 → 写入会话文件
#   4. 退出后：多信号判定异常（退出码 + 会话文件存在性）
#   5. 退出后：追加会话索引 + 触发月归档
# 备份检测已剥离至 backup skill（E:/Files/claude-backup-skill/），不再在 wrapper 中检查
# ============================================================

PROJECT_DIR="${1:-.}"
PROJECT_DIR="$(cd "$PROJECT_DIR" && pwd)"
CONTEXT_DIR="$PROJECT_DIR/.context"
CLAUDE_CONTEXT_DIR="$PROJECT_DIR/.claude/context"
CRASH_FILE="$CLAUDE_CONTEXT_DIR/.crash"
# ============================================================
# 启动前检查
# ============================================================

echo "========================================="
echo "  Claude Code 会话启动"
echo "========================================="
echo ""

# --- 1. 会话文件骨架 ---
# --- 0. 备份新鲜度检查 ---
BACKUP_STATUS_SH="$HOME/.claude/skills/backup/scripts/status.sh"
if [ -x "$BACKUP_STATUS_SH" ]; then
  eval "$(bash "$BACKUP_STATUS_SH" 2>/dev/null)"
  case "${BACKUP_STATUS:-none}" in
    expired) echo "⚠ 备份已过期 ${BACKUP_AGE_DAYS:-?} 天（阈值 ${backup_expire_days:-7} 天）" ;;
    none)    echo "💡 尚无备份快照" ;;
  esac
fi

echo ""
echo "[启动检查] 会话记录..."

SESSION_DATE=$(date +%Y-%m-%d)
SESSION_TIME=$(date +%H%M%S)
SESSION_SLUG="${SESSION_DATE}_${SESSION_TIME}"
SESSION_TOKEN="session-$$-$(date +%s)-${RANDOM}"
SESSION_START_MARKER="$CONTEXT_DIR/.session-start-time"

# 创建时间标记文件用于 diff
touch "$SESSION_START_MARKER"

# DB 会话创建（SQLite 是唯一真相源，.md 按需由 session_compile_md 生成）
MCP_CLI="${CLAUDE_PLUGIN_ROOT}/scripts/mcp-cli.sh"
if [ -x "$MCP_CLI" ] 2>/dev/null; then
  DB_RESULT=$(bash "$MCP_CLI" "$PROJECT_DIR" session_create \
    "{\"date\":\"$SESSION_DATE\",\"time_val\":\"$SESSION_TIME\",\"slug\":\"$SESSION_SLUG\",\"pid\":$$,\"token\":\"$SESSION_TOKEN\"}" 2>/dev/null || echo '{}')
  DB_ID=$(echo "$DB_RESULT" | python3 -c "import sys,json; print(json.load(sys.stdin).get('id',''))" 2>/dev/null || echo "")
  if [ -n "$DB_ID" ]; then
    echo "  ✓ DB 会话: ${DB_ID}"
  fi
fi

echo ""
echo "[wrapper] 启动 Claude — 项目: $PROJECT_DIR"
echo ""

# ============================================================
# 启动 Claude
# ============================================================

# CLAUDE_BIN 环境变量可覆盖 Claude 可执行文件路径
#   - cmd 的 .bat 启动器会设为 _claude.exe（避免调用 npm 版本）
#   - 不设则使用默认的 command claude
# CLAUDE_PLUGIN_ROOT 由 .bat 启动器预设，用于 --plugin-dir 参数
PLUGIN_ARG=""
if [ -n "${CLAUDE_PLUGIN_ROOT:-}" ]; then
  PLUGIN_ROOT_UNIX=$(echo "$CLAUDE_PLUGIN_ROOT" | sed 's|^\([A-Z]\):|/\1|' | tr '[:upper:]' '[:lower:]' | tr '\\' '/')
  PLUGIN_ARG="--plugin-dir $PLUGIN_ROOT_UNIX"
fi

if [ -n "$CLAUDE_BIN" ]; then
  # Windows 路径转换：C:\Users\... → /c/Users/...
  CLAUDE_BIN_UNIX=$(echo "$CLAUDE_BIN" | sed 's|^\([A-Z]\):|/\1|' | tr '[:upper:]' '[:lower:]')
  "$CLAUDE_BIN_UNIX" $PLUGIN_ARG "$PROJECT_DIR"
else
  command claude $PLUGIN_ARG "$PROJECT_DIR"
fi
EXIT_CODE=$?

echo ""
echo "========================================="
echo "  Claude Code 会话结束"
echo "========================================="
echo "[wrapper] Claude 退出 (exit_code=$EXIT_CODE)"

# ── 退出后处理（lib/_wrapper-exit.sh）──
source "${CLAUDE_PLUGIN_ROOT}/hooks/lib/_wrapper-exit.sh" 2>/dev/null || true
wrapper_exit_cleanup "$EXIT_CODE"
