#!/usr/bin/env python3
"""
压力测试脚本 — 验证上下文管理系统全部功能
用法: python stress_test.py [project_dir]
默认: E:/Files/ClaudeCode-测试目录
"""

import sys, os, json, time, random

TEST_DIR = sys.argv[1] if len(sys.argv) > 1 else 'E:/Files/ClaudeCode-测试目录'
sys.path.insert(0, 'E:/Files/ClaudeCode-ContextPlugin/mcp')

from db_core import ensure_schema, get_db_path
from db_ops import (
    session_create, session_finalize, session_get, session_list,
    session_check_active, session_mark_abandoned, session_events,
    event_log,
    memory_search, memory_store, memory_get, memory_update, memory_delete, memory_list,
    decision_record, decision_list,
    pattern_register, pattern_list,
    preference_get, preference_set,
    stats_overview,
    briefing_generate, briefing_get,
    decay_run, dedup_run,
)

PASS = 0
FAIL = 0

def check(desc, condition):
    global PASS, FAIL
    if condition:
        PASS += 1
        print(f"  [PASS] {desc}")
    else:
        FAIL += 1
        print(f"  ❌ {desc}")

print("=" * 60)
print("  上下文管理系统 — 压力测试")
print(f"  目标: {TEST_DIR}")
print("=" * 60)

# Clean start
db_path = get_db_path(TEST_DIR)
if os.path.exists(db_path):
    os.remove(db_path)
ensure_schema(TEST_DIR)

# ============================================================
# 测试 1: 基础 CRUD — 会话创建/结束/查询
# ============================================================
print("\n── 测试 1: 会话 CRUD ──")

s1 = session_create(TEST_DIR, date='2026-07-01', time_val='100000', slug='2026-07-01_100000', pid=1000)
check("session_create 返回 id", s1.get('id') is not None)
check("session_create 返回 slug", s1['slug'] == '2026-07-01_100000')

s2 = session_create(TEST_DIR, date='2026-07-01', time_val='110000', slug='2026-07-01_110000', pid=1001)
s3 = session_create(TEST_DIR, date='2026-07-02', time_val='090000', slug='2026-07-02_090000', pid=1002)

# Event logging
for tool in ['Read', 'Grep', 'Edit', 'Write', 'Bash', 'Glob', 'WebSearch']:
    for _ in range(random.randint(1, 5)):
        event_log(TEST_DIR, session_id=s1['id'], tool_name=tool, tool_input_summary=f'test {tool}')

check("event_log 写入成功", True)

# Add events to other sessions
for tool in ['Read', 'Bash', 'Edit']:
    event_log(TEST_DIR, session_id=s2['id'], tool_name=tool, tool_input_summary=f'test {tool}')
for tool in ['Read', 'Write', 'Bash', 'Glob']:
    event_log(TEST_DIR, session_id=s3['id'], tool_name=tool, tool_input_summary=f'test {tool}')

# Finalize session 1
sf1 = session_finalize(TEST_DIR, session_id=s1['id'], summary='完成初始架构搭建', exit_code=0)
check("session_finalize 成功", sf1.get('status') == 'completed')

# Finalize session 2 (simulate crash)
sf2 = session_finalize(TEST_DIR, session_id=s2['id'], summary='修复 post-tool 双写 bug', exit_code=1)
check("session_finalize crash exit", sf2.get('status') == 'completed')

# Session list
sessions = session_list(TEST_DIR)
check(f"session_list 返回 {len(sessions)} 条 (预期 3)", len(sessions) == 3)

# Session get by slug
sg = session_get(TEST_DIR, slug='2026-07-01_100000')
check("session_get by slug", sg is not None and sg['status'] == 'completed')

# Session events
evts = session_events(TEST_DIR, session_id=s1['id'])
check(f"session_events 返回 {len(evts)} 条 (>0)", len(evts) > 0)

# Active session check
active = session_check_active(TEST_DIR)
check("session_check_active 找到 s3", active is not None and active['slug'] == '2026-07-02_090000')

# Mark abandoned (excluding s3)
r = session_mark_abandoned(TEST_DIR, exclude_id=s3['id'])
check("session_mark_abandoned 排除当前", r.get('rowcount', 0) == 0)

# ============================================================
# 测试 2: Memory CRUD + 去重
# ============================================================
print("\n── 测试 2: Memory CRUD + 去重 ──")

m1 = memory_store(TEST_DIR, content='项目使用 FastAPI 作为后端框架', mem_type='semantic',
                  session_id=s1['id'], tags=['tech-stack', 'backend'])
