#!/bin/bash
# session-archive.sh — 会话按月归档
# 将超过阈值的 .md + .log 会话文件移入 archive/YYYY-MM/
# 用法: bash ~/.claude/tools/session-archive.sh <sessions_dir> [days=30]

SESSIONS_DIR="${1:-}"
ARCHIVE_DAYS="${2:-30}"

if [ -z "$SESSIONS_DIR" ] || [ ! -d "$SESSIONS_DIR" ]; then
  echo "用法: session-archive.sh <sessions_dir> [days]"
  exit 1
fi

ARCHIVE_DIR="$SESSIONS_DIR/archive"

# 归档阈值时间戳（N 天前）
CUTOFF_EPOCH=$(date -d "$ARCHIVE_DAYS days ago" +%s 2>/dev/null)
if [ -z "$CUTOFF_EPOCH" ] || [ "$CUTOFF_EPOCH" -le 0 ] 2>/dev/null; then
  # date -d 不可用时跳过（如非 GNU date）
  exit 0
fi

archived=0

# 遍历所有日期前缀会话文件（含旧格式 slug/中文名）
for session_md in "$SESSIONS_DIR"/[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]_*.md; do
  [ -f "$session_md" ] || continue

  name=$(basename "$session_md" .md)
  date_part="${name:0:10}"   # YYYY-MM-DD
  year_month="${date_part:0:7}"  # YYYY-MM

  # 用文件名中的日期计算文件年龄
  file_epoch=$(date -d "$date_part" +%s 2>/dev/null)
  [ -z "$file_epoch" ] && continue

  if [ "$file_epoch" -lt "$CUTOFF_EPOCH" ]; then
    mkdir -p "$ARCHIVE_DIR/$year_month"
    mv "$session_md" "$ARCHIVE_DIR/$year_month/" 2>/dev/null
    session_log="${session_md%.md}.log"
    [ -f "$session_log" ] && mv "$session_log" "$ARCHIVE_DIR/$year_month/" 2>/dev/null
    archived=$((archived + 1))
  fi
done

[ "$archived" -gt 0 ] && echo "  [归档] ${archived} 个会话移入 archive/（>${ARCHIVE_DAYS}天前）"
exit 0
