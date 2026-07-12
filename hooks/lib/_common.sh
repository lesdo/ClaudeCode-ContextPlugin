#!/bin/bash
# 工具链共享配置 — 所有脚本 source 此文件
TOOLS_VERSION="v5.0"

# ── PATH 修复（cmd 启动 bash 时工具缺失）──────────
export PATH="/usr/bin:/bin:$PATH"
[ -d "$HOME/.local/bin" ] && PATH="$HOME/.local/bin:$PATH"

# ── 备份配置 ─────────────────────────────────────
CONFIG_FILE="$HOME/.claude/.backup-config"
if [ -f "$CONFIG_FILE" ]; then
  source "$CONFIG_FILE"
fi
backup_check_min_interval_hours="${backup_check_min_interval_hours:-6}"
backup_expire_days="${backup_expire_days:-7}"
backup_check_on_start="${backup_check_on_start:-yes}"
KEEP_COUNT="${keep_count:-7}"
MIN_KEEP="${min_keep:-2}"

# ── 阈值配置（ax4: 硬编码数字 → 可配置变量，环境变量覆盖默认值）──
# 分析调度
CP_ANALYSIS_INTERVAL="${CP_ANALYSIS_INTERVAL:-3}"       # 每 N 次会话触发一次分析
# 活跃陷阱
CP_ERROR_RATE_THRESHOLD="${CP_ERROR_RATE_THRESHOLD:-0.1}" # 错误率阈值（0-1）
# 崩溃诊断
CP_EVENT_QUERY_LIMIT="${CP_EVENT_QUERY_LIMIT:-200}"      # events 查询上限
# 任务停滞
CP_STALE_TASK_DAYS="${CP_STALE_TASK_DAYS:-7}"            # 超过 N 天视为停滞
# 决策评审 (ax5: outcome_review 自动触发)
# 理由: 10 会话 ≈ 2-3 个工作日，足够积累足够的决策样本（decay/crash/dedup 每会话可能产生 2-5 条决策）且不超过
# decision_audit 表膨胀速度。min_age=7 天保证决策有足够时间产生"实际后果"（如被 decay 的记忆是否被重新访问）
CP_REVIEW_INTERVAL="${CP_REVIEW_INTERVAL:-10}"           # 每 N 次会话触发一次 outcome_review
CP_REVIEW_MIN_AGE="${CP_REVIEW_MIN_AGE:-7}"              # 只审查 ≥ N 天前的决策
# Opus 对抗式审查 (ax10: Red/Blue/Auditor 调度)
# 理由: 20 会话 ≈ 1-2 周，积累的 diff 通常覆盖 1-3 个特性。低于 20 则 diff 太小（常为单次编辑），
# 高于 30 则 diff 太大（token 超预算）。配合 _MIN_CHANGED_FILES=3 做二次门控
CP_OPUS_INTERVAL="${CP_OPUS_INTERVAL:-20}"             # 每 N 次会话触发一次审查上下文准备
# 学习状态摘要 (Layer 1 渐进式披露)
# 0=关闭, 1=开启 (默认)
CP_LEARNING_STATUS="${CP_LEARNING_STATUS:-1}"
# 健康检查
CP_CLAUDE_MD_LINE_LIMIT="${CP_CLAUDE_MD_LINE_LIMIT:-50}" # CLAUDE.md 行数上限
CP_COMPLEXITY_LINE_LIMIT="${CP_COMPLEXITY_LINE_LIMIT:-150}" # 单文件行数热点阈值
CP_MIN_FILE_LINES="${CP_MIN_FILE_LINES:-10}"              # 极小文件行数阈值
CP_TEST_FILE_MIN="${CP_TEST_FILE_MIN:-3}"                 # 测试文件数底线
CP_SCORE_PENALTY="${CP_SCORE_PENALTY:-2}"                 # 违规扣分值
# Activity 裁剪
CP_ACTIVITY_MAX_ENTRIES="${CP_ACTIVITY_MAX_ENTRIES:-19}"  # activity.md 最大条目数（不含标题）
# ─────────────────────────────────────────────────

# ── Hook 分级（预留，暂不实现门控逻辑）──
# minimal: 仅 SessionStart + Stop
# standard: 全部 6 事件（默认）
# strict: 全部 + 额外验证
CP_HOOK_PROFILE="${CP_HOOK_PROFILE:-standard}"