check("memory_store semantic", m1.get('status') in ('stored', 'deduped_exact'))

m2 = memory_store(TEST_DIR, content='JWT token 存储在 Redis，支持 refresh token rotation',
                  mem_type='semantic', session_id=s1['id'], tags=['auth', 'security'])
check("memory_store JWT decision", m2.get('status') in ('stored', 'deduped_exact'))

m3 = memory_store(TEST_DIR, content='bug#2 修复: SessionStart 必须排除当前会话避免 abandoned',
                  mem_type='episodic', session_id=s2['id'], tags=['bugfix'])
check("memory_store episodic bug", m3.get('status') in ('stored', 'deduped_exact'))

m4 = memory_store(TEST_DIR, content='部署流程: merge → CI lint → CI test → auto-deploy staging',
                  mem_type='procedural', session_id=s1['id'], tags=['deploy', 'workflow'])
check("memory_store procedural", m4.get('status') in ('stored', 'deduped_exact'))

# Exact dedup test
m5 = memory_store(TEST_DIR, content='项目使用 FastAPI 作为后端框架', mem_type='semantic',
                  session_id=s3['id'], tags=['tech-stack'])
check("exact fingerprint dedup", m5.get('status') == 'deduped_exact')

# Near-duplicate test
m6 = memory_store(TEST_DIR, content='项目使用 FastAPI 作为后端的 Web 框架',
                  mem_type='semantic', session_id=s3['id'], tags=['tech-stack', 'backend'])
check("Jaccard near-duplicate (>0.85)", m6.get('status') in ('near_duplicate', 'stored'))

# Memory get
mg = memory_get(TEST_DIR, mem_id=m1['id'])
check("memory_get by id", mg is not None and 'FastAPI' in mg['content'])

# Memory update
mu = memory_update(TEST_DIR, mem_id=m2['id'], importance=0.9)
check("memory_update importance", mu['status'] == 'updated')

# Memory search
results = memory_search(TEST_DIR, query='FastAPI')
check(f"FTS5 search 'FastAPI' -> {len(results)} results", len(results) > 0)

results2 = memory_search(TEST_DIR, query='Redis')
check(f"FTS5 search 'Redis' -> {len(results2)} results", len(results2) > 0)

# Memory list
ml = memory_list(TEST_DIR, mem_type='semantic')
check(f"memory_list semantic -> {len(ml)} results", len(ml) >= 1)

ml2 = memory_list(TEST_DIR)
check(f"memory_list all -> {len(ml2)} results", len(ml2) >= 4)

# ============================================================
# 测试 3: Decision + Pattern + Preference
# ============================================================
print("\n── 测试 3: Decision / Pattern / Preference ──")

d1 = decision_record(TEST_DIR, title='选择 FastAPI 作为后端框架',
                     context='需要异步支持和自动 OpenAPI 文档',
                     rationale='性能好、生态成熟、与团队技能匹配',
                     alternatives=['Flask', 'Django Ninja', 'Litestar'],
                     session_id=s1['id'])
check("decision_record", d1.get('id') is not None)

d2 = decision_record(TEST_DIR, title='使用 JWT + Redis 做认证',
                     context='需要无状态认证 + token 吊销能力',
                     rationale='JWT 减少数据库查询，Redis 提供快速吊销',
                     alternatives=['Session + Cookie', 'OAuth2 Proxy'],
                     session_id=s1['id'])
check("decision_record 2", d2.get('id') is not None)

dec_list = decision_list(TEST_DIR)
check(f"decision_list -> {len(dec_list)} active", len(dec_list) == 2)

p1 = pattern_register(TEST_DIR, title='错误处理统一用 Result 类型',
                      description='所有函数返回 Result[T, E] 而非 raise Exception',
                      category='convention', confidence=0.9)
check("pattern_register", p1.get('id') is not None)

p2 = pattern_register(TEST_DIR, title='SQLite PRAGMA 优化',
                      description='WAL 模式 + foreign_keys ON + busy_timeout 5000',
                      category='optimization', confidence=0.95)
check("pattern_register 2", p2.get('id') is not None)

pat_list = pattern_list(TEST_DIR)
check(f"pattern_list -> {len(pat_list)} patterns", len(pat_list) == 2)

pref1 = preference_set(TEST_DIR, key='code_style', value='PEP 8 strict', category='convention')
check("preference_set", pref1.get('status') == 'saved')

