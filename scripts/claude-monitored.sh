#!/bin/bash
# ============================================================
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
CONTEXT_DIR="$PROJECT_DIR/.claude/context"
CRASH_FILE="$CONTEXT_DIR/.crash"
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
          echo "⚠ 上次备份 ${DAYS} 天前（超过 ${backup_expire_days} 天），建议: bash ${CLAUDE_PLUGIN_ROOT}/scripts/backup-claude.sh"
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
SESSION_TIME=$(date +%H%M)
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

# --- 3. 会话文件更新：文件变更 + 退出信息 ---
END_TIME=$(date +%Y-%m-%dT%H:%M:%S+08:00)
# 计算会话时长（纯 bash date +%s 算术，无需 python3）
if [ -f "$SESSION_START_MARKER" ]; then
  START_EPOCH=$(stat -c %Y "$SESSION_START_MARKER" 2>/dev/null)
  END_EPOCH=$(date +%s)
  DURATION_MIN=$(( (END_EPOCH - START_EPOCH) / 60 ))
else
  DURATION_MIN="?"
fi

echo "  会话时长: ${DURATION_MIN} 分钟"

# 查找会话期间修改的文件（排除 .claude/、node_modules、.git 等）
MODIFIED_FILES=""
if [ -f "$SESSION_START_MARKER" ]; then
  MODIFIED_FILES=$(find "$PROJECT_DIR" -newer "$SESSION_START_MARKER" -type f -not -path "*/.claude/*" -not -path "*/node_modules/*" -not -path "*/.git/*" -not -path "*/__pycache__/*" -not -path "*/ClaudecodeBackup/*" 2>/dev/null | head -50 | sort)
fi

# 用令牌查找会话文件（AI 可能已改名）
SESSION_FILE=$(grep -l "token: ${SESSION_TOKEN}" "$CONTEXT_DIR/sessions/"*.md 2>/dev/null | head -1)
if [ -n "$SESSION_FILE" ]; then
  # 构建退出摘要，插入 ## 自动信息 段
  EXIT_BLOCK_FILE=$(mktemp)
  cat > "$EXIT_BLOCK_FILE" <<EXITEOF
- **结束时间**: ${END_TIME}
- **退出码**: ${EXIT_CODE}
- **时长**: ${DURATION_MIN} 分钟

### 文件变更

$(if [ -n "$MODIFIED_FILES" ]; then
  echo "$MODIFIED_FILES" | while IFS= read -r f; do
    echo "- \`${f}\`"
  done
else
  echo "（无文件变更）"
fi)
EXITEOF
  if grep -q "（会话结束后自动填充）" "$SESSION_FILE" 2>/dev/null; then
    sed -i "/（会话结束后自动填充）/{
      r $EXIT_BLOCK_FILE
      d
    }" "$SESSION_FILE"
  else
    sed -i "/^## 自动信息/{
      r $EXIT_BLOCK_FILE
    }" "$SESSION_FILE"
  fi
  rm -f "$EXIT_BLOCK_FILE"

	  echo "[wrapper] 会话文件已更新: sessions/$(basename "$SESSION_FILE")"
  if [ -n "$MODIFIED_FILES" ]; then
    CHANGED_COUNT=$(echo "$MODIFIED_FILES" | wc -l)
    echo "  文件变更: ${CHANGED_COUNT} 个文件"
  else
    echo "  文件变更: 无"
  fi
fi

# --- 3.5 追加会话索引 + 写入闭环校验（meta.redline 7c）---
SESSION_STATUS="complete"
grep -q "（待填充）" "$SESSION_FILE" 2>/dev/null && SESSION_STATUS="skeleton"
session_index_append "$CONTEXT_DIR/sessions" "$SESSION_DATE" "$SESSION_TIME" "$SESSION_STATUS"

# 写入后立即读回校验（禁止 fire-and-forget）
VERIFY_STATUS=$(session_index_find "$CONTEXT_DIR/sessions" "$SESSION_DATE" "$SESSION_TIME")
if [ "$VERIFY_STATUS" = "$SESSION_STATUS" ]; then
  echo "  会话索引: ${SESSION_DATE}_${SESSION_TIME} (${SESSION_STATUS}) ✓"
else
  echo "  会话索引: ${SESSION_DATE}_${SESSION_TIME} 写入失败！(预期=${SESSION_STATUS}, 读到=${VERIFY_STATUS})" >&2
fi

# --- 3.6 归档旧会话（30天前移入 archive/YYYY-MM/）---
SESSION_ARCHIVE_DAYS="${session_archive_days:-30}"
bash "${CLAUDE_PLUGIN_ROOT}/scripts/session-archive.sh" "$CONTEXT_DIR/sessions" "$SESSION_ARCHIVE_DAYS" 2>/dev/null || true

# 清理时间标记 + 备份提醒标记
rm -f "$SESSION_START_MARKER"
rm -f "$HOME/.claude/.pending-backup"

# --- 4. 退出状态判定（多信号） ---
echo ""
echo "[退出判定]"

if [ "$EXIT_CODE" = "0" ] || [ "$EXIT_CODE" = "130" ]; then
    echo "  判定: 正常退出 (exit_code=$EXIT_CODE)"
    rm -f "$CRASH_FILE"
else
    echo "  判定: 非标准退出 (exit_code=$EXIT_CODE)"
    echo "  （可能是手动关闭终端，下次启动时将检查会话记录完整性）"

	    # 崩溃溯源: 追加 CRASH 标记到取证日志（黑匣子自包含）
	    SESSION_LOG="${SESSION_FILE%.md}.log"
	    if [ -f "$SESSION_LOG" ]; then
	      echo "CRASH: exit_code=$EXIT_CODE time=$END_TIME project=$PROJECT_DIR" >> "$SESSION_LOG"
	      echo "  .log 已追加 CRASH 标记: $SESSION_LOG"
	    fi
    if [ ! -f "$SESSION_FILE" ]; then
        echo "  ⚠ 会话文件缺失，标记为异常"
        mkdir -p "$CONTEXT_DIR"
        cat > "$CRASH_FILE" <<EOF
crash_time=$END_TIME
exit_code=$EXIT_CODE
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
    echo "  ⚠ 上次备份后有配置变更，建议执行: bash ${CLAUDE_PLUGIN_ROOT}/scripts/backup-claude.sh \"变更说明\""
    echo "  变更内容:"
    diff "$LAST_BACKUP_STATE" "$CURRENT_STATE" 2>/dev/null | head -10
  fi

  rm -f "$CURRENT_STATE"
fi

echo ""
