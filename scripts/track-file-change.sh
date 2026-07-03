#!/usr/bin/env bash
# ============================================================
# track-file-change.sh — PostToolUse hook
# 来源: Continuum (marylin/Continuum) → 适配: jq 优先, sed 兜底
# 触发: matcher "Edit|Write"
# 写入: 项目/.claude/context/active-changes.log（供 auto-checkpoint 读取）
# 代价: 0 token（command hook, 不消耗 LLM 上下文）
# ============================================================
set -euo pipefail

INPUT=$(cat)
[ -z "$INPUT" ] && exit 0

# ── JSON 提取: jq 优先, sed 兜底 ──
if JQ=$(command -v jq 2>/dev/null) && [ -x "$JQ" ]; then
  TOOL_NAME=$("$JQ" -r '.tool_name // empty' 2>/dev/null <<< "$INPUT")
  FILE_PATH=$("$JQ" -r '.tool_input.file_path // empty' 2>/dev/null <<< "$INPUT")
  CWD=$("$JQ" -r '.cwd // empty' 2>/dev/null <<< "$INPUT")
  SID=$("$JQ" -r '.session_id // empty' 2>/dev/null <<< "$INPUT")
else
  TOOL_NAME=$(echo "$INPUT" | sed -n 's/.*"tool_name":"\([^"]*\)".*/\1/p')
  FILE_PATH=$(echo "$INPUT" | sed -n 's/.*"file_path":"\([^"]*\)".*/\1/p')
  CWD=$(echo "$INPUT" | sed -n 's/.*"cwd":"\([^"]*\)".*/\1/p')
  SID=$(echo "$INPUT" | sed -n 's/.*"session_id":"\([^"]*\)".*/\1/p')
fi

[ -z "$TOOL_NAME" ] || [ -z "$FILE_PATH" ] || [ -z "$CWD" ] && exit 0

# ── 目录 + 日志路径（项目内，不再散落 ~/.claude/）──
CONTEXT_DIR="$CWD/.claude/context"
LOG="$CONTEXT_DIR/active-changes.log"
mkdir -p "$CONTEXT_DIR"

# ── 路径规范化 ──
CWD="${CWD//\\//}"
FILE_PATH="${FILE_PATH//\\//}"
NOW=$(date +%Y-%m-%dT%H:%M:%S%z)
NOW_EPOCH=$(date +%s)

# ── 过期日志归档（15 分钟无活动 → 上一会话可能崩溃，保留证据）──
STALE_THRESHOLD=900
if [ -f "$LOG" ]; then
  LOG_MTIME=$(stat -c %Y "$LOG" 2>/dev/null || echo 0)
  LOG_AGE=$(( NOW_EPOCH - LOG_MTIME ))
  if [ "$LOG_AGE" -ge "$STALE_THRESHOLD" ]; then
    OLD_SID=$(head -1 "$LOG" 2>/dev/null | sed -n 's/.*sid=\([^ ]*\).*/\1/p')
    [ -z "$OLD_SID" ] && OLD_SID="unknown"
    mv "$LOG" "$SESSIONS_DIR/active-changes-${OLD_SID}.log" 2>/dev/null || true
  fi
fi

# ── 新会话写 header ──
if [ ! -f "$LOG" ]; then
  echo "# SESSION cwd=$CWD sid=${SID:-unknown} started=$NOW" > "$LOG"
fi

# ── 相对路径 ──
REL_PATH="${FILE_PATH#$CWD/}"
if [ "$REL_PATH" = "$FILE_PATH" ]; then
  REL_PATH=$(realpath --relative-to="$CWD" "$FILE_PATH" 2>/dev/null || echo "$FILE_PATH")
fi

# ── 追加变更记录 ──
echo "$NOW $TOOL_NAME $REL_PATH" >> "$LOG"
