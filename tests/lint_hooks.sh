#!/bin/bash
# lint_hooks.sh — L1: 语法 + 最佳实践检查
# 检查所有 .sh 脚本的 bash 语法和关键模式
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PLUGIN="$(dirname "$SCRIPT_DIR")"
source "$SCRIPT_DIR/assert.sh"

echo "=== Lint: Shell 脚本 ==="

# 收集所有 .sh 文件
SCRIPTS=$(find "$PLUGIN/hooks" "$PLUGIN/scripts" "$PLUGIN/tests" -name "*.sh" -type f 2>/dev/null | sort)

for s in $SCRIPTS; do
  rel="${s#$PLUGIN/}"

  # 检查 1: bash 语法
  if bash -n "$s" 2>/dev/null; then
    pass "$rel: 语法"
  else
    fail "$rel: 语法错误"
    continue
  fi

  # 区分库文件(lib/)和可执行脚本
  IS_LIB=false
  case "$rel" in
    hooks/lib/*|tests/assert.sh) IS_LIB=true ;;
  esac

  # 检查 2: shebang（仅可执行脚本需要）
  if $IS_LIB; then
    pass "$rel: lib (跳过 shebang)"
  elif head -1 "$s" | grep -qE '^#!.*(bash|sh)'; then
    pass "$rel: shebang"
  else
    fail "$rel: 缺 shebang"
  fi

  # 检查 3: set -euo pipefail（库文件不需要独立声明）
  if $IS_LIB; then
    pass "$rel: lib (跳过 pipefail)"
  elif grep -q "set -euo pipefail" "$s"; then
    pass "$rel: pipefail"
  else
    fail "$rel: 缺 set -euo pipefail"
  fi
done

finish
