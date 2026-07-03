#!/bin/bash
# validate_hooks_json.sh — L1: hooks.json 结构 + 脚本路径存在性
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PLUGIN="$(dirname "$SCRIPT_DIR")"
source "$SCRIPT_DIR/assert.sh"

echo "=== Validate: hooks.json ==="

HJ="$PLUGIN/hooks/hooks.json"

HJ_FILE="$HJ"
HJ_SCRIPT=$(mktemp)
cat > "$HJ_SCRIPT" << 'PYEOF'
import json, sys, os, re

with open(sys.argv[1], encoding='utf-8') as f:
    d = json.load(f)

if len(sys.argv) > 2:
    check = sys.argv[2]
    if check == "syntax":
        print("ok")
    elif check == "fields":
        for field in ["description", "hooks"]:
            assert field in d, f"missing: {field}"
        print("ok")
    elif check == "events":
        for e in d.get("hooks", {}):
            print(f"{e}:{len(d['hooks'][e])}")
    elif check == "scripts":
        scripts = set()
        for evt_list in d.get("hooks", {}).values():
            for group in evt_list:
                for h in group.get("hooks", []):
                    cmd = h.get("command", "")
                    matches = re.findall(r'[\"\$\{]*CLAUDE_PLUGIN_ROOT\}?/([^\"\s]+)', cmd)
                    for m in matches:
                        scripts.add(m)
        for s in sorted(scripts):
            print(s)
    elif check == "max_timeout":
        mt = 0
        for evt_list in d.get("hooks", {}).values():
            for group in evt_list:
                for h in group.get("hooks", []):
                    t = h.get("timeout", 0)
                    if t > mt:
                        mt = t
        print(mt)
PYEOF

# 1. JSON 语法
if python3 "$HJ_SCRIPT" "$HJ_FILE" syntax 2>/dev/null; then
  pass "JSON 语法"
else
  fail "JSON 语法错误"
  rm -f "$HJ_SCRIPT"; finish; exit 1
fi

# 2. 必需字段
if python3 "$HJ_SCRIPT" "$HJ_FILE" fields 2>/dev/null; then
  pass "字段: description + hooks"
else
  fail "缺必需字段"
fi

# 3. Hook 事件存在性
EVENTS_LIST=$(mktemp)
python3 "$HJ_SCRIPT" "$HJ_FILE" events 2>/dev/null | tr -d '\r' > "$EVENTS_LIST"
while IFS=':' read -r event count; do
  [ -z "$event" ] && continue
  pass "事件 $event: $count 组"
done < "$EVENTS_LIST"
rm -f "$EVENTS_LIST"

# 4. 所有引用的脚本路径存在
SCRIPTS_LIST=$(mktemp)
python3 "$HJ_SCRIPT" "$HJ_FILE" scripts 2>/dev/null | tr -d '\r' > "$SCRIPTS_LIST"
while read -r script; do
  [ -z "$script" ] && continue
  if [ -f "$PLUGIN/$script" ]; then
    pass "脚本: $script"
  else
    fail "脚本缺失: $script"
  fi
done < "$SCRIPTS_LIST"
rm -f "$SCRIPTS_LIST"

# 5. 超时值合理性
MAX_TIMEOUT=$(python3 "$HJ_SCRIPT" "$HJ_FILE" max_timeout 2>/dev/null)
if [ "$MAX_TIMEOUT" -le 30 ] 2>/dev/null; then
  pass "最大超时: ${MAX_TIMEOUT}s (<=30s)"
else
  fail "最大超时: ${MAX_TIMEOUT}s (>30s 上限)"
fi

rm -f "$HJ_SCRIPT"
finish
