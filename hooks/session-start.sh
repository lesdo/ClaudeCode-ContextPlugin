#!/bin/bash
# SessionStart hook — 项目初始化 + 画像/规则/上下文注入 + 会话状态/管理规则
set -uo pipefail  # fail-open: errors logged, always exit 0
# 合并 project-init.sh + context-inject.sh + session-rules.sh，单一入口，单一 source
# 测试: bash ~/.claude/tools/session-start.sh [项目目录]

CLAUDE_PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
source "${CLAUDE_PLUGIN_ROOT}/hooks/lib/_common.sh"
detect_project_dir "${1:-}"

# 守护: .claude/context/ 下是数据目录
case "$PROJECT_DIR" in
  *"/.claude/context/"*) exit 0 ;;
esac

CONTEXT_DIR="$PROJECT_DIR/.context"
CLAUDE_CONTEXT_DIR="$PROJECT_DIR/.claude/context"
PROJECT_MD="$CLAUDE_CONTEXT_DIR/project.md"
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
  mkdir -p "$CLAUDE_CONTEXT_DIR"
  cat > "$PROJECT_MD" << 'PROJECTEOF'
---
name: %NAME%
description: （待补充）
type: project
updated: %DATE%
---

## 目标

（待补充：这个项目要解决什么问题）

## 核心原则

（待补充：架构约束、技术选型底线、团队约定）

## 关键决策

（待补充：记录"为什么选了 A 而不是 B"，每条决策标注日期）

## 架构

详见 `docs/architecture.md`。
PROJECTEOF
  sed -i "s/%NAME%/$PROJECT_NAME/g; s/%DATE%/$TODAY/g" "$PROJECT_MD"
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
  items="$items  ✓ .context/briefing/
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
# 会话记录状态（精简版 — 不暴露文件系统路径，SQLite 为唯一源）
# ============================================================

SESSIONS_DIR="$CONTEXT_DIR/sessions"

if [ ! -d "$SESSIONS_DIR" ]; then
  echo "=== 会话记录状态 ==="
  echo "状态: 无会话目录（首次运行？）"
  echo "（SQLite 管线将在下方初始化）"
  echo ""
fi

# ── SQLite + MCP 管线初始化 ──
MCP_CLI="${CLAUDE_PLUGIN_ROOT}/scripts/mcp-cli.sh"
MCP_HEALTH=$(mcp_health_check "$PROJECT_DIR" "$MCP_CLI")

# ── P2: 崩溃残留检测 ──
CRASH_FILE="$CLAUDE_CONTEXT_DIR/.crash"
if [ -f "$CRASH_FILE" ]; then
  # 从 .crash 提取 slug 用于多维诊断
  CRASH_SLUG=$(head -1 "$CRASH_FILE" 2>/dev/null | grep -oE '[0-9]{8}_[0-9]{6}' | head -1)
  if [ -n "$CRASH_SLUG" ] && [ "$MCP_HEALTH" = "ok" ]; then
    read C_TOOLS C_SEV C_FLAGS <<< $(crash_diagnose "$CRASH_SLUG" "$PROJECT_DIR" "$MCP_HEALTH" "skeleton")
  else
    C_TOOLS="?"; C_SEV="L3"; C_FLAGS="health=${MCP_HEALTH}"
  fi
  echo ""
  echo "=== 崩溃警告 ==="
  echo "WARN_CRASH: $(cat "$CRASH_FILE")"
  echo "CRASH_SEVERITY: ${C_SEV} (tools=${C_TOOLS}, flags=${C_FLAGS})"
  case "$C_SEV" in
    L0) echo "  → 诊断: 疑似正常退出，残留文件可安全删除" ;;
    L1) echo "  → 诊断: 轻微异常，建议 /recover 检查" ;;
    L2) echo "  → 诊断: 中度崩溃，建议执行 /recover" ;;
    L3) echo "  → 诊断: 严重崩溃或数据缺失，需人工排查" ;;
  esac
fi

# ── 会话统计（仅 SQLite，不暴露文件路径）──
BRIEFING_FILE="$CONTEXT_DIR/briefing/active.md"
echo "=== 会话记录状态 ==="
if [ "$MCP_HEALTH" = "ok" ]; then
  STATS_JSON=$(bash "$MCP_CLI" "$PROJECT_DIR" session_stats 2>/dev/null)
  STATS_EXIT=$?
  if [ $STATS_EXIT -ne 0 ] || [ -z "$STATS_JSON" ] || [ "$STATS_JSON" = "null" ]; then
    echo "历史会话: DB 查询失败（exit=${STATS_EXIT}），使用 session_mine 工具查询"
  else
    HIST_TOTAL=$(echo "$STATS_JSON" | python3 -c "import sys,json; print(json.load(sys.stdin).get('total',0))" 2>/dev/null || echo "?")
    HIST_COMPLETE=$(echo "$STATS_JSON" | python3 -c "import sys,json; print(json.load(sys.stdin).get('complete',0))" 2>/dev/null || echo "?")
    echo "历史会话: ${HIST_TOTAL} 次 (完整 ${HIST_COMPLETE})"
  fi
