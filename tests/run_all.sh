#!/bin/bash
# run_all.sh — 测试入口，按顺序执行所有测试，汇总结果
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PLUGIN="$(dirname "$SCRIPT_DIR")"

TOTAL_PASS=0; TOTAL_FAIL=0
TESTS=(
  "lint_hooks.sh:L1 语法检查"
  "validate_hooks_json.sh:L1 hooks.json"
  "test_common.sh:L2 _common.sh"
  "test_post_tool.sh:L2 post-tool"
  "test_e2e.sh:L2 E2E 全流程"
)

echo "╔════════════════════════════════════╗"
echo "║  Plugin v3.0 — 测试套件          ║"
echo "╠════════════════════════════════════╣"
printf "║  %-32s ║\n" "L1: 语法 + Schema | L2: 单元 + E2E"
echo "╚════════════════════════════════════╝"
echo ""

ALL_PASSED=true

for entry in "${TESTS[@]}"; do
  IFS=':' read -r script label <<< "$entry"
  echo "────────────────────────────────────"
  echo "  $label ($script)"
  echo "────────────────────────────────────"

  if bash "$SCRIPT_DIR/$script" 2>&1; then
    echo "  >> PASSED"
  else
    echo "  >> FAILED (exit=$?)"
    ALL_PASSED=false
  fi
  echo ""
done

echo "════════════════════════════════════"
if $ALL_PASSED; then
  echo "  功能测试: 全部通过 ✓"
else
  echo "  功能测试: 存在失败 ✗"
fi
echo "════════════════════════════════════"

# ── 架构审计 (独立, 不影响 exit code) ──
echo ""
echo "────────────────────────────────────"
echo "  架构审计 (audit-plugin.sh)"
echo "────────────────────────────────────"
bash "$(dirname "$SCRIPT_DIR")/scripts/audit-plugin.sh" 2>&1 || true

$ALL_PASSED
