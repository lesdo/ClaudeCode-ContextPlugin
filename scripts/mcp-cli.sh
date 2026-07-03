#!/bin/bash
# mcp-cli.sh — Python MCP 服务器 CLI 前端
# 供 Bash hook 脚本调用，处理路径转换和 JSON 参数
# 用法: mcp-cli.sh <project_dir> <command> [json_args]
#
# 示例:
#   mcp-cli.sh "$PROJECT_DIR" session_create '{"date":"2026-07-03","time_val":"170000"}'
#   mcp-cli.sh "$PROJECT_DIR" stats_overview
#   mcp-cli.sh "$PROJECT_DIR" memory_search '{"query":"FastAPI"}'

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
MCP_DIR="$(dirname "$SCRIPT_DIR")/mcp"
SERVER="$MCP_DIR/server.py"

PROJECT_DIR="${1:-$PWD}"
COMMAND="${2:-}"
if [ -n "${3:-}" ]; then
  ARGS="$3"
else
  ARGS="{}"
fi

if [ -z "$COMMAND" ]; then
  echo '{"error":"Usage: mcp-cli.sh <project_dir> <command> [args_json]"}'
  exit 1
fi

# 调用 Python（强制 UTF-8 输出，避免 Windows GBK 编码错误）
export PYTHONIOENCODING=utf-8
exec python3 "$SERVER" "$PROJECT_DIR" "$COMMAND" "$ARGS"