else
  echo "历史会话: MCP 不可用（${MCP_HEALTH}），使用 session_mine 工具查询"
fi

# ============================================================
# Phase B: SQLite 集成 — 简报注入
# ============================================================

if [ "$MCP_HEALTH" = "ok" ]; then
  # bug#2: mark crash residues as abandoned (auto-skips when only 1 active)
  RESULT=$(bash "$MCP_CLI" "$PROJECT_DIR" session_mark_abandoned 2>/dev/null)
  ABANDON_EXIT=$?
  if [ $ABANDON_EXIT -ne 0 ]; then
    echo ""
    echo "⚠ session_mark_abandoned 失败 (exit=$ABANDON_EXIT)，跳过残留清理"
  elif [ -n "$RESULT" ] && [ "$RESULT" != "null" ]; then
    ABANDONED_COUNT=$(echo "$RESULT" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('rowcount',0))" 2>/dev/null || echo "0")
    if [ "$ABANDONED_COUNT" -gt 0 ] 2>/dev/null; then
      echo ""
      echo "WARN_DB: ${ABANDONED_COUNT} old sessions marked abandoned"
    fi
  fi

  # ── v5.0: 3D orphan scan (ax9: time-based, ax10: two-phase) ──
  ORPHAN_JSON=$(bash "$MCP_CLI" "$PROJECT_DIR" session_orphan_scan     '{"auto_abandon":true}' 2>/dev/null)
  ORPHAN_EXIT=$?

  if [ $ORPHAN_EXIT -ne 0 ] || [ -z "$ORPHAN_JSON" ] || [ "$ORPHAN_JSON" = "null" ]; then
    echo ""
    echo "⚠ 遗孤扫描失败（exit=$ORPHAN_EXIT），跳过。不影响正常使用。"
  else
    ABANDONED=$(echo "$ORPHAN_JSON" | python3 -c       "import sys,json; print(json.load(sys.stdin).get('recommendations',{}).get('abandon',0))" 2>/dev/null || echo "0")
    SUSPECT=$(echo "$ORPHAN_JSON" | python3 -c       "import sys,json; print(json.load(sys.stdin).get('recommendations',{}).get('suspect',0))" 2>/dev/null || echo "0")
    REVIEW_COUNT=$(echo "$ORPHAN_JSON" | python3 -c       "import sys,json; print(json.load(sys.stdin).get('recommendations',{}).get('review',0))" 2>/dev/null || echo "0")

    if [ "${ABANDONED:-0}" -gt 0 ] 2>/dev/null; then
      echo "WARN_DB: ${ABANDONED} suspect sessions confirmed abandoned (two-phase complete)"
    fi
    if [ "${SUSPECT:-0}" -gt 0 ] 2>/dev/null; then
      echo "WARN_DB: ${SUSPECT} sessions marked suspect — next startup will confirm or clear"
    fi
    if [ "${REVIEW_COUNT:-0}" -gt 0 ] 2>/dev/null; then
      echo ""
      echo "WARN_ORPHAN: ${REVIEW_COUNT} 个会话疑似遗留，建议 /recover 检查："
      echo "$ORPHAN_JSON" | python3 -c "
import sys,json
for s in json.load(sys.stdin).get('sessions',[]):
    if s.get('recommendation')=='review':
        print(f"  ⚠ {s['slug']} score={s['orphan_score']}")
