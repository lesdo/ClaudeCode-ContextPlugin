#!/bin/bash
# 退出 — 终止 Claude 进程
set -euo pipefail
# 前提: AI 应先运行 exit-check.sh 确认会话完整性
# 用法:
#   bash claude-exit.sh [项目目录] [PID]
#   PID 传入 → 杀指定 PID；未传 → 杀全部 _claude.exe
# 测试: bash claude-exit.sh [项目目录] [PID]

CLAUDE_PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
source "${CLAUDE_PLUGIN_ROOT}/hooks/lib/_common.sh"
detect_project_dir "$1"

MAIN_PID="${2:-}"

echo "STATE: exiting"
echo "PROJECT: ${PROJECT_DIR}"

if [ -n "$MAIN_PID" ]; then
  echo "PID: ${MAIN_PID}"
  taskkill /PID "$MAIN_PID" /F >/dev/null 2>&1 || true
else
  taskkill /F /IM _claude.exe >/dev/null 2>&1 || taskkill /F /IM claude.exe >/dev/null 2>&1 || true
fi
