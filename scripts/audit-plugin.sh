#!/bin/bash
# audit-plugin.sh — Plugin 架构自审计工具
# 用法: bash scripts/audit-plugin.sh [--json]
# 输出: 结构化审计报告 (文本/JSON)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PLUGIN="$(dirname "$SCRIPT_DIR")"
OUTPUT_MODE="${1:-text}"

# ── 工具函数 ──
hr() { printf "\n── %s ──\n" "$1"; }
kv() { printf "  %-30s %s\n" "$1:" "$2"; }
warn() { echo "  ⚠ $1"; }
good() { echo "  ✓ $1"; }
bad() { echo "  ✗ $1"; }

# ── 数据收集 ──
HOOK_FILES=$(find "$PLUGIN/hooks" -name "*.sh" -type f 2>/dev/null | sort)
SCRIPT_FILES=$(find "$PLUGIN/scripts" -name "*.sh" -type f 2>/dev/null | sort)
PY_FILES=$(find "$PLUGIN/mcp" -name "*.py" -type f 2>/dev/null | sort)
SKILL_FILES=$(find "$PLUGIN/skills" -name "SKILL.md" -type f 2>/dev/null | sort)
ALL_SHELL="$HOOK_FILES $SCRIPT_FILES"

echo "╔══════════════════════════════════════════╗"
echo "║  Plugin v3.0 — 架构审计报告            ║"
echo "╠══════════════════════════════════════════╣"
printf "║  %-38s ║\n" "$(date +%Y-%m-%dT%H:%M:%S)"
echo "╚══════════════════════════════════════════╝"

# ═══════════════════════════════════════════
# 1. 文件清单
# ═══════════════════════════════════════════
hr "1. 文件清单"

HOOK_COUNT=$(echo "$HOOK_FILES" | grep -c "." 2>/dev/null || echo 0)
SCRIPT_COUNT=$(echo "$SCRIPT_FILES" | grep -c "." 2>/dev/null || echo 0)
PY_COUNT=$(echo "$PY_FILES" | grep -c "." 2>/dev/null || echo 0)
SKILL_COUNT=$(echo "$SKILL_FILES" | grep -c "." 2>/dev/null || echo 0)

kv "Hook 脚本" "$HOOK_COUNT"
kv "独立脚本" "$SCRIPT_COUNT"
kv "Python 模块" "$PY_COUNT"
kv "Skill 定义" "$SKILL_COUNT"

# 代码量
SHELL_LINES=$(wc -l $ALL_SHELL 2>/dev/null | tail -1 | awk '{print $1}')
PY_LINES=$(wc -l $PY_FILES 2>/dev/null | tail -1 | awk '{print $1}')
kv "Shell 总行数" "$SHELL_LINES"
kv "Python 总行数" "$PY_LINES"

# ═══════════════════════════════════════════
# 2. 代码复杂度
# ═══════════════════════════════════════════
hr "2. 复杂度热点 (>150行)"

for f in $ALL_SHELL $PY_FILES; do
  [ ! -f "$f" ] && continue
  lines=$(wc -l < "$f" 2>/dev/null)
  if [ "$lines" -gt 150 ] 2>/dev/null; then
    rel="${f#$PLUGIN/}"
    warn "$rel ($lines 行)"
  fi
done

# 函数统计
hr "2b. 函数定义"
for f in $ALL_SHELL; do
  [ ! -f "$f" ] && continue
  funcs=$(grep -cE '^[a-zA-Z_][a-zA-Z0-9_]*\(\)' "$f" 2>/dev/null || echo 0)
  if [ "$funcs" -gt 0 ] 2>/dev/null; then
    rel="${f#$PLUGIN/}"
    kv "$rel" "${funcs} 函数"
  fi
done

# ═══════════════════════════════════════════
# 3. 依赖分析
# ═══════════════════════════════════════════
hr "3. 内部依赖 (source)"

for f in $ALL_SHELL; do
  [ ! -f "$f" ] && continue
  # 跳过自身
  echo "$f" | grep -q "audit-plugin" && continue
  deps=$(grep -oE 'source "[^"]*"' "$f" 2>/dev/null | sed 's/source "//;s/"//' || true)
  if [ -n "$deps" ]; then
    rel="${f#$PLUGIN/}"
    echo "  $rel"
    echo "$deps" | while read -r d; do
      echo "    → $d"
    done
  fi
done

# ═══════════════════════════════════════════
# 4. 外部脐带 — 最关键
# ═══════════════════════════════════════════
hr "4. 外部引用 (~/.claude/ 或 \$HOME)"

