#!/bin/bash
# SessionStart hook — 项目初始化 + 画像/规则/上下文注入 + 会话状态/管理规则
# 合并 project-init.sh + context-inject.sh + session-rules.sh，单一入口，单一 source
# 测试: bash ~/.claude/tools/session-start.sh [项目目录]

CLAUDE_PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
source "${CLAUDE_PLUGIN_ROOT}/hooks/lib/_common.sh"
detect_project_dir "$1"

# 守护: .claude/context/ 下是数据目录
case "$PROJECT_DIR" in
  *"/.claude/context/"*) exit 0 ;;
esac

CONTEXT_DIR="$PROJECT_DIR/.claude/context"
PROJECT_MD="$CONTEXT_DIR/project.md"
MEMORY_DIR="$PROJECT_DIR/.claude/memory"
SETTINGS_LOCAL="$PROJECT_DIR/.claude/settings.local.json"
CLAUDE_MD="$PROJECT_DIR/CLAUDE.md"
PROJECT_NAME=$(basename "$PROJECT_DIR")
TODAY=$(date +%Y-%m-%d)

# ============================================================
# 项目骨架初始化（原 project-init.sh）
# ============================================================
initialized=0
items=""

if [ ! -f "$PROJECT_MD" ]; then
  mkdir -p "$CONTEXT_DIR"
  cat > "$PROJECT_MD" << PROJECTEOF
---
name: $PROJECT_NAME
description: （待补充）
type: project
updated: $TODAY
---

## 目标

（待补充）

## 核心原则

（待补充）

## 关键决策

（待补充）

## 已执行

（待补充）
PROJECTEOF
  initialized=1
  items="$items  ✓ .claude/context/project.md
"
fi

if [ ! -d "$MEMORY_DIR" ]; then
  mkdir -p "$MEMORY_DIR"
  initialized=1
  items="$items  ✓ .claude/memory/
"
fi

if [ ! -f "$SETTINGS_LOCAL" ]; then
  echo '{}' > "$SETTINGS_LOCAL"
  initialized=1
  items="$items  ✓ .claude/settings.local.json
"
fi

if [ ! -f "$CLAUDE_MD" ]; then
  cat > "$CLAUDE_MD" << CLAUDEEOF
# $PROJECT_NAME

> 项目指针 — 全局规则由 context-inject.sh 注入。

## 架构

