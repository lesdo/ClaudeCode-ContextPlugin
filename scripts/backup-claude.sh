#!/bin/bash
# Claude Code 用户配置备份（全量 + 黑名单 + 新条目检测 + 过期清理）
# 用法:
#   bash backup-claude.sh [变更说明]    # 备份 + 自动清理过期
#   bash backup-claude.sh --clean        # 仅清理过期备份
#   bash backup-claude.sh --dry-run      # 预览（不执行）

CLAUDE_PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
source "${CLAUDE_PLUGIN_ROOT}/hooks/lib/_common.sh"

IGNORE_FILE="$HOME/.claude/.backup-ignore"
DATE_TAG=$(date +%Y%m%d_%H%M)
TMP_DIR="$BACKUP_DIR/$DATE_TAG"
TMP_DIR_UNIX="$BACKUP_DIR_UNIX/$DATE_TAG"
CHANGE_NOTE="${1:-<填写变更说明>}"
RECREATE_DIR=false

SET_DIR_PATH=""

# === --set-dir 标记（需在 --recreate-dir / CHANGE_NOTE 之前处理）===
if [ "$1" = "--set-dir" ]; then
  if [ -z "$2" ]; then
    echo "错误: --set-dir 需要指定路径"
    echo "用法: bash ~/.claude/tools/backup-claude.sh --set-dir <路径> [变更说明]"
    exit 1
  fi
  SET_DIR_PATH="$2"
  shift 2
  CHANGE_NOTE="${1:-<填写变更说明>}"

  # 写入配置文件
  if grep -q "^BACKUP_DIR=" "$CONFIG_FILE" 2>/dev/null; then
    sed -i "s|^BACKUP_DIR=.*|BACKUP_DIR=\"$SET_DIR_PATH\"|" "$CONFIG_FILE"
  else
    echo "BACKUP_DIR=\"$SET_DIR_PATH\"" >> "$CONFIG_FILE"
  fi
  echo "已更新备份路径: $SET_DIR_PATH"

  # 重新加载配置以获取新的 BACKUP_DIR
  source "${CLAUDE_PLUGIN_ROOT}/hooks/lib/_common.sh"

  # 目录不存在则创建
  if [ ! -d "$BACKUP_DIR" ]; then
    mkdir -p "$BACKUP_DIR"
    echo "已创建备份目录: $BACKUP_DIR"
  fi
fi

# === --recreate-dir 标记（需在 CHANGE_NOTE 之前处理）===
if [ "$1" = "--recreate-dir" ]; then
  RECREATE_DIR=true
  shift
  CHANGE_NOTE="${1:-<填写变更说明>}"
fi

# === 备份目录存在性检查 ===
# 退出码: 0=正常, 2=需要用户决策
check_backup_dir() {
  if [ ! -d "$BACKUP_DIR" ]; then
    if [ "$RECREATE_DIR" = "true" ]; then
      echo "重建备份目录: $BACKUP_DIR"
      mkdir -p "$BACKUP_DIR"
      return 0
    fi

    echo "=== NEED_USER_DECISION ==="
    echo "备份目录不存在: $BACKUP_DIR"
    echo ""
    echo "请选择处理方式:"
    echo "  [1] 指定新备份路径"
    echo "  [2] 创建原路径 ($BACKUP_DIR)"
    echo "  [3] 取消本次备份"
    echo "=== END_OPTIONS ==="
    exit 2
  fi
}

