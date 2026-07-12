# Checkpoint: 修复工具可发现性 + 源漂移 + 会话连续性
**Saved:** 2026-07-08T23:00:00+08:00
**Task:** 实施三个架构修复（全部完成）
**Progress:** 4/4 tasks complete, 6/6 tests pass

## Context
经过一整天的分析（自审计+对标+Grill），定位了三层根因：MCP 工具未注册→LLM 不可见→绕过 SQLite 直接读文件→源漂移+会话冷启动。实施了 .mcp.json 注册 + session-start.sh 精简 + tool annotations 三个修复。

## Decisions Made
- MCP 注册用 `.mcp.json` stdio 模式: 比 `/engram` 命令更优雅，零 token 成本自动发现
- Push/Pull 边界: Push=画像+规则+项目+崩溃+简报≤500t+checkpoint指针；Pull=全部 MCP 工具
- `.context/sessions/*.md` 退化为纯人类可读备份: 不再在 SessionStart 输出中暴露
- 15 个只读工具加了 readOnlyHint: 减少权限弹窗

## What's Next
1. 真实 Claude Code 会话验证 `.mcp.json` 加载 — 检查 MCP 工具是否出现在工具列表
2. 端到端测试："看看上次会话做了什么" — 确认 LLM 调 session_list 而非 ls+Read
3. 如果 .mcp.json 变量不生效 → fallback 绝对路径

## Gotchas
- `.mcp.json` 中 `${CLAUDE_PROJECT_DIR}` 变量是否可用需实测; 不可用则改用绝对路径
- 测试 `test_session_start.sh` 中有路径 bug（`.claude/context/sessions/` vs `.context/sessions/`），已修复
- ArcSight 对项目不可用（仅支持 JS/TS），建议卸载 `npm uninstall -g arcsight`
- `scripts/claude-monitored.sh` 有预存修改未提交（非本次改动）
