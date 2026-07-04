#!/bin/bash
# ============================================================
set -uo pipefail  # fail-open: errors logged, always exit 0
# claude-monitored.sh — 带崩溃监视 + 备份提醒的 Claude 启动器
# ============================================================

CLAUDE_PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
source "${CLAUDE_PLUGIN_ROOT}/hooks/lib/_common.sh"
# 用法:
#   bash ~/.claude/tools/claude-monitored.sh [项目目录]
#
# 功能:
#   1. 启动前：检查备份新鲜度（>7天警告）
#   2. 启动前：快照 ~/.claude/ 关键文件状态
#   3. 启动前：创建会话文件骨架（sessions/）
#   4. 启动 Claude，作为父进程 wait
#   5. 退出后：自动捕获文件变更 → 写入会话文件
#   6. 退出后：多信号判定异常（退出码 + 会话文件存在性）
#   7. 退出后：对比状态快照，有修改则提醒备份
#   8. 退出后：追加会话索引 + 触发月归档
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

# --- 0. 备份新鲜度检查 ---
# （_common.sh 已在顶部 source，提供 BACKUP_DIR_UNIX 等变量）
if [ -f "$HOME/.claude/.backup-config" ]; then
  source "$HOME/.claude/.backup-config"
fi
backup_check_min_interval_hours="${backup_check_min_interval_hours:-6}"
backup_expire_days="${backup_expire_days:-7}"
BACKUP_DIR="${BACKUP_DIR:-$HOME/ClaudecodeBackup}"
BACKUP_PATTERN="claude-backup-[0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9]_[0-9][0-9][0-9][0-9].tar.gz"
if [ -d "$BACKUP_DIR" ]; then
  LATEST_BACKUP=$(ls -t "$BACKUP_DIR_UNIX"/$BACKUP_PATTERN 2>/dev/null | head -1)
  if [ -n "$LATEST_BACKUP" ]; then
    LATEST_NAME=$(basename "$LATEST_BACKUP")
    LATEST_DATE=$(echo "$LATEST_NAME" | grep -oE '[0-9]{8}' | head -1)
    if [ -n "$LATEST_DATE" ]; then
      # 用 date +%s 计算天数差（替代 python3，省 ~100ms 启动开销）
      LATEST_EPOCH=$(date -d "${LATEST_DATE:0:4}-${LATEST_DATE:4:2}-${LATEST_DATE:6:2}" +%s 2>/dev/null)
      if [ -n "$LATEST_EPOCH" ] && [ "$LATEST_EPOCH" -gt 0 ] 2>/dev/null; then
        NOW_EPOCH=$(date +%s)
        DAYS=$(( (NOW_EPOCH - LATEST_EPOCH) / 86400 ))
        if [ "$DAYS" -gt "$backup_expire_days" ] 2>/dev/null; then
          echo "⚠ 上次备份 ${DAYS} 天前（超过 ${backup_expire_days} 天），建议备份（下次会话中说"建议备份"即可自动触发）"
          echo ""
        fi
      fi
    fi
  fi
fi

# --- 1. 会话文件骨架 ---
echo ""
echo "[启动检查] 会话文件..."

mkdir -p "$CONTEXT_DIR/sessions"
SESSION_DATE=$(date +%Y-%m-%d)
SESSION_TIME=$(date +%H%M%S)
SESSION_SLUG="${SESSION_DATE}_${SESSION_TIME}"
SESSION_FILE="$CONTEXT_DIR/sessions/${SESSION_SLUG}.md"
SESSION_TOKEN="session-$$-$(date +%s)-${RANDOM}"
SESSION_START_MARKER="$CONTEXT_DIR/.session-start-time"
SESSION_START_TIME=$(date +%Y-%m-%dT%H:%M:%S+08:00)

cat > "$SESSION_FILE" <<SESSIONEOF
# ${SESSION_SLUG}

<!-- token: ${SESSION_TOKEN} -->

**日期**: ${SESSION_DATE}
**摘要**: （待填充）
**PID**: $$
**开始时间**: ${SESSION_START_TIME}

---

## 自动信息

（会话结束后自动填充）

---

## 上下文

（待填充）

---

## 任务

（待填充）
SESSIONEOF

# 创建时间标记文件用于 diff
touch "$SESSION_START_MARKER"
echo "  ✓ 会话文件: sessions/${SESSION_SLUG}.md"

# Phase B: DB 会话双写
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

# ============================================================
# 退出后处理
# ============================================================

# --- P1: 退出码分类函数 ---
classify_exit_code() {
  case "$1" in
    0)   echo "OK" ;;
    130) echo "SIGINT" ;;
    137) echo "SIGKILL" ;;
    143) echo "SIGTERM" ;;
    127) echo "CMD_NOT_FOUND" ;;
    126) echo "NOT_EXECUTABLE" ;;
    1)   echo "GENERAL_ERROR" ;;
    *)   echo "UNKNOWN" ;;
  esac
}

# --- 3. 会话文件编译 (Phase C): SQLite → Markdown ---
END_TIME=$(date +%Y-%m-%dT%H:%M:%S+08:00)
EXIT_LABEL=$(classify_exit_code "$EXIT_CODE")
SESSION_SLUG="${SESSION_DATE}_${SESSION_TIME}"

# 会话时长（SQLite 已记录 start_time，此处仅展示）
SESSION_FILE="$CONTEXT_DIR/sessions/${SESSION_SLUG}.md"
MCP_CLI="${CLAUDE_PLUGIN_ROOT}/scripts/mcp-cli.sh"