# === 过期清理函数 ===
cleanup_old_backups() {
  local all_backups=($(ls -t "$BACKUP_DIR_UNIX"/$BACKUP_PATTERN 2>/dev/null))

  if [ ${#all_backups[@]} -le $KEEP_COUNT ]; then
    return 0
  fi

  local to_delete=("${all_backups[@]:$KEEP_COUNT}")
  local keep=("${all_backups[@]:0:$KEEP_COUNT}")

  # 安全底线：清理后至少保留 MIN_KEEP 个
  if [ ${#keep[@]} -lt $MIN_KEEP ]; then
    echo "(清理跳过：不足以保留 $MIN_KEEP 个备份)"
    return 0
  fi

  echo ""
  echo "--- 清理过期备份（保留最近 $KEEP_COUNT 个）---"
  for f in "${to_delete[@]}"; do
    echo "  删除: $(basename "$f")"
    rm -f "$f"
  done
  echo "  完成: 已删除 ${#to_delete[@]} 个，保留 ${#keep[@]} 个"
}

# === --clean 模式：仅清理 ===
if [ "$1" = "--clean" ]; then
  echo "=== 备份过期清理 ==="
  check_backup_dir
  echo "保留策略: 最近 $KEEP_COUNT 个 (安全底线: $MIN_KEEP 个)"
  cleanup_old_backups
  exit 0
fi

# === --dry-run 模式：预览不执行 ===
if [ "$1" = "--dry-run" ]; then
  echo "=== 备份预览（不执行） ==="
  echo "备份目录: $BACKUP_DIR"
  check_backup_dir
  ALL_BACKUPS=($(ls -t "$BACKUP_DIR_UNIX"/$BACKUP_PATTERN 2>/dev/null))
  echo "现有备份: ${#ALL_BACKUPS[@]} 个"
  if [ ${#ALL_BACKUPS[@]} -gt 0 ]; then
    echo "  最新: $(basename "${ALL_BACKUPS[0]}")"
  fi
  echo "保留策略: 最近 $KEEP_COUNT 个 (底线: $MIN_KEEP 个)"
  if [ ${#ALL_BACKUPS[@]} -gt $KEEP_COUNT ]; then
    TO_DEL=${#ALL_BACKUPS[@]}
    TO_DEL=$((TO_DEL - KEEP_COUNT))
    echo "将删除: $TO_DEL 个"
    for ((i=KEEP_COUNT; i<${#ALL_BACKUPS[@]}; i++)); do
      echo "  → $(basename "${ALL_BACKUPS[$i]}") (将被清理)"
    done
  else
    echo "清理: 无需（未超过 $KEEP_COUNT 个）"
  fi
  exit 0
fi

# === 0. 目录检查 ===
check_backup_dir

# === 1. 全量备份 ~/.claude/（通过黑名单排除） ===
mkdir -p "$TMP_DIR"
tar -czf "$TMP_DIR_UNIX/backup.tar.gz" \
  --exclude-from "$IGNORE_FILE" \
  --exclude ".backup-ignore" \
  -C "$HOME" ".claude" 2>/dev/null

# 解压到临时目录（后续用于 diff 和打包）
tar -xzf "$TMP_DIR_UNIX/backup.tar.gz" -C "$TMP_DIR_UNIX/" 2>/dev/null
rm "$TMP_DIR/backup.tar.gz"

# === 2. 与上一次备份对比 ===
PREV_TGZ=$(ls -t "$BACKUP_DIR"/claude-backup-*.tar.gz 2>/dev/null | head -1)
# Windows Git Bash: tar 不认识 E:，转为 /e/ 格式
if [ -n "$PREV_TGZ" ]; then
  PREV_TGZ_SANE=$(echo "$PREV_TGZ" | sed 's|^\([A-Z]\):|/\1|' | tr '[:upper:]' '[:lower:]')
fi

DIFF_FILE="$TMP_DIR/.claude/changes.diff"
MANIFEST_FILE="$TMP_DIR/.claude/BACKUP_MANIFEST.txt"

# 生成本次备份清单（顶层条目）
{
  echo "=== 本次备份清单 ($DATE_TAG) ==="
  echo ""
  echo "=== 黑名单（未备份） ==="
  grep -v '^#' "$IGNORE_FILE" | grep -v '^$' | while read line; do echo "  $line"; done
  echo ""
  echo "=== 已备份条目 ==="
  ls -1 "$TMP_DIR/.claude/" | grep -v 'changes.diff' | grep -v 'BACKUP_MANIFEST.txt' | grep -v 'BACKUP_INFO.txt' | while read item; do
    if [ -d "$TMP_DIR/.claude/$item" ]; then
      echo "  $item/"
    else
      echo "  $item"
    fi
  done
} > "$MANIFEST_FILE"

if [ -n "$PREV_TGZ" ]; then
  PREV_DIR="/tmp/backup-prev-$$"
  rm -rf "$PREV_DIR"
  mkdir -p "$PREV_DIR"
  tar -xzf "$PREV_TGZ_SANE" -C "$PREV_DIR" 2>/dev/null
  PREV_CONTENT="$PREV_DIR/.claude"

  # 新条目检测：对比本次和上次的顶层条目
  echo "=== 差异报告：$(basename "$PREV_TGZ") → $DATE_TAG ===" > "$DIFF_FILE"
  echo "" >> "$DIFF_FILE"

  # 收集本次和上次的顶层条目
  NOW_ITEMS=$(ls -1 "$TMP_DIR/.claude/" 2>/dev/null | grep -v 'changes.diff' | grep -v 'BACKUP_MANIFEST.txt' | grep -v 'BACKUP_INFO.txt' | sort)
  PREV_ITEMS=$(ls -1 "$PREV_CONTENT/" 2>/dev/null | grep -v 'changes.diff' | grep -v 'BACKUP_MANIFEST.txt' | grep -v 'BACKUP_INFO.txt' | sort)

  NEW_ITEMS=$(comm -23 <(echo "$NOW_ITEMS") <(echo "$PREV_ITEMS"))
  REMOVED_ITEMS=$(comm -13 <(echo "$NOW_ITEMS") <(echo "$PREV_ITEMS"))

  if [ -n "$NEW_ITEMS" ]; then
    echo "⚠ 检测到新条目（已自动纳入备份）：" >> "$DIFF_FILE"
    echo "$NEW_ITEMS" | while read item; do echo "  + $item"; done >> "$DIFF_FILE"
    echo "  如需排除，编辑 ~/.claude/.backup-ignore" >> "$DIFF_FILE"
    echo "" >> "$DIFF_FILE"
  fi
  if [ -n "$REMOVED_ITEMS" ]; then
    echo "⚠ 以下条目已消失：" >> "$DIFF_FILE"
    echo "$REMOVED_ITEMS" | while read item; do echo "  - $item"; done >> "$DIFF_FILE"
    echo "" >> "$DIFF_FILE"
  fi

  # 逐文件 diff（只对文本文件）
  echo "=== 文件变更详情 ===" >> "$DIFF_FILE"
  echo "" >> "$DIFF_FILE"

  for ITEM in $NOW_ITEMS; do
    OLD_PATH="$PREV_CONTENT/$ITEM"
    NEW_PATH="$TMP_DIR/.claude/$ITEM"

    if [ -f "$OLD_PATH" ] && [ -f "$NEW_PATH" ]; then
      if ! diff -q "$OLD_PATH" "$NEW_PATH" > /dev/null 2>&1; then
        echo "--- $ITEM ---" >> "$DIFF_FILE"
        diff -u "$OLD_PATH" "$NEW_PATH" >> "$DIFF_FILE" 2>&1 || true
        echo "" >> "$DIFF_FILE"
      fi
    elif [ -d "$OLD_PATH" ] && [ -d "$NEW_PATH" ]; then
      if ! diff -rq "$OLD_PATH" "$NEW_PATH" > /dev/null 2>&1; then
        echo "--- $ITEM/ (目录有变化) ---" >> "$DIFF_FILE"
        diff -rq "$OLD_PATH" "$NEW_PATH" 2>/dev/null | head -20 >> "$DIFF_FILE"
        echo "... (仅列出文件名差异，详细内容请解压查看)" >> "$DIFF_FILE"
        echo "" >> "$DIFF_FILE"
      fi
    fi
  done

  rm -rf "$PREV_DIR"
  PREV_NAME=$(basename "$PREV_TGZ" .tar.gz)
else
  echo "=== 首次备份，无历史可对比 ===" > "$DIFF_FILE"
  PREV_NAME="(无)"
fi

# === 3. 自说明文件（解压即读） ===
INFO_FILE="$TMP_DIR/.claude/BACKUP_INFO.txt"
{
  echo "========================================"
  echo "  Claude Code 配置备份"
  echo "========================================"
  echo ""
  echo "备份时间: $DATE_TAG"
  echo "变更说明: $CHANGE_NOTE"
  echo "对比基准: $PREV_NAME"
  echo ""
  cat "$MANIFEST_FILE"
  echo ""
  echo "=== 查看变更 ==="
  echo ""
  echo "详细差异见同目录下的 changes.diff"
} > "$INFO_FILE"

# === 4. 检查黑名单覆盖情况 ===
UNTRACKED=""
while IFS= read -r item; do
  name=$(basename "$item")
  if ! grep -qF "$name" "$IGNORE_FILE" 2>/dev/null; then
    # 检查是否在备份中
    if [ ! -e "$TMP_DIR/.claude/$name" ]; then
      UNTRACKED="$UNTRACKED  $name"
    fi
  fi
done < <(ls -1d "$HOME/.claude/"* "$HOME/.claude/".* 2>/dev/null | grep -v '\.$' | grep -v '\.claude$')

# === 5. 打包 ===
FILE_COUNT=$(find "$TMP_DIR/.claude" -type f | wc -l)
cd "$TMP_DIR" && tar -czf "$BACKUP_DIR_UNIX/claude-backup-$DATE_TAG.tar.gz" ".claude" && cd "$BACKUP_DIR" && rm -rf "$TMP_DIR"

BACKUP_SIZE=$(ls -lh "$BACKUP_DIR/claude-backup-$DATE_TAG.tar.gz" | awk '{print $5}')

echo "Backup: $BACKUP_DIR/claude-backup-$DATE_TAG.tar.gz  ($BACKUP_SIZE, ${FILE_COUNT} 个文件)"
echo "Base:   $PREV_NAME"

# 更新备份状态快照（供退出时对比）+ 清除变更日志
snapshot_config "$HOME/.claude/.last-backup-state"
rm -f "$HOME/.claude/.backup-changes"

# 输出新条目警告
if [ -n "$NEW_ITEMS" ]; then
  echo ""
  echo "⚠ 检测到新条目（已自动纳入备份）："
  echo "$NEW_ITEMS" | while read item; do echo "  + $item"; done
  echo "  如需排除，编辑 ~/.claude/.backup-ignore"
fi

# 输出未追踪条目（不在黑名单中也未出现在备份中，可能是 tar 遗漏或权限问题）
if [ -n "$UNTRACKED" ]; then
  echo ""
  echo "⚠ 以下条目未被黑名单覆盖，但也未出现在备份中（请检查）："
  for item in $UNTRACKED; do echo "  ? $item"; done
fi

echo ""
echo "解压后可查看: BACKUP_INFO.txt / changes.diff / BACKUP_MANIFEST.txt"

# === 6. 过期清理 ===
cleanup_old_backups