# ── 遗孤扫描（v5.0: 三维加权判定，ax9/ax10）──
# ax9: 活跃度信号优先级——时间间隔 > 事件计数
CP_ORPHAN_TIME_NONE="${CP_ORPHAN_TIME_NONE:-40}"           # 无事件得分
CP_ORPHAN_TIME_OLD_H="${CP_ORPHAN_TIME_OLD_H:-2}"           # "陈旧"时间阈值（小时）
CP_ORPHAN_TIME_OLD_SCORE="${CP_ORPHAN_TIME_OLD_SCORE:-30}"  # 陈旧得分
CP_ORPHAN_TIME_RECENT_H="${CP_ORPHAN_TIME_RECENT_H:-1}"      # "较新"时间阈值（小时）
CP_ORPHAN_TIME_RECENT_SCORE="${CP_ORPHAN_TIME_RECENT_SCORE:-15}" # 较新得分
CP_ORPHAN_EVENT_FEW="${CP_ORPHAN_EVENT_FEW:-3}"              # 辅助惩罚：事件数<此值且时间旧→惩罚
CP_ORPHAN_EVENT_FEW_PENALTY="${CP_ORPHAN_EVENT_FEW_PENALTY:-10}" # 辅助惩罚分
# ax9: pid liveness
CP_ORPHAN_PID_DEAD="${CP_ORPHAN_PID_DEAD:-35}"              # 进程不存在得分
CP_ORPHAN_PID_NONE="${CP_ORPHAN_PID_NONE:-20}"              # 无PID得分
CP_ORPHAN_PID_UNKNOWN="${CP_ORPHAN_PID_UNKNOWN:-15}"         # PID状态未知得分
# ax9: checkpoint evidence
CP_ORPHAN_CHK_NONE="${CP_ORPHAN_CHK_NONE:-25}"              # 无检查点得分
CP_ORPHAN_CHK_WINDOW_H="${CP_ORPHAN_CHK_WINDOW_H:-2}"        # 检查点时间窗口（小时）
# ax10: two-phase abandon
CP_ORPHAN_ABANDON_SCORE="${CP_ORPHAN_ABANDON_SCORE:-60}"     # abandon 推荐线
CP_ORPHAN_REVIEW_SCORE="${CP_ORPHAN_REVIEW_SCORE:-30}"       # review 推荐线
CP_ORPHAN_COOLDOWN_MIN="${CP_ORPHAN_COOLDOWN_MIN:-30}"       # 二阶段冷却期（分钟）
# ─────────────────────────────────────────────────

# ── 备份目录 ─────────────────────────────────────
BACKUP_DIR="${BACKUP_DIR:-$HOME/ClaudecodeBackup}"
if echo "$BACKUP_DIR" | grep -q '^[A-Za-z]:'; then
  BACKUP_DIR_UNIX="/$(echo "$BACKUP_DIR" | cut -c1 | tr '[:upper:]' '[:lower:]')$(echo "$BACKUP_DIR" | cut -c3- | tr '\\' '/')"
else
  BACKUP_DIR_UNIX="$BACKUP_DIR"
fi
BACKUP_PATTERN="claude-backup-[0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9]_[0-9][0-9][0-9][0-9].tar.gz"

DOC_TECHNICAL_NOTE="$BACKUP_DIR/TECHNICAL_NOTE.md"
DOC_README="$BACKUP_DIR/README.md"

# ── 项目目录检测（多级 fallback）─────────────────
detect_project_dir() {
  if [ -n "${1:-}" ]; then
    PROJECT_DIR="$1"
  elif [ -n "${CLAUDE_PROJECT_DIR:-}" ]; then
    PROJECT_DIR="$CLAUDE_PROJECT_DIR"
  elif [ -n "${CLAUDE_CODE_PROJECT_DIR:-}" ]; then
    PROJECT_DIR="$CLAUDE_CODE_PROJECT_DIR"
  else
    PROJECT_DIR="$PWD"
  fi
}

