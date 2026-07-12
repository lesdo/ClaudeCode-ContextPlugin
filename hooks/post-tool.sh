#!/bin/bash
# PostToolUse hook — 合并: 取证日志(auto-log) + 配置守护(guard)
# v4.5: JSON 解析改为 python3 脚本（_extract_tool_event.py）
set -uo pipefail  # fail-open: errors logged, always exit 0

CLAUDE_PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
source "${CLAUDE_PLUGIN_ROOT}/hooks/lib/_common.sh"
detect_project_dir "${1:-}"

INPUT=$(cat 2>/dev/null)
[ -z "$INPUT" ] && exit 0

# ── v4.5: python3 一次性 JSON 提取 ──
EXTRACT_SCRIPT="${CLAUDE_PLUGIN_ROOT}/scripts/_extract_tool_event.py"
PYTHON_EXTRACT=$(python3 "$EXTRACT_SCRIPT" 2>/dev/null <<< "$INPUT" || true)

# 解析提取值
TOOL_NAME=""; FILE_PATH=""; SUMMARY=""; EXIT_CODE=""; STDERR_SUMMARY=""
while IFS='=' read -r key val; do
  case "$key" in
    TOOL_NAME) TOOL_NAME="$val" ;;
    FILE_PATH) FILE_PATH="$val" ;;
    SUMMARY) SUMMARY="$val" ;;
    EXIT_CODE) EXIT_CODE="$val" ;;
    STDERR_SUMMARY) STDERR_SUMMARY="$val" ;;
  esac
done <<< "$PYTHON_EXTRACT"

[ -z "$TOOL_NAME" ] && exit 0

# ============================================================
# Phase 1: 事件记录 — SQLite event_log
# ============================================================
MCP_CLI="${CLAUDE_PLUGIN_ROOT}/scripts/mcp-cli.sh"

MCP_HEALTH=$(mcp_health_check "$PROJECT_DIR" "$MCP_CLI")
if [ "$MCP_HEALTH" = "ok" ]; then
  EVENT_JSON="{\"tool_name\":\"$TOOL_NAME\",\"tool_input_summary\":\"$SUMMARY\",\"file_path\":\"${FILE_PATH:-}\""
  [ -n "$EXIT_CODE" ] && EVENT_JSON="$EVENT_JSON,\"exit_code\":$EXIT_CODE"
  [ -n "$STDERR_SUMMARY" ] && EVENT_JSON="$EVENT_JSON,\"stderr_summary\":\"$STDERR_SUMMARY\""
  EVENT_JSON="$EVENT_JSON}"
  bash "$MCP_CLI" "$PROJECT_DIR" event_log "$EVENT_JSON" 2>/dev/null || echo "post-tool: event_log 失败 (tool=$TOOL_NAME)" >&2

  # ax10 reversal: new event → session is alive → clear suspect marker
  bash "$MCP_CLI" "$PROJECT_DIR" session_clear_suspect 2>/dev/null || true
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

建议备份: 下次会话中说"建议备份"即可自动触发

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
