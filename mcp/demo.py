#!/usr/bin/env python3
"""
交互式演示 — 展示 v3.0 上下文管理系统的完整工作流程
运行: python3 E:/Files/ClaudeCode-ContextPlugin/mcp/demo.py
"""

import sys, os, time
sys.path.insert(0, 'E:/Files/ClaudeCode-ContextPlugin/mcp')

TEST_DIR = 'E:/Files/ClaudeCode-测试目录'

from db_core import ensure_schema, get_db_path
from db_ops import *

def hr(title):
    print(f"\n{'='*60}")
    print(f"  {title}")
    print('='*60)

def step(n, desc):
    print(f"\n  >>> 步骤{n}: {desc}")

# ── 初始化 ──
db_path = get_db_path(TEST_DIR)
if os.path.exists(db_path):
    os.remove(db_path)
ensure_schema(TEST_DIR)

print("""
╔══════════════════════════════════════════════════════╗
║    Claude Code 上下文管理系统 v3.0 — 演示            ║
║    模拟 3 次完整会话, 展示记忆增长和搜索演进           ║
╚══════════════════════════════════════════════════════╝
""")

# ══════════════════════════════════════════════════════
# 会话 1: 项目初始化
# ══════════════════════════════════════════════════════
hr("会话 1: 项目初始化 — 搭建 FastAPI 后端")
time.sleep(0.5)

step(1, "会话创建")
s1 = session_create(TEST_DIR, date='2026-07-03', time_val='140000', slug='2026-07-03_140000', pid=5001)
print(f"    ID: {s1['id'][:16]}...")
print(f"    状态: {s1['status']}")

step(2, "用户开始工作 — 工具调用被自动记录")
tools_used = [
    ('Read', 'CLAUDE.md'),
    ('Bash', 'pip install fastapi'),
    ('Write', 'main.py — FastAPI app scaffold'),
    ('Write', 'models/user.py — User + async DB model'),
    ('Bash', 'pytest tests/ — 12 passed'),
    ('Edit', 'main.py — add CORS middleware'),
    ('Read', 'docs/fastapi-best-practices.md'),
    ('Write', 'auth.py — JWT + bcrypt auth module'),
    ('Bash', 'uvicorn main:app — server started at :8000'),
    ('Edit', 'auth.py — add refresh token rotation'),
]
for tool, detail in tools_used:
    event_log(TEST_DIR, session_id=s1['id'], tool_name=tool, tool_input_summary=detail)
    print(f"    📝 {tool}: {detail}")

step(3, "用户说「记住这些」 — 手动存储记忆")
m1 = memory_store(TEST_DIR, content='后端使用 FastAPI 框架，所有端点必须 async def', mem_type='semantic', session_id=s1['id'], tags=['backend','convention'])
m2 = memory_store(TEST_DIR, content='认证方案: JWT access token (15min) + refresh token (7d)，token 存储在 Redis', mem_type='decision', session_id=s1['id'], tags=['auth','security'])
m3 = memory_store(TEST_DIR, content='密码使用 bcrypt 哈希，12 轮 salt', mem_type='semantic', session_id=s1['id'], tags=['auth','security'])
m4 = memory_store(TEST_DIR, content='测试框架: pytest + pytest-asyncio + httpx.AsyncClient', mem_type='procedural', session_id=s1['id'], tags=['testing'])
m5 = memory_store(TEST_DIR, content='统一错误处理: 使用 Result[T,E] 类型，永不裸 raise', mem_type='pattern', session_id=s1['id'], tags=['convention','error-handling'])
m6 = memory_store(TEST_DIR, content='部署: GitHub Actions → merge develop 触发 CI lint+test → auto-deploy staging', mem_type='procedural', session_id=s1['id'], tags=['deploy','ci'])
print(f"    存储了 6 条记忆")
print(f"    [{m1['status']}] FastAPI 约定")
print(f"    [{m2['status']}] JWT 认证方案")
print(f"    [{m3['status']}] bcrypt 配置")
print(f"    [{m4['status']}] 测试框架")
print(f"    [{m5['status']}] 错误处理模式")
print(f"    [{m6['status']}] 部署流程")

