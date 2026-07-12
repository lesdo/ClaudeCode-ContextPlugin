# Checkpoint: FastMCP 迁移 + KDNA 判断层补丁
**Saved:** 2026-07-12
**Task:** 消除 MCP handler 漂移 + KDNA 规则闭环

## Context
server.py 存在三处独立维护的工具注册（TOOLS 字典 + mcp_main handlers + cli_main handlers），导致 4/27 工具在 MCP 路径不可达。同时发现 KDNA 域缺少对 LLM 自身决策行为的约束——LLM 存在「省力合理化」默认倾向。本次一箭双雕：用 FastMCP 装饰器根治漂移，同时将反模式写入插件判断系统。

## Decisions Made
- **FastMCP 替代手动 TOOLS+handlers**: 社区推荐标准，装饰器自注册，永久消除漂移。cli_main 保留——bash hooks 需要
- **方案 C 优于 B/B'**: 首次评估时被错误排除（省力合理化），用户追问后验证发现 C 净减 114 行且更优雅
- **新 KDNA 规则: 方案排除前必须验证**: 写入 pattern_register + preference_set，立即生效。下次 KDNA 域更新时纳入主文件
- **遗孤回收暂缓**: 设计已确认（三维加权判定 + 用户确认），下次会话实现

## What's Next
1. 重启 Claude Code，验证 MCP 27 个工具全部可见
2. 在 SessionStart 中加遗孤回收逻辑（三维度：last_event + pid + checkpoint）
3. 积累 outcome_review 数据——现在工具可达但 decision_audit 表仍为空

## Gotchas
- `_PD` 是模块级变量，env var 在进程启动时一次性读取——MCP server 长期运行时不会更新，但当前场景无影响
- 测试 test_common.sh 有预存问题（session_index_append 未找到）
- E2E 7 个失败是测试环境 DB 问题，非本次改动引入
- KDNA 域文件 (.kdna) 本身未更新——规则仅在插件 SQLite 中生效
