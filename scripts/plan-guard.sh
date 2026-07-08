#!/bin/bash
# plan-guard.sh — 计划停滞检测（v4: 简化为单一 >7天检测）
# 只做机械的日期比较，不做智能分级判断。
#
# 用法: bash plan-guard.sh <project_dir>
# 退出码: 0=PASS, 非零不影响 stop 管线（fail-open）

set -euo pipefail

CLAUDE_PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
source "${CLAUDE_PLUGIN_ROOT}/hooks/lib/_common.sh"
detect_project_dir "${1:-}"

# ── 路径 ──
DB_PATH="$PROJECT_DIR/.claude/context/memory.db"
GAP_FILE="$PROJECT_DIR/.claude/context/plan-gap.txt"

# ── 门控 ──
if [ ! -f "$DB_PATH" ] || ! command -v python3 >/dev/null 2>&1; then
  trash_put "$GAP_FILE" 2>/dev/null || true
  exit 0
fi

# ── >7 天检测 ──
STALE_OUTPUT=$(python3 -c "
import sqlite3, json, os
from datetime import datetime, timezone, timedelta

try:
    conn = sqlite3.connect('$DB_PATH')
    conn.row_factory = sqlite3.Row
except Exception:
    exit(0)

plan_slug = 'default'
idx_path = os.path.join('$PROJECT_DIR', '.planning', 'index.json')
if os.path.exists(idx_path):
    try:
        with open(idx_path, encoding='utf-8') as f:
            idx = json.load(f)
        active = idx.get('active', '')
        if active and idx.get('plans', {}).get(active, {}).get('status') in ('active', 'paused'):
            plan_slug = active
    except Exception:
        pass

now = datetime.now(timezone.utc)
cutoff = (now - timedelta(days=7)).isoformat()

rows = conn.execute(
    \"SELECT task_id, subject, status FROM task_states\"
    \" WHERE plan_slug=? AND status IN ('pending', 'in_progress') AND updated_at < ?\"
    \" ORDER BY updated_at ASC\", (plan_slug, cutoff)
).fetchall()
conn.close()

for r in rows:
    tid = r['task_id'][:12]
    st = r['status']
    subj = (r['subject'] or 'Untitled')[:80]
    print(f'{tid}|{st}|{subj}')
" 2>/dev/null || true)

# ── 写 plan-gap.txt ──
STALE_COUNT=0
if [ -n "$STALE_OUTPUT" ]; then
  STALE_COUNT=$(echo "$STALE_OUTPUT" | wc -l | tr -d ' ')
fi

if [ "$STALE_COUNT" -eq 0 ]; then
  trash_put "$GAP_FILE" 2>/dev/null || true
  exit 0
fi

mkdir -p "$(dirname "$GAP_FILE")"
{
  echo "# 📋 停滞任务提醒"
  echo ""
  echo "${STALE_COUNT} 个任务超过 7 天未更新:"
  echo ""
  echo "$STALE_OUTPUT" | while IFS='|' read -r tid status subj; do
    [ -z "$tid" ] && continue
    echo "- [${status}] ${subj}  (id: ${tid})"
  done
  echo ""
  echo "处理: 运行 /verify-tasks 审计或 /reflect 归档"
} > "$GAP_FILE"

exit 0
