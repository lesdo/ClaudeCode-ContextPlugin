#!/usr/bin/env bash
# ============================================================
# track-commit.sh — PostToolUse hook
# 来源: Continuum (marylin/Continuum) → 适配: jq 优先, sed 兜底
# 触发: matcher "Bash(git commit*)"
# 写入: ~/.claude/sessions/active-changes.log
# 代价: 0 token
# ============================================================
set -euo pipefail

INPUT=$(cat)
[ -z "$INPUT" ] && exit 0

# ── JSON 提取: jq 优先, sed 兜底 ──
if JQ=$(command -v jq 2>/dev/null) && [ -x "$JQ" ]; then
  CWD=$("$JQ" -r '.cwd // empty' 2>/dev/null <<< "$INPUT")
else
  CWD=$(echo "$INPUT" | sed -n 's/.*"cwd":"\([^"]*\)".*/\1/p')
fi

[ -z "$CWD" ] && exit 0

SESSIONS_DIR="$HOME/.claude/sessions"
LOG="$SESSIONS_DIR/active-changes.log"
[ -f "$LOG" ] || exit 0

CWD="${CWD//\\//}"
NOW=$(date +%Y-%m-%dT%H:%M:%S%z)

# ── 获取最新 commit ──
COMMIT_INFO=$(git -C "$CWD" log -1 --format="%h %s" 2>/dev/null || true)
[ -z "$COMMIT_INFO" ] && exit 0

echo "$NOW COMMIT $COMMIT_INFO" >> "$LOG"

# ── 快照工作区状态 ──
while IFS= read -r line; do
  [ -n "$line" ] && echo "$NOW GITSTATUS $line" >> "$LOG"
done < <(git -C "$CWD" status --porcelain 2>/dev/null || true)