EXT_REFS=$(grep -Hon '\$HOME/\.claude\|~/.claude\|$HOME/Claudecode' $ALL_SHELL 2>/dev/null || true)
if [ -n "$EXT_REFS" ]; then
  echo "$EXT_REFS" | while read -r line; do
    file="${line%%:*}"
    rel="${file#$PLUGIN/}"
    ref="${line#*:}"
    ref="$(echo "$ref" | sed 's/^[[:space:]]*//')"
    echo "  $rel"
    echo "    $ref"
  done

  # 分类统计
  echo ""
  echo "  分类:"
  DESIGNED=$(echo "$EXT_REFS" | grep -cE 'profile/(user|rules)\.md|rules\.redline|\.backup-config' 2>/dev/null) || DESIGNED=0
  DATA=$(echo "$EXT_REFS" | grep -cE 'sessions/|\.backup-changes|\.last-backup' 2>/dev/null) || DATA=0
  BACKUP=$(echo "$EXT_REFS" | grep -cE 'ClaudecodeBackup|backup-claude|BACKUP_DIR' 2>/dev/null) || BACKUP=0
  echo "    有意设计 (profile/红线/备份配置): $DESIGNED"
  echo "    数据文件 (变更追踪/检查点):      $DATA"
  echo "    备份目录:                         $BACKUP"
fi

# ═══════════════════════════════════════════
# 5. Python 依赖
# ═══════════════════════════════════════════
hr "5. Python 依赖"

echo "  requirements.txt:"
if [ -f "$PLUGIN/mcp/requirements.txt" ]; then
  cat "$PLUGIN/mcp/requirements.txt" | while read -r pkg; do
    echo "    pip: $pkg"
  done
fi

echo ""
echo "  import 依赖 (非标准库):"
STDLIB="sys|os|json|time|hashlib|uuid|datetime|contextlib|typing|collections|re|math|struct|tempfile|random|asyncio|sqlite3|subprocess|argparse|abc|base64"
INTERNAL="db_core|db_ops|vectors"
IMPORTS=$(grep -hE "^import|^from" $PY_FILES 2>/dev/null | grep -vE "$STDLIB|$INTERNAL" | sort -u || true)
if [ -n "$IMPORTS" ]; then
  echo "$IMPORTS" | while read -r imp; do
    echo "    $imp"
  done
else
  echo "    (全部标准库或内部模块)"
fi

# ═══════════════════════════════════════════
# 6. Hook 注册完整性
# ═══════════════════════════════════════════
hr "6. Hook 注册"

HJ="$PLUGIN/hooks/hooks.json"
if [ -f "$HJ" ]; then
  export PYTHONIOENCODING=utf-8
  # 生成临时 Python 审计脚本（避免内联转义问题）
  AUDIT_PY=$(mktemp)
  cat > "$AUDIT_PY" << 'PYEOF'
import json, re, os, sys

plugin = sys.argv[1]
with open(sys.argv[2], encoding='utf-8') as f:
    d = json.load(f)

# 事件统计
print("  注册事件:")
for evt, groups in d.get('hooks', {}).items():
    scripts = []
    for g in groups:
        for h in g.get('hooks', []):
            m = re.findall(r'CLAUDE_PLUGIN_ROOT\}?/([^\"\s]+)', h.get('command', ''))
            scripts.extend(m)
    print(f'    {evt}: {len(groups)} 组, {len(scripts)} 脚本')
    for s in scripts:
        print(f'      → {s}')

# 缺失检查
missing = []
for evt, groups in d.get('hooks', {}).items():
    for g in groups:
        for h in g.get('hooks', []):
            m = re.findall(r'CLAUDE_PLUGIN_ROOT\}?/([^\"\s]+)', h.get('command', ''))
            for s in m:
                if not os.path.exists(os.path.join(plugin, s)):
                    missing.append(s)

if missing:
    print("\n  ⚠ 缺失脚本:")
    for m in sorted(set(missing)):
        print(f'    - {m}')
else:
    print("\n  ✓ 所有注册脚本存在")
PYEOF
  python3 "$AUDIT_PY" "$PLUGIN" "$HJ" 2>/dev/null
  rm -f "$AUDIT_PY"
else
  bad "hooks.json 不存在"
fi

# ═══════════════════════════════════════════
# 7. 冗余/死代码检测
# ═══════════════════════════════════════════
hr "7. 潜在问题"