# ── 备份间隔检查 ─────────────────────────────────
should_check_backup() {
  if [ "$backup_check_on_start" != "yes" ]; then
    return 1
  fi
  if [ "${backup_check_min_interval_hours}" -eq 0 ] 2>/dev/null; then
    return 0
  fi
  local last_check_file="$HOME/.claude/.last-backup-check"
  if [ -f "$last_check_file" ]; then
    local last_check now elapsed
    last_check=$(cat "$last_check_file" 2>/dev/null)
    if [ -n "$last_check" ] && [ "$last_check" -gt 0 ] 2>/dev/null; then
      now=$(date +%s)
      elapsed=$(( (now - last_check) / 3600 ))
      if [ "$elapsed" -lt "${backup_check_min_interval_hours}" ]; then
        echo "备份检查: 跳过（距上次检查 ${elapsed} 小时，间隔 ${backup_check_min_interval_hours}h）"
        return 1
      fi
    fi
  fi
  return 0
}

mark_backup_checked() {
  date +%s > "$HOME/.claude/.last-backup-check"
}

# ── 配置状态快照 ─────────────────────────────────
snapshot_config() {
  local target="$1"
  for path in \
    "$HOME/.claude/CLAUDE.md" \
    "$HOME/.claude/config.json" \
    "$HOME/.claude/settings.json" \
    "$HOME/.claude/settings.local.json" \
    "$HOME/.claude/.backup-ignore" \
    "$HOME/.claude/skills"; do
    if [ -e "$path" ]; then
      if [ -d "$path" ]; then
        (cd "$path" && find . -type f -print0 2>/dev/null | xargs -0 md5sum 2>/dev/null | sort | md5sum | awk '{print $1}')
        echo "  d $path"
      else
        md5sum "$path" 2>/dev/null | awk '{print $1}'
        echo "  f $path"
      fi
    else
      echo "  - $path"
    fi
  done > "$target"
}

session_find_file() {
  local dir="$1" date="$2" time="$3" ext="${4:-md}"
  local f="$dir/${date}_${time}.${ext}"
  [ -f "$f" ] && { echo "$f"; return 0; }
  local archive="$dir/archive/${date:0:7}/${date}_${time}.${ext}"
  [ -f "$archive" ] && { echo "$archive"; return 0; }
  return 1
}

# ── MCP 健康检查（多层验证） ──
# 用法: mcp_health_check <project_dir> <mcp_cli_path>
# 输出（stdout）: ok|error|no_python|missing
# 返回码: 0=ok, 1=不可用
# 三层验证: 文件可执行 → python3 可用 → ensure_schema 成功
mcp_health_check() {
  local project_dir="$1"
  local mcp_cli="${2:-${CLAUDE_PLUGIN_ROOT}/scripts/mcp-cli.sh}"

  if [ ! -x "$mcp_cli" ] 2>/dev/null; then
    echo "missing"
    return 1
  fi
  if ! command -v python3 >/dev/null 2>&1; then
    echo "no_python"
    return 1
  fi
  local health_out health_exit
  health_out=$(bash "$mcp_cli" "$project_dir" ensure_schema 2>&1) || true
  health_exit=$?
  if [ "$health_exit" -ne 0 ]; then
    echo "error"
    return 1
  fi
  echo "ok"
  return 0
}

