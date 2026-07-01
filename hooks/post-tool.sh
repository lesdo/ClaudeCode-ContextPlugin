#!/bin/bash
# PostToolUse hook — 合并: 取证日志(auto-log) + 配置守护(guard)
# 单次 stdin 解析，顺序执行，纯 bash，零外部依赖
# 测试: echo '{"tool_name":"Edit","tool_input":{"file_path":"'$HOME'/.claude/CLAUDE.md"}}' | bash ${CLAUDE_PLUGIN_ROOT}/hooks/post-tool.sh [项目目录]

CLAUDE_PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
source "${CLAUDE_PLUGIN_ROOT}/hooks/lib/_common.sh"
detect_project_dir "$1"

INPUT=$(cat 2>/dev/null)
[ -z "$INPUT" ] && exit 0

# ── 一次性 JSON 提取（纯 bash sed，零 python 开销）──
TOOL_NAME=$(echo "$INPUT" | sed -n 's/.*"tool_name":"\([^"]*\)".*/\1/p')
[ -z "$TOOL_NAME" ] && exit 0

FILE_PATH=$(echo "$INPUT" | sed -n 's/.*"file_path":"\([^"]*\)".*/\1/p')

SUMMARY=""
for key in file_path command description pattern url query skill subject taskId cron id; do
  SUMMARY=$(echo "$INPUT" | sed -n "s/.*\"$key\":\"\\([^\"]*\\)\".*/\\1/p" | head -1)
  [ -n "$SUMMARY" ] && break
done
[ -z "$SUMMARY" ] && SUMMARY="-"

# ============================================================
# Phase 1: 取证日志（原 auto-log.sh）— 全部工具调用
# ============================================================
SESSIONS_DIR="$PROJECT_DIR/.claude/context/sessions"
if [ -d "$SESSIONS_DIR" ]; then
  POINTER="$SESSIONS_DIR/.current-session"
  if [ -f "$POINTER" ]; then
    SESSION_LOG=$(sed 's/\.md$/.log/' "$POINTER")
  else
    SESSION_MD=$(ls -1t "$SESSIONS_DIR"/*.md 2>/dev/null | grep -E '/[0-9]{4}-[0-9]{2}-[0-9]{2}_[0-9]{4}\.md$' | head -1)
    if [ -n "$SESSION_MD" ]; then
      SESSION_LOG="${SESSION_MD%.md}.log"
    fi
  fi
  if [ -n "${SESSION_LOG:-}" ]; then
    TS=$(date +%H:%M:%S)
    echo "- $TS $TOOL_NAME $SUMMARY" >> "$SESSION_LOG"
  fi
fi

# ============================================================
# Phase 2: 配置守护（原 guard.sh）— 仅 Edit/Write
# ============================================================
{ [ "$TOOL_NAME" != "Edit" ] && [ "$TOOL_NAME" != "Write" ]; } && exit 0
[ -z "$FILE_PATH" ] && exit 0

# 检查 1: .claude/ 路径格式提醒
case "$FILE_PATH" in
  *"/.claude/"*)
    echo "⚠ 已编辑 .claude/ 下文件，确认文本输出已展示完整绝对路径。" >&2
    ;;
esac

# 检查 2: ~/.claude/ 变更追踪 + 备份提醒
case "$FILE_PATH" in
  "$HOME/.claude/"*) ;;
  *) exit 0 ;;
esac

case "$TOOL_NAME" in
  "Write") OP="新建" ;;
  "Edit")  OP="修改" ;;
  *)       OP="变更" ;;
esac

REL_PATH="${FILE_PATH#$HOME/.claude/}"

CHANGES_FILE="$HOME/.claude/.backup-changes"
touch "$CHANGES_FILE"
grep -qF "${OP} ${REL_PATH}" "$CHANGES_FILE" 2>/dev/null && exit 0
echo "${OP} ${REL_PATH}" >> "$CHANGES_FILE"

TOTAL=$(wc -l < "$CHANGES_FILE" | tr -d ' ')
[ "$TOTAL" -eq 1 ] && CHANGE_SUMMARY="${OP} ${REL_PATH}" || CHANGE_SUMMARY="${TOTAL} 个文件变更"

cat <<EOF

**备份提醒** — ~/.claude/ 变更：
${CHANGE_SUMMARY}

变更文件：
$(while IFS= read -r line; do echo "- ${line}"; done < "$CHANGES_FILE")

建议执行: \`bash ${CLAUDE_PLUGIN_ROOT}/scripts/backup-claude.sh "变更说明"\`

EOF

# 检查 3: CLAUDE.md 红线检查
case "$FILE_PATH" in
  *".claude/CLAUDE.md") ;;
  *) exit 0 ;;
esac

source "$HOME/.claude/rules.redline" 2>/dev/null
VIOLATIONS=""

LINES=$(wc -l < "$FILE_PATH" 2>/dev/null)
MAX="${CLAUDE_MAX_LINES:-50}"
if [ "$LINES" -gt "$MAX" ] 2>/dev/null; then
  VIOLATIONS="${VIOLATIONS}  • CLAUDE.md 行数: $LINES > $MAX（上限）
"
fi

if [ -n "${CLAUDE_FORBID_CMD:-}" ]; then
  FORBID_HITS=$(grep -nE "$CLAUDE_FORBID_CMD" "$FILE_PATH" 2>/dev/null)
  if [ -n "$FORBID_HITS" ]; then
    VIOLATIONS="${VIOLATIONS}  • CLAUDE.md 含禁止命令:
"
    while IFS= read -r hit; do
      VIOLATIONS="${VIOLATIONS}    行 $hit
"
    done <<< "$FORBID_HITS"
  fi
fi

[ -z "$VIOLATIONS" ] && exit 0

cat <<EOF

╔══════════════════════════════════════════╗
║ ⚠ 架构底线违规（rules.redline）        ║
╠══════════════════════════════════════════╣
║ 刚刚的编辑触发了以下红线：              ║
$(echo -e "$VIOLATIONS")
║                                          ║
║ 请立即修复，否则 check-health 将失败。  ║
╚══════════════════════════════════════════╝

EOF
