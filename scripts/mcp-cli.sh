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

# 参数
PROJECT_DIR="${1:-$PWD}"
COMMAND="${2:-}"
ARGS="${3:-{}}"

if [ -z "$COMMAND" ]; then
  echo '{"error":"Usage: mcp-cli.sh <project_dir> <command> [args_json]"}'
  exit 1
fi

# Windows 路径转换: E:/... → /e/...
# Python 的 os.path 可以处理 E:/ 格式，但 MSYS2 的 python 可能不行
PROJECT_DIR_WIN="$(echo "$PROJECT_DIR" | sed 's|^/\([a-zA-Z]\)/|\1:/|')"

# 调用 Python CLI
exec python3 "$MCP_DIR/server.py" "$PROJECT_DIR" "$COMMAND" "$ARGS"