" 2>/dev/null
      echo ""
    fi

    ERRORS=$(echo "$ORPHAN_JSON" | python3 -c       "import sys,json; errs=json.load(sys.stdin).get('errors',[]); print(len(errs))" 2>/dev/null || echo "0")
    if [ "${ERRORS:-0}" -gt 0 ] 2>/dev/null; then
      echo "⚠ 遗孤扫描中 ${ERRORS} 个非致命错误（如检查点文件读取失败）。"
    fi
  fi

  # 简报注入 + 落盘到文件 (≤500 tokens)
  BRIEFING=$(bash "$MCP_CLI" "$PROJECT_DIR" briefing_generate 2>/dev/null)
  BRIEF_EXIT=$?
  if [ $BRIEF_EXIT -ne 0 ]; then
    echo ""
    echo "⚠ 简报生成失败 (exit=$BRIEF_EXIT)，降级到文件缓存"
  elif [ -n "$BRIEFING" ] && [ "$BRIEFING" != "null" ]; then
    echo ""
    echo "=== 上次会话 ==="
    echo "$BRIEFING"
    # 附加 checkpoint 指针
    LATEST_CHECKPOINT=$(ls -t "$PROJECT_DIR/.lifecycle/checkpoints/"*.md 2>/dev/null | head -1)
    if [ -n "$LATEST_CHECKPOINT" ]; then
      echo "深度恢复: $(basename "$LATEST_CHECKPOINT") — 用 session_mine 或 Read 加载"
    fi
    echo ""
    # 写入文件供 PreCompact/PostCompact 使用
    mkdir -p "$(dirname "$BRIEFING_FILE")"
    echo "$BRIEFING" > "$BRIEFING_FILE"
  fi
elif [ -f "$BRIEFING_FILE" ] && [ -s "$BRIEFING_FILE" ]; then
  # DB 不可用时的文件 fallback
  echo ""
  echo "=== 会话简报（文件缓存）==="
  cat "$BRIEFING_FILE"
  echo ""
  echo "⚠ 以上为上次缓存，DB 不可用时使用。"
fi

# ============================================================
# v4.0: 活跃陷阱注入 — 近 30 天高频错误工具
# ============================================================

if [ "$MCP_HEALTH" = "ok" ]; then
  PITFALL_JSON=$(bash "$MCP_CLI" "$PROJECT_DIR" get_behavior_profile \
    '{"dimension":"error_rate"}' 2>/dev/null || echo '{"profile":[]}')
  PITFALL_COUNT=$(echo "$PITFALL_JSON" | python3 -c "
import sys,json,os
threshold = float(os.environ.get('CP_ERROR_RATE_THRESHOLD','0.1'))
p = json.load(sys.stdin).get('profile',[])
print(len([x for x in p if float(x['value']) > threshold]))
" 2>/dev/null || echo "0")

  if [ "$PITFALL_COUNT" -gt 0 ] 2>/dev/null; then
    echo "=== 活跃陷阱（近 30 天高频错误） ==="
    echo "$PITFALL_JSON" | python3 -c "
import sys,json,os
threshold = float(os.environ.get('CP_ERROR_RATE_THRESHOLD','0.1'))
profile = json.load(sys.stdin).get('profile',[])
for p in profile:
    if float(p['value']) > threshold:
        print(f\"  ⚠ {p['key']}: {int(float(p['value'])*100)}% 错误率\")
" 2>/dev/null
    echo ""
  fi
fi

# ============================================================
# v4.5: 活跃任务注入 — 跨会话未完成任务
# ============================================================

PLANNING_INDEX="${PROJECT_DIR}/.planning/index.json"
export PLANNING_INDEX
if [ -f "$PLANNING_INDEX" ]; then
  TASK_OUTPUT=$(python3 -c "
import json, os

idx_path = os.environ.get('PLANNING_INDEX', '')
with open(idx_path, encoding='utf-8') as f:
    idx = json.load(f)

active = idx.get('active', '')
plans = idx.get('plans', {})
if not active or plans.get(active, {}).get('status') not in ('active', 'paused'):
    exit(0)

state_path = os.path.join(os.path.dirname(idx_path), active, 'state.json')
if not os.path.exists(state_path):
    exit(0)

with open(state_path, encoding='utf-8') as f:
    state = json.load(f)

tasks = [t for t in state.get('tasks', [])
         if t.get('status') not in ('completed', 'abandoned')]
if not tasks:
    exit(0)

print('=== 活跃任务（跨会话未完成） ===')
print('')
marks = {'pending': '[ ]', 'in_progress': '[→]'}
for t in tasks:
    mark = marks.get(t.get('status', ''), '[?]')
    subj = t.get('subject', 'Untitled')
    tid = t.get('id', '')[:8]
    print(f'  {mark} {subj}  (id: {tid})')
print('')
" 2>/dev/null || true)

  if [ -n "$TASK_OUTPUT" ]; then
    echo "$TASK_OUTPUT"
  fi
fi

# ============================================================
# 会话管理规则（指针式 — 详细规则见 CLAUDE.md 和 ~/.claude/tools/session-start.sh 注释）
# ============================================================
echo ""
echo "会话生命周期: 启动(hook注入)→运行(取证)→退出(Stop hook→wrapper编译→claude-exit)"
echo "崩溃恢复: .crash残留→检查.log取证→接管或重建"
echo "详见 docs/architecture.md 和 ~/.claude/rules.redline"
