#!/bin/bash
# _orphan_setup.sh — 为遗孤扫描测试创建 mock 会话数据
# 用法: source 此文件后调用 setup_orphan_sessions TEST_DIR

setup_orphan_sessions() {
  local TEST_DIR="$1"
  local MCP="${2:-scripts/mcp-cli.sh}"
  local PLUGIN="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

  # 孤儿会话 (旧日期 + dead PID + 无事件 → 预期 suspect)
  bash "$MCP" "$TEST_DIR" session_create \
    '{"date":"2026-06-01","time_val":"100000","slug":"2026-06-01_100000","pid":999999}' \
    2>/dev/null >/dev/null
  bash "$MCP" "$TEST_DIR" session_create \
    '{"date":"2026-06-02","time_val":"110000","slug":"2026-06-02_110000","pid":999998}' \
    2>/dev/null >/dev/null

  # 平行会话 (alive PID + 有事件 → 预期 keep)
  bash "$MCP" "$TEST_DIR" session_create \
    '{"date":"2026-06-03","time_val":"120000","slug":"2026-06-03_120000","pid":'"$$"'}' \
    2>/dev/null >/dev/null

  # "当前" 会话最后创建，确保 created_at 最新，被 orphan_scan 排除
  bash "$MCP" "$TEST_DIR" session_create \
    '{"date":"2026-07-12","time_val":"120000","slug":"2026-07-12_120000","pid":'"$$"'}' \
    2>/dev/null >/dev/null

  # 用 Python 设 start_time + 给 parallel 加事件
  python3 - "$TEST_DIR" "$PLUGIN" << 'PYEOF'
import sys, os
td = sys.argv[1]
plugin = sys.argv[2]
sys.path.insert(0, os.path.join(plugin, 'mcp'))
from db_core import get_db, ensure_schema
ensure_schema(td)
with get_db(td) as conn:
    conn.execute("UPDATE sessions SET start_time='2026-06-01T10:00:00+00:00' WHERE slug='2026-06-01_100000'")
    conn.execute("UPDATE sessions SET start_time='2026-06-02T11:00:00+00:00' WHERE slug='2026-06-02_110000'")
    conn.execute("UPDATE sessions SET start_time='2026-06-03T12:00:00+00:00' WHERE slug='2026-06-03_120000'")
    row = conn.execute("SELECT id FROM sessions WHERE slug='2026-06-03_120000'").fetchone()
    if row:
        conn.execute("INSERT INTO events (session_id, timestamp, tool_name, tool_input_summary) VALUES (?,datetime('now'),'Read','test')", (row[0],))
PYEOF
}
