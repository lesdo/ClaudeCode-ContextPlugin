# Checkpoint: 修复启动报告 + MCP 幽灵目录
**Saved:** 2026-07-08T23:50:00+08:00
**Task:** 修复两个启动 Bug，提炼教训
**Progress:** 2/2 完成

## Context
上次会话的架构修复（.mcp.json + session-start.sh 精简）引入/保留了 Bug：启动报告误报"无会话目录"，MCP 服务器连到错误数据库。两个 Bug 都导致 LLM 无法正确查询会话历史。

## Decisions Made
- session-start.sh exit 0：改为 continue + 提示，不提前退出。让下方 MCP 初始化/崩溃检测/简报正常执行
- .mcp.json env 块：删除 `CLAUDE_PROJECT_DIR: "${CLAUDE_PROJECT_DIR}"`，改为空 `{}`。MCP 服务器 fallback 到 os.getcwd() 自动正确
- 垃圾目录清理：已删 `${CLAUDE_PROJECT_DIR}/`，但当前会话 MCP 进程仍会重建，重启后不再出现

## What's Next
1. 重启 Claude Code 验证修复生效 — 启动报告应显示崩溃警告+会话统计+简报
2. 删除 `${CLAUDE_PROJECT_DIR}/` 垃圾目录（重启后不再被重建）
3. MCP 工具调用验证 — session_list 应返回真实会话数据
4. git commit 所有改动

## Gotchas
- `.mcp.json` 修改只在下次启动时生效，当前会话的 MCP 进程 env 不变
- `.context/sessions/` 目录从未存在过，session 文件在 `.claude/context/sessions/`，SESSIONS_DIR 指向错误路径是历史遗留
- 验证清单：工具可发现 ≠ 工具可用，必须端到端调用确认数据源正确