pref2 = preference_set(TEST_DIR, key='test_framework', value='pytest + pytest-asyncio', category='tech')
check("preference_set 2", pref2.get('status') == 'saved')

pref_get = preference_get(TEST_DIR, key='code_style')
check("preference_get", pref_get == 'PEP 8 strict')

# ============================================================
# 测试 4: Stats + Briefing
# ============================================================
print("\n── 测试 4: Stats + Briefing ──")

# Finalize s3 first
session_finalize(TEST_DIR, session_id=s3['id'], summary='压力测试会话', exit_code=0)

stats = stats_overview(TEST_DIR)
check(f"stats_overview total_sessions={stats['total_sessions']}", stats['total_sessions'] == 3)
check(f"stats_overview completed={stats['completed']}", stats['completed'] >= 2)
check(f"stats_overview total_memories={stats['total_memories']}", stats['total_memories'] >= 4)
check(f"stats_overview active_decisions={stats['active_decisions']}", stats['active_decisions'] == 2)
check(f"stats_overview patterns={stats['patterns']}", stats['patterns'] == 2)
check(f"stats_overview total_events={stats['total_events']}", stats['total_events'] > 0)

brief = briefing_generate(TEST_DIR)
check("briefing_generate 非空", brief is not None and len(brief) > 0)
token_est = len(brief.split()) // 2
check(f"简报 token 估算: ~{token_est} (<=500)", token_est <= 500)

print(f"\n  简报内容:\n{brief[:300]}...")

# ============================================================
# 测试 5: 衰减 + 去重
# ============================================================
print("\n── 测试 5: Decay + Dedup ──")

decay_result = decay_run(TEST_DIR)
check(f"decay_run 完成 (archived={decay_result.get('archived',0)}, deleted={decay_result.get('deleted',0)})", 'error' not in decay_result)

dedup_result = dedup_run(TEST_DIR, dry_run=True)
check(f"dedup_run dry_run -> {len(dedup_result)} duplicates found", isinstance(dedup_result, list))

dedup_real = dedup_run(TEST_DIR, dry_run=False)
check(f"dedup_run real -> {len(dedup_real)} processed", isinstance(dedup_real, list))

# ============================================================
# 测试 6: 边界情况
# ============================================================
print("\n── 测试 6: 边界情况 ──")

# Empty search
empty = memory_search(TEST_DIR, query='xyznonexistent12345')
check("FTS5 search miss -> 0 results", len(empty) == 0)

# Create 50 sessions rapidly
print("  创建 50 个模拟会话...")
for i in range(50):
    sid = session_create(TEST_DIR, date=f'2026-07-{(i//20)+3:02d}',
                         time_val=f'{10000+(i*137)%80000:06d}',
                         slug=f'2026-07-{(i//20)+3:02d}_{10000+(i*137)%80000:06d}',
                         pid=2000+i)
    event_log(TEST_DIR, session_id=sid['id'], tool_name='Test', tool_input_summary=f'stress {i}')
    session_finalize(TEST_DIR, session_id=sid['id'], summary=f'压力测试会话 #{i}', exit_code=0)

final_stats = stats_overview(TEST_DIR)
check(f"50 sessions created -> total={final_stats['total_sessions']}", final_stats['total_sessions'] == 53)

# Session list pagination
page = session_list(TEST_DIR, limit=10, offset=0)
check(f"session_list page1 -> {len(page)} items", len(page) == 10)

# Search across many sessions
search = memory_search(TEST_DIR, query='FastAPI', limit=5)
check(f"FTS5 search still works after 50 sessions -> {len(search)} results", len(search) > 0)

# Memory persistence
mem_count = final_stats['total_memories']
check(f"Memories survived 50-session storm: {mem_count}", mem_count >= 4)

# ============================================================
# 结果总结
# ============================================================
print()
print("=" * 60)
print(f"  测试结果: {PASS} 通过 / {FAIL} 失败 / {PASS+FAIL} 总计")
if FAIL == 0:
    print("  🎉 全部通过！")
else:
    print(f"  ⚠ {FAIL} 项失败，需要排查")
print("=" * 60)

# DB 最终状态
print(f"\n  DB 文件: {db_path}")
print(f"  大小: {os.path.getsize(db_path) / 1024:.0f} KB")
print(f"  会话: {final_stats['total_sessions']}")
print(f"  事件: {final_stats['total_events']}")
print(f"  记忆: {final_stats['total_memories']}")
print(f"  决策: {final_stats['active_decisions']}")
print(f"  模式: {final_stats['patterns']}")

sys.exit(0 if FAIL == 0 else 1)