# 未使用的 source
echo "  重复 source:"
grep -h "source " $ALL_SHELL 2>/dev/null | sort | uniq -c | sort -rn | while read -r count src; do
  if [ "$count" -gt 1 ] 2>/dev/null; then
    echo "    ${count}x: $src"
  fi
done

# 空文件
echo ""
echo "  空/极小文件 (<10行):"
for f in $ALL_SHELL; do
  [ ! -f "$f" ] && continue
  lines=$(wc -l < "$f" 2>/dev/null)
  if [ "$lines" -lt 10 ] 2>/dev/null; then
    rel="${f#$PLUGIN/}"
    warn "$rel ($lines 行)"
  fi
done

# ═══════════════════════════════════════════
# 8. 测试覆盖率
# ═══════════════════════════════════════════
hr "8. 测试覆盖"

TEST_COUNT=$(find "$PLUGIN/tests" -name "test_*.sh" -type f 2>/dev/null | wc -l)
kv "测试文件" "$TEST_COUNT"

# 有测试覆盖的模块
echo ""
echo "  覆盖状态:"
for f in $ALL_SHELL; do
  [ ! -f "$f" ] && continue
  rel="${f#$PLUGIN/}"
  base=$(basename "$f" .sh)
  TEST_FILE="$PLUGIN/tests/test_${base}.sh"
  LINT_FILE="$PLUGIN/tests/lint_hooks.sh"
  if [ -f "$TEST_FILE" ]; then
    good "$rel → tests/test_${base}.sh"
  elif echo "$rel" | grep -q "^tests/"; then
    :  # skip test files themselves
  elif echo "$rel" | grep -q "^hooks/lib/"; then
    good "$rel → tests/test_common.sh (via source)"
  else
    warn "$rel — 无对应测试"
  fi
done

# ═══════════════════════════════════════════
# 9. 架构合规
# ═══════════════════════════════════════════
hr "9. 架构合规检查"

# 规则 1: Hook 脚本都必须从 _common.sh source
VIOLATIONS=0
for f in $HOOK_FILES; do
  [ ! -f "$f" ] && continue
  if echo "$f" | grep -q "/lib/"; then continue; fi
  if ! grep -q "_common.sh" "$f" 2>/dev/null; then
    warn "$(basename "$f"): 未 source _common.sh"
    VIOLATIONS=$((VIOLATIONS+1))
  fi
done
[ "$VIOLATIONS" -eq 0 ] && good "所有 Hook 脚本 source _common.sh"

# 规则 2: 所有脚本有 shebang
NO_SHEBANG=0
for f in $ALL_SHELL; do
  [ ! -f "$f" ] && continue
  if echo "$f" | grep -q "/lib/\|tests/assert"; then continue; fi
  if ! head -1 "$f" | grep -qE '^#!'; then
    NO_SHEBANG=$((NO_SHEBANG+1))
  fi
done
[ "$NO_SHEBANG" -eq 0 ] && good "所有脚本有 shebang" || warn "$NO_SHEBANG 个脚本缺 shebang"

# 规则 3: 不使用硬编码路径 (E:/ 等)
HARDCODED=$(grep -l 'E:/' $ALL_SHELL 2>/dev/null || true)
if [ -z "$HARDCODED" ]; then
  good "无硬编码 E:/ 路径"
else
  warn "硬编码路径: $HARDCODED"
fi

# ═══════════════════════════════════════════
# 10. 总结
# ═══════════════════════════════════════════
hr "10. 总结"
echo ""
kv "总文件数" "$((HOOK_COUNT + SCRIPT_COUNT + PY_COUNT + SKILL_COUNT))"
kv "总代码行" "$((SHELL_LINES + PY_LINES))"
kv "外部脐带" "$(echo "$EXT_REFS" | grep -c '.' 2>/dev/null || echo 0) 处"
kv "测试套件" "$TEST_COUNT 文件"
echo ""

# 健康评分
SCORE=10
[ "$VIOLATIONS" -gt 0 ] && SCORE=$((SCORE - VIOLATIONS))
[ "$NO_SHEBANG" -gt 0 ] && SCORE=$((SCORE - NO_SHEBANG))
[ -n "$HARDCODED" ] && SCORE=$((SCORE - 2))
[ "$TEST_COUNT" -lt 3 ] && SCORE=$((SCORE - 2))

echo "  ╔══════════════════════╗"
printf "  ║  健康评分: %2d / 10    ║\n" $SCORE
echo "  ╚══════════════════════╝"
