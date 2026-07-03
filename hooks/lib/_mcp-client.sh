#!/bin/bash
# _mcp-client.sh — Hook 中调用 MCP 服务器的辅助函数
# source 此文件即可使用 mcp_call() 函数
#
# 要求: PLUGIN_DIR 环境变量（指向 Plugin 根目录）
#       CLAUDE_PROJECT_DIR 环境变量（指向当前项目）

MCP_CLI="${PLUGIN_DIR:-$CLAUDE_PLUGIN_ROOT}/scripts/mcp-cli.sh"

if [ ! -f "$MCP_CLI" ]; then
  # fallback: 从 _common.sh 已知的路径推导
  MCP_CLI="$(dirname "$(dirname "${BASH_SOURCE[0]:-$0}")")/scripts/mcp-cli.sh"
fi

# 项目目录
MCP_PROJECT="${CLAUDE_PROJECT_DIR:-${PROJECT_DIR:-$PWD}}"

# ── mcp_call ──────────────────────────────────────────
# 调用 MCP 服务器的指定函数
# 用法: result=$(mcp_call <command> [json_args])
# 返回: JSON 字符串（stdout）
# 超时: 10 秒
mcp_call() {
  local cmd="$1"
  local args="${2:-{}}"
  local timeout=10

  if [ ! -f "$MCP_CLI" ]; then
    echo "{\"error\":\"MCP CLI not found: $MCP_CLI\"}"
    return 1
  fi

  # 使用 timeout 命令（如果可用）
  if command -v timeout >/dev/null 2>&1; then
    timeout "$timeout" bash "$MCP_CLI" "$MCP_PROJECT" "$cmd" "$args" 2>/dev/null || {
      echo "{\"error\":\"MCP call timed out or failed: $cmd\"}"
      return 1
    }
  else
    bash "$MCP_CLI" "$MCP_PROJECT" "$cmd" "$args" 2>/dev/null || {
      echo "{\"error\":\"MCP call failed: $cmd\"}"
      return 1
    }
  fi
}

# ── mcp_call_silent ───────────────────────────────────
# 同上，但静默错误（返回空字符串而非错误 JSON）
mcp_call_silent() {
  local result
  result=$(mcp_call "$@" 2>/dev/null) || true
  if echo "$result" | grep -q '"error"'; then
    echo ""
  else
    echo "$result"
  fi
}

# ── mcp_json_get ──────────────────────────────────────
# 从 mcp_call 返回的 JSON 中提取字段
# 用法: value=$(mcp_json_get "$json" "key")
# 依赖 python3（简单可靠）
mcp_json_get() {
  local json="$1"
  local key="$2"
  echo "$json" | python3 -c "
import sys, json
try:
    data = json.load(sys.stdin)
    print(data.get('$key', ''))
except:
    print('')
" 2>/dev/null
}

# ── 预定义的便捷调用 ──────────────────────────────────

mcp_session_create() {
  local date="${1:-$(date +%Y-%m-%d)}"
  local time="${2:-$(date +%H%M%S)}"
  local pid="${3:-$$}"
  mcp_call session_create "{\"date\":\"$date\",\"time_val\":\"$time\",\"pid\":$pid}"
}

mcp_event_log() {
  local tool="$1"
  local summary="${2:-}"
  local file="${3:-}"
  mcp_call event_log "{\"tool_name\":\"$tool\",\"tool_input_summary\":\"$summary\",\"file_path\":\"$file\"}" 2>/dev/null || true
}

mcp_session_finalize() {
  local summary="${1:-}"
  local exit_code="${2:-0}"
  mcp_call session_finalize "{\"summary\":\"$summary\",\"exit_code\":$exit_code}"
}

mcp_stats() {
  mcp_call stats_overview
}

mcp_briefing() {
  mcp_call briefing_generate
}
