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

# ── 会话索引操作（轻量，纯 shell，零外部依赖）────
# 索引文件: $SESSIONS_DIR/.session-index
# 格式: JSONL，每行 {"date":"YYYY-MM-DD","time":"HHMM","status":"complete|skeleton"}

session_index_append() {
  local dir="$1" date="$2" time="$3" status="$4"
  local index="$dir/.session-index"
  printf '{"date":"%s","time":"%s","status":"%s"}\n' "$date" "$time" "$status" >> "$index"
}

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

session_index_migrate() {
  local dir="$1"
  local skip_name="$2"
  local index="$dir/.session-index"
  local count=0

  for f in "$dir"/[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]_*.md; do
    [ -f "$f" ] || continue
    local name=$(basename "$f" .md)
    local date="${name:0:10}"
    local time="${name:11:6}"
    # 提取连续数字部分（兼容 HHMM 和 HHMMSS）
    time=$(echo "$time" | grep -oE '^[0-9]+' | head -1)
    [ -z "$time" ] && time="0000"

    # 跳过当前会话
    [ "$name" = "$skip_name" ] && continue

    if ! echo "$time" | grep -qE '^[0-9]{4,6}$'; then
      time=$(grep -oE "^# [0-9]{4}-[0-9]{2}-[0-9]{2}_[0-9]{4,6}" "$f" 2>/dev/null | head -1 | grep -oE '[0-9]{4,6}$')
      [ -z "$time" ] && time="0000"
    fi

    local status="complete"
    grep -q "（待填充）" "$f" 2>/dev/null && status="skeleton"
    session_index_append "$dir" "$date" "$time" "$status"
    count=$((count + 1))
  done

  echo "$count"
}

# ── 会话索引修复: 文件系统 → 索引（wrapper 被中断的补录安全网）──
# 扫描 sessions/ 下所有标准名称 .md 文件，将未在索引中的条目追加写入。
# 通过 session-start.sh 在每次会话启动时自动执行。
# skip_name: 跳过当前会话（wrapper 尚未退出，索引不应有当前条目）。
session_index_reconcile() {
  local dir="$1"
  local skip_name="$2"
  local added=0 complete=0 skeleton=0

  [ ! -d "$dir" ] && { echo "0 0 0"; return 0; }

  for f in "$dir"/[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]_*.md; do
    [ -f "$f" ] || continue
    local name=$(basename "$f" .md)
    local date="${name:0:10}"
    local time="${name:11:6}"
    time=$(echo "$time" | grep -oE '^[0-9]+' | head -1)
    [ -z "$time" ] && time="0000"

    # 跳过当前会话
    [ "$name" = "$skip_name" ] && continue

    # 处理标准 YYYY-MM-DD_HHMM 或 YYYY-MM-DD_HHMMSS 格式
    echo "$time" | grep -qE '^[0-9]{4,6}$' || continue

    local found
    found=$(session_index_find "$dir" "$date" "$time")
    [ "$found" != "unknown" ] && continue

    local status="complete"
    grep -q "（待填充）" "$f" 2>/dev/null && status="skeleton"
    session_index_append "$dir" "$date" "$time" "$status"
    added=$((added + 1))
    [ "$status" = "complete" ] && complete=$((complete + 1)) || skeleton=$((skeleton + 1))
  done

  echo "$added $complete $skeleton"
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
