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

BRIEFING_DIR="$CONTEXT_DIR/briefing"
if [ ! -d "$BRIEFING_DIR" ]; then
  mkdir -p "$BRIEFING_DIR"
  initialized=1
  items="$items  ✓ .claude/context/briefing/
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

# 匹配会话文件格式 YYYY-MM-DD_HHMM.md 或 YYYY-MM-DD_HHMMSS.md
SESSION_FILES=$(ls -1 "$SESSIONS_DIR"/*.md 2>/dev/null | grep -E '/[0-9]{4}-[0-9]{2}-[0-9]{2}_[0-9]{4,6}\.md$' | sort -r)

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

# ── P2: 崩溃残留检测 + 严重度分级（L1/L2/L3）──
CRASH_FILE="$CONTEXT_DIR/.crash"
CRASH_SEVERITY=""
if [ -f "$CRASH_FILE" ]; then
  echo ""
  echo "WARN_CRASH: $(cat "$CRASH_FILE")"
  echo "CRASH_LOG: $CURRENT_LOG"
  CRASH_SEVERITY="L3"
  echo "CRASH_SEVERITY: L3 — 会话文件缺失，需人工排查"
fi

# 历史会话（排除当前）
HISTORICAL=$(echo "$SESSION_FILES" | sed -n '2,$p')

# ── 索引初始化（不依赖是否有历史会话）──
SESSION_INDEX="$SESSIONS_DIR/.session-index"

# 当前会话基础名（不含 .md 后缀，供 migrate/reconcile 跳过用）
CURRENT_BASE="${CURRENT_NAME%.md}"

if [ ! -f "$SESSION_INDEX" ]; then
  # 首次运行：从现有会话文件一次性迁移构建索引（跳过当前会话）
  MIGRATED=$(session_index_migrate "$SESSIONS_DIR" "$CURRENT_BASE")
  if [ "$MIGRATED" -gt 0 ] 2>/dev/null; then
    echo "  （会话索引已构建: ${MIGRATED} 条记录）"
  fi
fi

# ── 文件系统→索引修复（处理 wrapper 被中断导致的孤儿会话）
RECONCILED=$(session_index_reconcile "$SESSIONS_DIR" "$CURRENT_BASE")
read REC_ADDED REC_COMPLETE REC_SKELETON <<< "$RECONCILED"
if [ "$REC_ADDED" -gt 0 ] 2>/dev/null; then
  echo "  （孤儿会话已修复: ${REC_ADDED} 条缺失索引已补录）"
fi

# 从索引读取统计
read HIST_TOTAL HIST_COMPLETE HIST_SKELETON <<< $(session_index_read "$SESSIONS_DIR")

if [ -z "$HISTORICAL" ]; then
  echo "历史会话: 无"
else
  echo "历史会话: 共 $HIST_TOTAL，已记录 $HIST_COMPLETE，仅骨架 $HIST_SKELETON"

  # 上次会话（ID 精确查询索引，禁止 tail -1 位置推断 — meta.redline 7a）
  PREV_SESSION=$(echo "$HISTORICAL" | head -1)
  PREV_NAME=$(basename "$PREV_SESSION")
  PREV_DATE="${PREV_NAME:0:10}"
  PREV_TIME="${PREV_NAME:11:6}"
  PREV_STATUS=$(session_index_find "$SESSIONS_DIR" "$PREV_DATE" "$PREV_TIME")
  if [ "$PREV_STATUS" = "skeleton" ]; then
    echo ""
    echo "⚠ 上次会话未记录上下文！"
    echo "  文件: $PREV_NAME（仅骨架）"

    PREV_LOG="${PREV_SESSION%.md}.log"
    read TOOL_COUNT PREV_SEVERITY DID_FILL <<< $(crash_auto_fill "$PREV_SESSION" "$PREV_LOG" "skeleton")

    if [ "$PREV_SEVERITY" = "L3" ]; then
      if [ ! -f "$PREV_LOG" ] || [ ! -s "$PREV_LOG" ]; then
        echo "  状态: 骨架（无取证日志文件）"
      else
        echo "  状态: 骨架（无取证数据可填充）"
      fi
    elif [ "$DID_FILL" = "1" ]; then
      echo "  状态: ✅ 已自动填充 (${TOOL_COUNT} 次工具调用, 严重度 ${PREV_SEVERITY})"
    else
      echo "  状态: 骨架（占位符已变更，跳过自动填充）"
    fi

    # 输出严重度分级（供 AI 启动报告使用）
    case "${PREV_SEVERITY:-L3}" in
      L1) echo "  CRASH_SEVERITY: L1 — 短会话/少量操作，无实质损失" ;;
      L2) echo "  CRASH_SEVERITY: L2 — 有取证数据，已自动填充，可恢复上下文" ;;
      L3) echo "  CRASH_SEVERITY: L3 — 数据缺失，需人工排查" ;;
    esac
  elif [ "$PREV_STATUS" = "complete" ]; then
    echo "上次会话: $PREV_NAME（已完整记录）"
  else
    # FP3: "unknown" → 文件系统直接恢复（索引可能因 wrapper 中断缺失）
    echo "上次会话: $PREV_NAME（索引无记录，从文件系统检测...）"
    echo ""

    PREV_LOG="${PREV_SESSION%.md}.log"
    if [ -f "$PREV_LOG" ] && [ -s "$PREV_LOG" ]; then
      read TOOL_COUNT PREV_SEVERITY DID_FILL <<< $(crash_auto_fill "$PREV_SESSION" "$PREV_LOG" "unknown")
      echo "  状态: ✅ 取证日志存在（${TOOL_COUNT} 次工具调用），可恢复"

      CRASH_LABEL=$(grep "^CRASH:" "$PREV_LOG" 2>/dev/null | tail -1 | grep -oE 'label=[A-Z_]+' | cut -d= -f2)
      [ -n "$CRASH_LABEL" ] && echo "  CRASH 标记: ${CRASH_LABEL}"

      if [ "$DID_FILL" = "1" ]; then
        echo "  自动填充: ✅ 已完成"
      elif [ "$PREV_SEVERITY" != "L3" ]; then
        echo "  自动填充: 跳过（占位符已变更）"
      fi
    else
      if grep -q "（待填充）" "$PREV_SESSION" 2>/dev/null; then
        echo "  状态: 骨架（仅文件存在，无日志，无工具调用）"
      else
        echo "  状态: 已记录（文件存在，内容已填充，但索引缺失）"
      fi
    fi
  fi
fi

# ============================================================
# Phase B: SQLite 集成 — 健康哨兵 + 会话状态 + 简报注入
# ============================================================
MCP_CLI="${CLAUDE_PLUGIN_ROOT}/scripts/mcp-cli.sh"
MCP_HEALTH="unknown"

if [ ! -x "$MCP_CLI" ] 2>/dev/null; then
  echo ""
  echo "⚠ MCP: mcp-cli.sh 不可用（文件缺失或无执行权限）"
  MCP_HEALTH="missing"
elif ! command -v python3 >/dev/null 2>&1; then
  echo ""
  echo "⚠ MCP: python3 未安装 — SQLite 管线不可用"
  MCP_HEALTH="no_python"
else
  # ── 健康哨兵: 快速验证 Python + MCP + DB 可用性 ──
  HEALTH_OUT=$(bash "$MCP_CLI" "$PROJECT_DIR" ensure_schema 2>&1)
  HEALTH_EXIT=$?
  if [ $HEALTH_EXIT -ne 0 ]; then
    echo ""
    echo "⚠ MCP: SQLite 管线异常（ensure_schema 失败, exit=$HEALTH_EXIT）"
    echo "  详情: ${HEALTH_OUT:-(无输出)}"
    MCP_HEALTH="error"
  else
    MCP_HEALTH="ok"
  fi
fi

BRIEFING_FILE="$CONTEXT_DIR/briefing/active.md"

if [ "$MCP_HEALTH" = "ok" ]; then
  # bug#2: mark crash residues as abandoned (auto-skips when only 1 active)
  RESULT=$(bash "$MCP_CLI" "$PROJECT_DIR" session_mark_abandoned 2>/dev/null || echo "{}")
  ABANDONED_COUNT=$(echo "$RESULT" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('rowcount',0))" 2>/dev/null || echo "0")
  if [ "$ABANDONED_COUNT" -gt 0 ] 2>/dev/null; then
    echo ""
    echo "WARN_DB: ${ABANDONED_COUNT} old sessions marked abandoned"
  fi

  # 简报注入 + 落盘到文件 (Tier 1, <=500 tokens)
  BRIEFING=$(bash "$MCP_CLI" "$PROJECT_DIR" briefing_generate 2>/dev/null)
  if [ -n "$BRIEFING" ] && [ "$BRIEFING" != "null" ]; then
    echo ""
    echo "=== 会话简报 (DB) ==="
    echo "$BRIEFING"
    echo ""
    # 写入文件供 PreCompact/PostCompact 使用
    mkdir -p "$(dirname "$BRIEFING_FILE")"
    echo "$BRIEFING" > "$BRIEFING_FILE"
  fi

  # DB 统计速览
  DB_STATS=$(bash "$MCP_CLI" "$PROJECT_DIR" stats_overview 2>/dev/null || echo '{}')
  DB_SESSIONS=$(echo "$DB_STATS" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('total_sessions','?'))" 2>/dev/null)
  DB_MEMS=$(echo "$DB_STATS" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('total_memories','?'))" 2>/dev/null)
  echo "DB 速览: ${DB_SESSIONS:-?} 会话, ${DB_MEMS:-?} 记忆"
elif [ -f "$BRIEFING_FILE" ] && [ -s "$BRIEFING_FILE" ]; then
  # DB 不可用时的文件 fallback
  echo ""
  echo "=== 会话简报（文件缓存）==="
  cat "$BRIEFING_FILE"
  echo ""
  echo "⚠ 以上为上次缓存，DB 不可用时使用。"
fi

# ============================================================
# 会话管理规则（指针式 — 详细规则见 CLAUDE.md 和 ~/.claude/tools/session-start.sh 注释）
# ============================================================
echo ""
echo "会话生命周期: 启动(hook注入)→运行(取证)→退出(exit-check→填充→claude-exit)"
echo "崩溃恢复: .crash残留→检查.log取证→接管或重建"
echo "详见 docs/architecture.md 和 ~/.claude/rules.redline"
