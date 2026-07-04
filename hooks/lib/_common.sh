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

# ── 会话索引操作 (Phase D: deprecated, 由 SQLite sessions 表替代) ──
# 保留供 MCP 不可用时的兜底查询。不再写入新条目。

session_index_read() {
  local dir="$1"
  local index="$dir/.session-index"
  if [ ! -f "$index" ]; then
    echo "0 0 0"
    return
  fi
  local total complete skeleton
  total=$(wc -l < "$index" 2>/dev/null || echo 0)
  complete=$(grep -c '"status":"complete"' "$index" 2>/dev/null || echo 0)
  skeleton=$(grep -c '"status":"skeleton"' "$index" 2>/dev/null || echo 0)
  echo "$total $complete $skeleton"
}

session_index_tail() {
  local dir="$1" n="${2:-1}"
  local index="$dir/.session-index"
  [ -f "$index" ] && tail -n "$n" "$index" 2>/dev/null
}

session_index_find() {
  local dir="$1" date="$2" time="$3"
  local index="$dir/.session-index"
  [ ! -f "$index" ] && { echo "unknown"; return 0; }
  local result
  result=$(grep -F "{\"date\":\"$date\",\"time\":\"$time\"" "$index" 2>/dev/null | tail -1)
  if [ -n "$result" ]; then
    case "$result" in
      *'"status":"skeleton"'*) echo "skeleton"; return 0 ;;
      *'"status":"complete"'*) echo "complete"; return 0 ;;
    esac
  fi
  echo "unknown"
}

session_find_file() {
  local dir="$1" date="$2" time="$3" ext="${4:-md}"
  local f="$dir/${date}_${time}.${ext}"
  [ -f "$f" ] && { echo "$f"; return 0; }
  local archive="$dir/archive/${date:0:7}/${date}_${time}.${ext}"
  [ -f "$archive" ] && { echo "$archive"; return 0; }
  return 1
}

# ── 崩溃诊断 (Phase C): 纯查询，不修改文件 ──
# 用法: crash_diagnose <session_slug> <project_dir> [context]
# 输出: TOOL_COUNT SEVERITY（无 DID_FILL，不做 sed 注入）
crash_diagnose() {
  local slug="$1"
  local project_dir="$2"
  local context="${3:-skeleton}"
  local tool_count=0 severity="L3"

  # 尝试 SQLite
  local mcp_cli="${CLAUDE_PLUGIN_ROOT:-$(dirname "$(dirname "${BASH_SOURCE[0]}")")}/scripts/mcp-cli.sh"
  if [ -x "$mcp_cli" ] 2>/dev/null; then
    local events_json
    events_json=$(bash "$mcp_cli" "$project_dir" session_events_by_slug \
      "{\"slug\":\"$slug\",\"limit\":200}" 2>/dev/null || echo "[]")
    if [ "$events_json" != "[]" ] && [ -n "$events_json" ]; then
      tool_count=$(echo "$events_json" | python3 -c "import sys,json; print(len(json.load(sys.stdin)))" 2>/dev/null || echo "0")
      if [ "$tool_count" -gt 0 ] 2>/dev/null; then
        severity="L2"
        echo "$tool_count $severity"
        return 0
      fi
    fi
  fi

  # 回退 .log
  local session_md="$project_dir/.context/sessions/${slug}.md"
  local session_log="${session_md%.md}.log"
  if [ -f "$session_log" ] && [ -s "$session_log" ]; then
    local crash_line
    crash_line=$(grep "^CRASH:" "$session_log" 2>/dev/null | tail -1)
    tool_count=$(grep -cE "^- [0-9]{2}:[0-9]{2}:[0-9]{2} " "$session_log" 2>/dev/null || echo "0")

    severity="L2"
    if [ "$context" = "skeleton" ]; then
      if [ -n "$crash_line" ]; then
        if [ "$tool_count" -lt 5 ] 2>/dev/null; then severity="L1"; fi
      elif [ "$tool_count" -eq 0 ] 2>/dev/null; then
        severity="L3"
      fi
    fi
  fi

  echo "$tool_count $severity"
}