# ── 崩溃诊断 (Phase C): 纯查询，不修改文件 ──
# 用法: crash_diagnose <session_slug> <project_dir> [mcp_health] [context]
#   mcp_health: 调用方已算出的 MCP 健康状态 (ok|error|no_python|missing)
#               传 "ok" 则走 SQLite 多维诊断；其他值直接降级到 .log 回退
#   context: skeleton（仅骨架）/ partial（有部分事件）/ complete（正常完成）
# 输出: TOOL_COUNT SEVERITY DIAG_FLAGS
#   DIAG_FLAGS: 冒号分隔的诊断标记
#     baseline=N   — 偏离历史基线 N 个标准差（仅 mcp_health=ok 时输出）
#     last_tool=X  — 最后一个工具调用名称/状态
#     fallback=log — 降级到 .log 回退
#     db_error     — SQLite 查询失败
#     no_data      — 无任何事件数据
# 阈值可配置（环境变量）:
#   CP_DIAG_MIN_TOOLS=5       — 低于此值视为异常（默认 5）
#   CP_DIAG_BASELINE_STD=2.0  — 偏离历史基线超过此标准差数视为异常（默认 2.0）
crash_diagnose() {
  local slug="$1"
  local project_dir="$2"
  local mcp_health context

  # 向后兼容：3个参数时第3个是 context；4个参数时第3个是 mcp_health
  if [ $# -ge 4 ]; then
    mcp_health="$3"
    context="$4"
  else
    # 第3个参数若是 ok/error/no_python/missing 则为 health，否则为 context
    case "${3:-skeleton}" in
      ok|error|no_python|missing) mcp_health="$3"; context="skeleton" ;;
      *) mcp_health=""; context="$3" ;;  # 空=未预检，自行探测
    esac
  fi

  local tool_count=0 severity="L3" flags=""
  local min_tools="${CP_DIAG_MIN_TOOLS:-5}"
  local baseline_std="${CP_DIAG_BASELINE_STD:-2.0}"

  local mcp_cli="${CLAUDE_PLUGIN_ROOT:-$(dirname "$(dirname "${BASH_SOURCE[0]}")")}/scripts/mcp-cli.sh"

  # ── Layer 1: 二进制可执行 ──
  if [ ! -x "$mcp_cli" ]; then
    flags="fallback=log"
  # ── Layer 2: 调用方预检结果 —— 明确不可用则跳过SQLite，空值=未预检则继续尝试 ──
  elif [ -n "$mcp_health" ] && [ "$mcp_health" != "ok" ]; then
    flags="fallback=log:health=${mcp_health}"
  else
    # ── Layer 3: 实际查询 + 连接验证 ──
    local events_json
    events_json=$(bash "$mcp_cli" "$project_dir" session_events_by_slug \
      "{\"slug\":\"$slug\",\"limit\":${CP_EVENT_QUERY_LIMIT:-200}}" 2>/dev/null) || true

    if [ -z "$events_json" ]; then
      flags="db_error"  # 查询完全失败（连接断开/超时/schema异常）
    elif [ "$events_json" = "[]" ]; then
      flags="no_events" # DB正常但此会话无事件（可能刚创建或未被 PostTool 记录）
    else
      # 多维信号提取
      tool_count=$(echo "$events_json" | python3 -c "
import sys, json
events = json.load(sys.stdin)
print(len(events))
" 2>/dev/null) || tool_count=0

      if [ "$tool_count" -gt 0 ] 2>/dev/null; then
        # 提取最后一个工具的状态
        local last_tool_info
        last_tool_info=$(echo "$events_json" | python3 -c "
import sys, json
events = json.load(sys.stdin)
if events:
    last = events[-1]
    name = last.get('tool_name','?')
    print(f'{name}')
" 2>/dev/null) || last_tool_info="?"
        flags="last_tool=${last_tool_info:-?}"

        # ── 多维判定 ──
        # 维度1: tool_count 绝对数量
        # 维度2: 与历史基线比较（由分析调度器维护的统计数据）
        # 维度3: 上下文类型（skeleton/partial/complete）
        if [ "$context" = "complete" ] && [ "$tool_count" -gt 0 ]; then
          severity="L0"  # 正常完成且有事件 → 不应标记为崩溃
        elif [ "$tool_count" -ge "$min_tools" ]; then
          severity="L2"
        elif [ "$tool_count" -gt 0 ]; then
          severity="L1"
        fi
        # 注: tool_count == 0 保持默认 L3

        echo "$tool_count $severity $flags"
        return 0
      fi
    fi
  fi

  # ── 回退 .log（MCP 不可用时的降级路径）──
  local session_md="$project_dir/.context/sessions/${slug}.md"
  local session_log="${session_md%.md}.log"
  if [ -f "$session_log" ] && [ -s "$session_log" ]; then
    local crash_line exit_code_log
    crash_line=$(grep "^CRASH:" "$session_log" 2>/dev/null | tail -1)
    exit_code_log=$(grep "^EXIT_CODE:" "$session_log" 2>/dev/null | tail -1 | awk '{print $2}')
    tool_count=$(grep -cE "^- [0-9]{2}:[0-9]{2}:[0-9]{2} " "$session_log" 2>/dev/null || echo "0")

    # 多维判定（.log 回退版本）: tool_count + exit_code + crash标记
    if [ -n "$exit_code_log" ] && [ "$exit_code_log" = "0" ] && [ -z "$crash_line" ]; then
      severity="L0"  # 正常退出 + 无崩溃标记
    elif [ "$tool_count" -gt 0 ] 2>/dev/null; then
      severity="L2"
      if [ "$context" = "skeleton" ] && [ -n "$crash_line" ] && [ "$tool_count" -lt "$min_tools" ] 2>/dev/null; then
        severity="L1"
      fi
    fi
    flags="${flags}:fallback=log"
  else
    flags="${flags}:no_data"
  fi

  echo "$tool_count $severity $flags"
}
