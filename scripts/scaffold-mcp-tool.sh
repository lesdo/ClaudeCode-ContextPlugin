#!/bin/bash
# scaffold-mcp-tool.sh — MCP Python 工具模块脚手架
# 用法: bash scaffold-mcp-tool.sh <module_name>
#   bash scaffold-mcp-tool.sh verify_dedup
#   bash scaffold-mcp-tool.sh task_health
# 生成: mcp/_verify_dedup.py（标准模板）
set -euo pipefail

CLAUDE_PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
source "${CLAUDE_PLUGIN_ROOT}/hooks/lib/_common.sh"

NAME="${1:-}"

if [ -z "$NAME" ]; then
  echo "用法: scaffold-mcp-tool.sh <module_name>" >&2
  echo "  bash scaffold-mcp-tool.sh verify_dedup    → mcp/_verify_dedup.py" >&2
  echo "  bash scaffold-mcp-tool.sh task_health     → mcp/_task_health.py" >&2
  exit 1
fi

# 规范化名称: 下划线前缀 + 小写 + 下划线分隔
CLEAN=$(echo "$NAME" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9]/_/g' | sed 's/__*/_/g' | sed 's/^_//;s/_$//')
MODULE="_${CLEAN}.py"
TARGET="${CLAUDE_PLUGIN_ROOT}/mcp/${MODULE}"

if [ -f "$TARGET" ]; then
  echo "❌ 已存在: $TARGET" >&2
  exit 1
fi

cat > "$TARGET" << EOF
#!/usr/bin/env python3
"""${CLEAN} — [简短描述职责]"""
from typing import Optional
from db_core import get_db, now_iso


def ${CLEAN}(project_dir: Optional[str] = None) -> dict:
    """[函数描述]
    Returns: dict with status and data.
    """
    with get_db(project_dir) as conn:
        # TODO: 实现逻辑
        pass

    return {"ok": True}
EOF

echo "✅ $TARGET"
echo ""
echo "下一步:"
echo "  1. 编辑 $TARGET 实现逻辑"
echo "  2. 在 mcp/server.py TOOLS 字典注册"
echo "  3. 在 cli_main handlers 和 mcp_main handlers 添加"
echo "  4. 创建 tests/test_${CLEAN}.py"
echo "  5. 运行: PYTHONIOENCODING=utf-8 python3 -m pytest tests/test_${CLEAN}.py"
exit 0
