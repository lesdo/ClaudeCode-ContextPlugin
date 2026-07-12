#!/bin/bash
# test_e2e.sh — L2: 全流程集成测试
# 覆盖: session_create → event_log → crash_diagnose → compile_md → memory
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PLUGIN="$(dirname "$SCRIPT_DIR")"
source "$SCRIPT_DIR/assert.sh"
export CLAUDE_PLUGIN_ROOT="$PLUGIN"
source "$PLUGIN/hooks/lib/_common.sh"

echo "=== E2E: 全流程 ==="

MCP="$PLUGIN/scripts/mcp-cli.sh"
TEST_DIR=$(mktemp -d)
mkdir -p "$TEST_DIR/.claude/context/sessions" "$TEST_DIR/.claude/context/briefing"
SD="2026-07-03"; ST="230000"; SLUG="${SD}_${ST}"

# ── 1. MCP 健康 ──
echo "--- 1. MCP 健康 ---"
if [ -x "$MCP" ] && command -v python3 >/dev/null; then
  bash "$MCP" "$TEST_DIR" ensure_schema 2>/dev/null >/dev/null && pass "MCP OK" || fail "MCP"
else
  fail "MCP 不可用"; finish; exit 1
fi

# ── 2. 会话创建 ──
echo "--- 2. 会话创建 ---"
SJ=$(bash "$MCP" "$TEST_DIR" session_create "{\"date\":\"$SD\",\"time_val\":\"$ST\",\"slug\":\"$SLUG\",\"pid\":$$}" 2>/dev/null)
SID=$(echo "$SJ" | python3 -c "import sys,json; print(json.load(sys.stdin).get('id','?'))" 2>/dev/null)
[ "$SID" != "?" ] && pass "DB 会话" || fail "DB 会话"

cat > "$TEST_DIR/.claude/context/sessions/${SLUG}.md" << MDEOF
# $SLUG
<!-- token: test -->
**日期**: $SD
**摘要**: E2E 测试
---
## 自动信息
（会话结束后自动填充）
---
## 上下文
测试
MDEOF
pass ".md 骨架"

# ── 3. 事件写入 ──
echo "--- 3. 事件 ---"
for args in \
  '{"tool_name":"Edit","tool_input_summary":"config.py","file_path":"config.py"}' \
  '{"tool_name":"Read","tool_input_summary":"docs/api.md","file_path":"docs/api.md"}' \
  '{"tool_name":"Bash","tool_input_summary":"git status","file_path":""}' \
  '{"tool_name":"Write","tool_input_summary":"src/main.ts","file_path":"src/main.ts"}' \
  '{"tool_name":"Bash","tool_input_summary":"npm test","file_path":""}' \
  '{"tool_name":"Edit","tool_input_summary":"src/utils.ts","file_path":"src/utils.ts"}' \
  '{"tool_name":"Write","tool_input_summary":"tests/test.ts","file_path":"tests/test.ts"}' \
  '{"tool_name":"Bash","tool_input_summary":"git diff","file_path":""}'; do
  bash "$MCP" "$TEST_DIR" event_log "$args" 2>/dev/null >/dev/null
done
EV=$(bash "$MCP" "$TEST_DIR" session_events_by_slug "{\"slug\":\"$SLUG\"}" 2>/dev/null)
EC=$(echo "$EV" | python3 -c "import sys,json; print(len(json.load(sys.stdin)))" 2>/dev/null)
assert_eq "事件数" "8" "$EC"

# ── 4. crash_diagnose ──
echo "--- 4. 诊断 ---"
read DC DS DFLAGS <<< $(crash_diagnose "$SLUG" "$TEST_DIR" "skeleton")
assert_eq "诊断" "8 L2" "$DC $DS"

# ── 5. 会话统计 ──
echo "--- 5. 统计 ---"
ST2=$(bash "$MCP" "$TEST_DIR" session_stats 2>/dev/null)
STOT=$(echo "$ST2" | python3 -c "import sys,json; print(json.load(sys.stdin).get('total',0))" 2>/dev/null)
assert_eq "会话数" "1" "$STOT"

# ── 6. 记忆 ──
echo "--- 6. 记忆 ---"
bash "$MCP" "$TEST_DIR" memory_store '{"content":"偏好 TypeScript 严格模式","mem_type":"preference","tags":["ts"]}' 2>/dev/null >/dev/null \
  && pass "store" || fail "store"
SR=$(bash "$MCP" "$TEST_DIR" memory_search '{"query":"TypeScript"}' 2>/dev/null)
SC=$(echo "$SR" | python3 -c "import sys,json; print(len(json.load(sys.stdin)))" 2>/dev/null)
assert_ge "FTS5 结果" "1" "$SC"

# ── 7. 简报 + 编译 ──
echo "--- 7. 简报+编译 ---"
BF=$(bash "$MCP" "$TEST_DIR" briefing_generate 2>/dev/null)
[ -n "$BF" ] && [ "$BF" != "null" ] && pass "简报" || fail "简报"
echo "$BF" > "$TEST_DIR/.claude/context/briefing/active.md"