# 建立关系
memory_relation_create(TEST_DIR, source_id=m1['id'], target_id=m5['id'], relation_type='extends')
memory_relation_create(TEST_DIR, source_id=m2['id'], target_id=m3['id'], relation_type='depends_on')

step(4, "会话结束 — 自动捕获 + 衰减清理")
r = session_finalize(TEST_DIR, session_id=s1['id'], summary='完成 FastAPI 后端初始化, 实现 JWT 认证 + async 约定', exit_code=0)
print(f"    结束状态: {r['status']}")
print(f"    时长: {r.get('duration_min','?')} 分钟")

# ══════════════════════════════════════════════════════
# 会话 2: Bug 修复
# ══════════════════════════════════════════════════════
hr("会话 2: Bug 修复 — JWT refresh token 泄露")
time.sleep(0.5)

step(1, "会话创建")
s2 = session_create(TEST_DIR, date='2026-07-03', time_val='150000', slug='2026-07-03_150000', pid=5002)

step(2, "工作中...")
for tool, detail in [
    ('Read', 'auth.py — token rotation logic'),
    ('Grep', 'refresh_token — 发现存储明文'),
    ('Edit', 'auth.py — hash refresh tokens before storing'),
    ('Bash', 'pytest tests/test_auth.py — 2 FAILED'),
    ('Edit', 'tests/test_auth.py — update token assertions'),
    ('Bash', 'pytest tests/test_auth.py — 14 passed'),
    ('Read', 'Redis 文档 — key expiration'),
    ('Edit', 'auth.py — add Redis TTL for tokens'),
]:
    event_log(TEST_DIR, session_id=s2['id'], tool_name=tool, tool_input_summary=detail)

step(3, "用户纠正 AI 的错误做法 — 自动存为 pattern")
memory_store(TEST_DIR, content='【用户纠正】refresh token 必须在 Redis 中 hash 存储，不能存明文 — 上次 session 140000 中 auth.py 的 token 实现有安全漏洞', mem_type='pattern', session_id=s2['id'], tags=['security','correction','bugfix'])
print(f"    ✅ 用户纠正已存为 pattern")

step(4, "尝试重复存储 — 触发去重")
dup = memory_store(TEST_DIR, content='后端使用 FastAPI 框架，所有端点必须 async def', mem_type='semantic', session_id=s2['id'])
print(f"    去重结果: {dup['status']} (命中已有记忆 {dup.get('id','?')[:16]}...)")

step(5, "会话结束")
session_finalize(TEST_DIR, session_id=s2['id'], summary='修复 refresh token 明文存储漏洞, hash + TTL', exit_code=0)

# ══════════════════════════════════════════════════════
# 会话 3: 新功能 + 搜索演示
# ══════════════════════════════════════════════════════
hr("会话 3: 新功能开发 — 此时系统已有 2 次会话的经验")
time.sleep(0.5)

step(1, "会话创建")
s3 = session_create(TEST_DIR, date='2026-07-03', time_val='160000', slug='2026-07-03_160000', pid=5003)

step(2, "SessionStart: AI 看到「会话简报」")
brief = briefing_generate(TEST_DIR)
print(f"    📋 AI 启动时看到的简报 ({len(brief.split())//2} tokens):")
print(f"    {'─'*50}")
for line in brief.split('\n'):
    print(f"    │ {line}")
print(f"    {'─'*50}")

step(3, "AI: 「上次是怎么做认证的来着？」→ 搜索")
results = memory_hybrid_search(TEST_DIR, query='auth JWT token Redis', top_k=3)
print(f"    混合搜索返回 {len(results)} 条结果:")
for m in results:
    print(f"    📌 [{m['type']:12s}] {m['content'][:80]}")