# 从 SQLite 编译 .md（Phase C 主路径，SQLite 始终可用）
if [ -x "$MCP_CLI" ] 2>/dev/null; then
  COMPILED_JSON=$(bash "$MCP_CLI" "$PROJECT_DIR" session_compile_md \
    "{\"slug\":\"$SESSION_SLUG\"}" 2>/dev/null || echo "")
  if [ -n "$COMPILED_JSON" ] && [ "$COMPILED_JSON" != "null" ]; then
    echo "$COMPILED_JSON" | python3 -c "import sys,json; sys.stdout.write(json.load(sys.stdin))" > "$SESSION_FILE" 2>/dev/null
    if [ -s "$SESSION_FILE" ]; then
      echo "[wrapper] 会话文件已编译 (SQLite): sessions/${SESSION_SLUG}.md"
    fi
  fi
fi

# Phase D: 终结合话（wrapper 是唯一生杀权持有者）
# 不在 Stop hook 中关库 — compaction 时 Stop 也会触发，提前关库会导致事件丢失
if [ -x "$MCP_CLI" ] 2>/dev/null; then
  FINALIZE_RESULT=$(bash "$MCP_CLI" "$PROJECT_DIR" session_finalize \
    "{\"slug\":\"$SESSION_SLUG\",\"exit_code\":$EXIT_CODE}" 2>/dev/null || echo '{}')
  FINALIZE_STATUS=$(echo "$FINALIZE_RESULT" | python3 -c "import sys,json; print(json.load(sys.stdin).get('status','error'))" 2>/dev/null || echo "error")
  echo "[wrapper] DB 会话已终结: ${SESSION_SLUG} (status=${FINALIZE_STATUS})"
fi

# .session-index 不再追加。历史索引保留供兜底查询。

# --- 3.6 归档旧会话（30天前移入 archive/YYYY-MM/）---
SESSION_ARCHIVE_DAYS="${session_archive_days:-30}"
bash "${CLAUDE_PLUGIN_ROOT}/scripts/session-archive.sh" "$CONTEXT_DIR/sessions" "$SESSION_ARCHIVE_DAYS" 2>/dev/null || true

# 清理时间标记 + 备份提醒标记
rm -f "$SESSION_START_MARKER"
rm -f "$HOME/.claude/.pending-backup"

# --- 4. 退出状态判定（多信号 + P1 退出码分类诊断） ---
echo ""
echo "[退出判定]"

if [ "$EXIT_CODE" = "0" ] || [ "$EXIT_CODE" = "130" ]; then
    echo "  判定: 正常退出 (exit_code=$EXIT_CODE, $EXIT_LABEL)"
    rm -f "$CRASH_FILE"
else
    echo "  判定: 异常退出 (exit_code=$EXIT_CODE, $EXIT_LABEL)"

    # 按退出码给出诊断提示
    case "$EXIT_CODE" in
      137) echo "  诊断: 进程被 SIGKILL 终止（可能 OOM 或手动 kill -9）" ;;
      143) echo "  诊断: 进程收到 SIGTERM（系统关闭或外部终止）" ;;
      127) echo "  诊断: 命令未找到（PATH 或环境问题）" ;;
      126) echo "  诊断: 命令不可执行（权限或二进制兼容性问题）" ;;
        *) echo "  诊断: 未知异常，下次启动时将检查会话记录完整性" ;;
    esac

    # 崩溃溯源: 追加 CRASH 标记到取证日志（黑匣子自包含）
    SESSION_LOG="${SESSION_FILE%.md}.log"
    if [ -f "$SESSION_LOG" ]; then
      echo "CRASH: exit_code=$EXIT_CODE label=$EXIT_LABEL time=$END_TIME project=$PROJECT_DIR" >> "$SESSION_LOG"
      echo "  .log 已追加 CRASH 标记: $SESSION_LOG"
    fi
    if [ ! -f "$SESSION_FILE" ]; then
        echo "  ⚠ 会话文件缺失，标记为异常"
        mkdir -p "$CONTEXT_DIR"
        cat > "$CRASH_FILE" <<EOF
crash_time=$END_TIME
exit_code=$EXIT_CODE
label=$EXIT_LABEL
project=$PROJECT_DIR
EOF
        echo "  .crash 已写入: $CRASH_FILE"
    else
        echo "  会话文件存在，不标记为崩溃"
        rm -f "$CRASH_FILE"
    fi
fi

# --- 5. 配置修改检测 ---
echo ""
echo "[退出检查] 配置变更..."

LAST_BACKUP_STATE="$HOME/.claude/.last-backup-state"

if [ ! -f "$LAST_BACKUP_STATE" ]; then
  echo "  (无备份记录，跳过)"
else
  CURRENT_STATE="/tmp/claude-current-state-$$"
  snapshot_config "$CURRENT_STATE"

  if diff -q "$LAST_BACKUP_STATE" "$CURRENT_STATE" > /dev/null 2>&1; then
    echo "  ✓ 快照一致（自上次备份后无内容变更）"
  else
    echo "  ⚠ 上次备份后有配置变更，建议备份（下次会话中说"建议备份"即可自动触发）"
    echo "  变更内容:"
    diff "$LAST_BACKUP_STATE" "$CURRENT_STATE" 2>/dev/null | head -10
  fi

  rm -f "$CURRENT_STATE"
fi

echo ""