bash "$MCP" "$TEST_DIR" session_finalize '{"summary":"E2E 测试通过","exit_code":0}' 2>/dev/null >/dev/null
CJ=$(bash "$MCP" "$TEST_DIR" session_compile_md "{\"slug\":\"$SLUG\"}" 2>/dev/null)
CM=$(echo "$CJ" | python3 -c "import sys,json; sys.stdout.write(json.load(sys.stdin))" 2>/dev/null)
echo "$CM" > "$TEST_DIR/.claude/context/sessions/${SLUG}.md"
assert_contains "编译: 事件" "$TEST_DIR/.claude/context/sessions/${SLUG}.md" "共 8 次"
assert_contains "编译: 摘要" "$TEST_DIR/.claude/context/sessions/${SLUG}.md" "E2E 测试"

# ── 8. 全量统计 ──
echo "--- 8. stats_overview ---"
bash "$MCP" "$TEST_DIR" stats_overview 2>/dev/null >/dev/null && pass "stats" || fail "stats"

# ── 9. 遗孤扫描 (v5.0: 3D weighted scoring) ──
echo "--- 9. 遗孤扫描 ---"
ORPHAN_DIR=$(mktemp -d)
mkdir -p "$ORPHAN_DIR/.claude/context/sessions"
bash "$MCP" "$ORPHAN_DIR" ensure_schema 2>/dev/null >/dev/null

source "$SCRIPT_DIR/_orphan_setup.sh"
setup_orphan_sessions "$ORPHAN_DIR" "$MCP"

OSCAN=$(bash "$MCP" "$ORPHAN_DIR" session_orphan_scan '{"auto_abandon":false}' 2>/dev/null)
OSCANNED=$(echo "$OSCAN" | python3 -c "import sys,json; print(json.load(sys.stdin).get('scanned',0))" 2>/dev/null)
assert_ge "遗孤扫描: scanned >= 2" "2" "${OSCANNED:-0}"

OREC_SUSPECT=$(echo "$OSCAN" | python3 -c "
import sys,json
print(len([s for s in json.load(sys.stdin).get('sessions',[]) if s.get('recommendation')=='suspect']))
" 2>/dev/null)
assert_ge "遗孤扫描: suspect >= 1" "1" "${OREC_SUSPECT:-0}"

OREC_KEEP=$(echo "$OSCAN" | python3 -c "
import sys,json
# 平行会话有事件+alive PID, 分数应低于孤儿 (但 Windows os.kill 不可靠, 不严格断言 rec)
sessions = json.load(sys.stdin).get('sessions',[])
parallel = [s for s in sessions if s.get('slug')=='2026-06-03_120000']
orphans = [s for s in sessions if s.get('slug') != '2026-06-03_120000']
if parallel and orphans:
    ps = parallel[0]['orphan_score']
    os_min = min(o['orphan_score'] for o in orphans)
    ok = ps < os_min and parallel[0]['event_count'] > 0
    print('1' if ok else '0')
else:
    print('0')
" 2>/dev/null)
assert_eq "遗孤扫描: 平行会话分数低于孤儿且有事件" "1" "${OREC_KEEP:-0}"

OERR=$(echo "$OSCAN" | python3 -c "import sys,json; print(len(json.load(sys.stdin).get('errors',[])))" 2>/dev/null)
assert_eq "遗孤扫描: errors" "0" "${OERR:-99}"

rm -rf "$ORPHAN_DIR"
pass "遗孤扫描: 3D 加权验证通过"

# ── 10. 安全扫描 (v0.2.0: secrets 14 rules) ──
echo "--- 10. 安全扫描 ---"
SHIELD_DIR=$(mktemp -d)
# 注一个假 secret 文件
echo 'export GITHUB_TOKEN="ghp_abcdefghijklmnopqrstuvwxyz1234567890"' > "$SHIELD_DIR/config.sh"
SSCAN=$(bash "$MCP" "$SHIELD_DIR" security_scan 2>/dev/null)
SFOUND=$(echo "$SSCAN" | python3 -c "import sys,json; print(json.load(sys.stdin).get('scan_summary',{}).get('total_findings',0))" 2>/dev/null)
assert_ge "安全扫描: 检测假 secret" "1" "${SFOUND:-0}"

SSEV=$(echo "$SSCAN" | python3 -c "import sys,json; print(json.load(sys.stdin).get('scan_summary',{}).get('by_severity',{}).get('critical',0))" 2>/dev/null)
assert_ge "安全扫描: 关键级别 >= 1" "1" "${SSEV:-0}"

SIMPL=$(echo "$SSCAN" | python3 -c "import sys,json; print(json.load(sys.stdin).get('implemented_rules',0))" 2>/dev/null)
assert_eq "安全扫描: implemented_rules=14" "14" "${SIMPL:-0}"
rm -rf "$SHIELD_DIR"

rm -rf "$TEST_DIR"
finish