step(4, "AI: 「async 有什么约定？」→ 搜索 + 关系遍历")
results2 = memory_search(TEST_DIR, query='async def convention', limit=2)
if results2:
    related = memory_relations_get(TEST_DIR, mem_id=results2[0]['id'], max_depth=1)
    print(f"    📌 直接匹配: {results2[0]['content'][:80]}")
    print(f"    🔗 关联记忆 ({len(related)} 条):")
    for m in related:
        print(f"       └─ [{m['type']}] {m['content'][:80]}")

step(5, "工作中...")
for tool, detail in [
    ('Read', 'auth.py'),
    ('Write', 'endpoints/websocket.py — WebSocket endpoint'),
    ('Bash', 'pytest tests/ — 18 passed'),
    ('Edit', 'main.py — register WebSocket router'),
]:
    event_log(TEST_DIR, session_id=s3['id'], tool_name=tool, tool_input_summary=detail)

step(6, "AI 记录新决策")
d1 = decision_record(TEST_DIR, title='WebSocket 连接使用 Redis Pub/Sub 做跨进程广播', context='多 worker 进程需要共享 WebSocket 消息', rationale='Redis 已在栈中, Pub/Sub 足够轻量', alternatives=['RabbitMQ', 'PostgreSQL LISTEN/NOTIFY', 'gRPC stream'], session_id=s3['id'])
print(f"    决策已记录: {d1['title']}")

step(7, "AI 发现新模式")
p1 = pattern_register(TEST_DIR, title='WebSocket handler 必须带 try/finally 确保 disconnect', description='忘记 finally disconnect 会导致 Redis 连接泄漏', category='bug', confidence=0.9, session_id=s3['id'])
print(f"    模式已注册: {p1['title']}")

step(8, "会话结束")
session_finalize(TEST_DIR, session_id=s3['id'], summary='新增 WebSocket 支持, Redis Pub/Sub 跨进程广播', exit_code=0)

# ══════════════════════════════════════════════════════
# 最终统计
# ══════════════════════════════════════════════════════
hr("📊 系统总览 — 3 次会话后 DB 状态")
time.sleep(0.5)

stats = stats_overview(TEST_DIR)
decay_result = decay_run(TEST_DIR)

print(f"""
    ┌──────────────────────────────────┐
    │  会话总数:  {stats['total_sessions']:>3}                      │
    │  完成:      {stats['completed']:>3}                      │
    │  事件总数:  {stats['total_events']:>3}                      │
    │  记忆总数:  {stats['total_memories']:>3}                      │
    │  活跃决策:  {stats['active_decisions']:>3}                      │
    │  模式:      {stats['patterns']:>3}                      │
    │  DB 大小:   {os.path.getsize(db_path)/1024:.0f} KB                   │
    │  衰减:      归档 {decay_result.get('archived',0)}, 删除 {decay_result.get('deleted',0)}          │
    └──────────────────────────────────┘
""")

print("  记忆类型分布:")
for mt in ['semantic', 'decision', 'procedural', 'pattern', 'episodic', 'preference']:
    count = len(memory_list(TEST_DIR, mem_type=mt))
    if count > 0:
        print(f"    {mt:15s} {count} 条")

print("\n  最近 3 次会话:")
for s in session_list(TEST_DIR, limit=3):
    print(f"    {s['slug']}: {s.get('summary','?')[:60]}")

print(f"""
╔══════════════════════════════════════════════════════╗
║  🎉 演示完成                                         ║
║                                                      ║
║  这就是 v3.0 的实际效果:                              ║
║  - 每次会话自动记录事件                                ║
║  - 记忆自动去重, 类型分类                              ║
║  - FTS5 + 向量混合搜索, 跨会话检索                     ║
║  - SessionStart 自动注入简报                           ║
║  - 记忆关系图谱, BFS 遍历                              ║
║  - 一切都自然积累, 不需要手动维护                       ║
║                                                      ║
║  DB 位置: {db_path}
╚══════════════════════════════════════════════════════╝
""")