- 项目上下文: \`.claude/context/project.md\`
- 全局底线: \`~/.claude/rules.redline\`

## 项目约定

（待补充）
CLAUDEEOF
  initialized=1
  items="$items  ✓ CLAUDE.md
"
fi

if [ "$initialized" -eq 1 ]; then
  echo "=== 项目架构初始化 ==="
  echo "项目: $PROJECT_NAME"
  echo "路径: $PROJECT_DIR"
  echo ""
  echo "已创建："
  echo -n "$items"
  echo ""
  echo "docs/ 目录: 未创建"
  echo ""
fi

# ============================================================
# 命名空间
# ============================================================
echo "命名空间: 全局 $HOME/.claude/ | 项目 $PROJECT_DIR/.claude/（变更必问仅适用全局）"
echo ""

# ============================================================
# 用户画像（全局）
# ============================================================
USER_MD="$HOME/.claude/profile/user.md"
if [ -f "$USER_MD" ]; then
  echo "=== 用户画像 ==="
  cat "$USER_MD"
  echo ""
else
  echo "=== 用户画像 ==="
  echo "（未配置：$USER_MD 不存在）"
  echo ""
fi

# ============================================================
# 行为规则（全局）
# ============================================================
RULES_MD="$HOME/.claude/profile/rules.md"
if [ -f "$RULES_MD" ]; then
  echo "=== 行为规则 ==="
  cat "$RULES_MD"
  echo ""
else
  echo "=== 行为规则 ==="
  echo "（未配置：$RULES_MD 不存在）"
  echo ""
fi

# ============================================================
# 项目上下文（项目级）— 稳定段全文 + 演进段指针
# ============================================================
if [ -f "$PROJECT_MD" ]; then
  echo "=== 项目上下文 ==="

  awk '
    /^## / { section_count++ }
    section_count <= 2 { print }
    section_count == 3 && !printed {
      print ""
      print "> 完整项目上下文（关键决策/已执行/待定）见: .claude/context/project.md"
      print ""
      printed = 1
    }
  ' "$PROJECT_MD"

  echo ""
else
  echo "=== 项目上下文 ==="
  echo "（当前项目尚未初始化 .claude/context/project.md）"
  echo "项目路径: $PROJECT_DIR"
  echo ""
fi

# ============================================================
# 会话记录状态
# ============================================================
echo "=== 会话记录状态 ==="

SESSIONS_DIR="$PROJECT_DIR/.claude/context/sessions"

if [ ! -d "$SESSIONS_DIR" ]; then
  echo "状态: 无会话目录（首次运行？）"
  echo ""
  echo "=== 会话管理规则 ==="
  echo "首次进入项目，.claude/context/ 目录将在首次会话后自动创建。"
  exit 0
fi

# 仅匹配会话文件格式 YYYY-MM-DD_HHMM.md
SESSION_FILES=$(ls -1 "$SESSIONS_DIR"/*.md 2>/dev/null | grep -E '/[0-9]{4}-[0-9]{2}-[0-9]{2}_[0-9]{4}\.md$' | sort -r)

if [ -z "$SESSION_FILES" ]; then
  echo "状态: 无历史会话记录"
  echo ""
  echo "=== 会话管理规则 ==="
  echo "会话文件: 维护 .claude/context/sessions/ 下的会话文件"
  echo "格式: YYYY-MM-DD_HHMM.md，摘要写入文件内 **摘要** 字段"
  echo "摘要/上下文/任务: 由 Claude 填充，自动信息段不可修改"
  echo "任务标记: ### [阻塞] / [进行中] / [完成] 标题"
  echo "STATUS.md: 会话结束时编译，扫描最近 3 个会话文件"
  exit 0
fi

# 当前会话（最新文件，由 wrapper 创建）
CURRENT_SESSION=$(echo "$SESSION_FILES" | head -1)
CURRENT_NAME=$(basename "$CURRENT_SESSION")

echo "当前会话: $CURRENT_NAME"

# 同步创建取证日志（机械安全网）
CURRENT_LOG="${CURRENT_SESSION%.md}.log"
if [ ! -f "$CURRENT_LOG" ]; then
  echo "# $(basename "$CURRENT_LOG")" > "$CURRENT_LOG"
  echo "启动: $(date +%Y-%m-%dT%H:%M:%S+08:00)" >> "$CURRENT_LOG"
fi

# 写入会话指针（供 PostToolUse hook 快速定位）
echo "$CURRENT_SESSION" > "$SESSIONS_DIR/.current-session"

# 崩溃残留检测
CRASH_FILE="$CONTEXT_DIR/.crash"
if [ -f "$CRASH_FILE" ]; then
  echo ""
  echo "WARN_CRASH: $(cat "$CRASH_FILE")"
  echo "CRASH_LOG: $CURRENT_LOG"
fi

# 历史会话（排除当前）
HISTORICAL=$(echo "$SESSION_FILES" | sed -n '2,$p')

if [ -z "$HISTORICAL" ]; then
  echo "历史会话: 无"
else
  HIST_TOTAL=$(echo "$HISTORICAL" | wc -l)

  # 索引驱动统计（替代 xargs grep 全量扫描 + .session-stats 缓存）
  SESSION_INDEX="$SESSIONS_DIR/.session-index"

  if [ ! -f "$SESSION_INDEX" ]; then
    # 首次运行：从现有会话文件一次性迁移构建索引
    MIGRATED=$(session_index_migrate "$SESSIONS_DIR")
    echo "  （会话索引已构建: ${MIGRATED} 条记录）"
  fi

  # 从索引读取统计（O(1) grep 替代 O(n) xargs grep 扫描文件内容）
  read HIST_TOTAL HIST_COMPLETE HIST_SKELETON <<< $(session_index_read "$SESSIONS_DIR")

  echo "历史会话: 共 $HIST_TOTAL，已记录 $HIST_COMPLETE，仅骨架 $HIST_SKELETON"

  # 上次会话（ID 精确查询索引，禁止 tail -1 位置推断 — meta.redline 7a）
  PREV_SESSION=$(echo "$HISTORICAL" | head -1)
  PREV_NAME=$(basename "$PREV_SESSION")
  PREV_DATE="${PREV_NAME:0:10}"
  PREV_TIME="${PREV_NAME:11:4}"
  PREV_STATUS=$(session_index_find "$SESSIONS_DIR" "$PREV_DATE" "$PREV_TIME")
  if [ "$PREV_STATUS" = "skeleton" ]; then
    echo ""
    echo "⚠ 上次会话未记录上下文！"
    echo "  文件: $PREV_NAME（仅骨架）"
    echo "  状态: 上次会话未完整记录"
  elif [ "$PREV_STATUS" = "complete" ]; then
    echo "上次会话: $PREV_NAME（已完整记录）"
  else
    echo "上次会话: $PREV_NAME（状态未知，索引无记录）"
  fi
fi

# ============================================================
# 会话管理规则（指针式 — 详细规则见 CLAUDE.md 和 ~/.claude/tools/session-start.sh 注释）
# ============================================================
echo ""
echo "会话生命周期: 启动(hook注入)→运行(取证)→退出(exit-check→填充→claude-exit)"
echo "崩溃恢复: .crash残留→检查.log取证→接管或重建"
echo "详见 docs/architecture.md 和 ~/.claude/rules.redline"
