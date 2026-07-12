# Grill: 会话连续性与工具可发现性

Date: 2026-07-08

## Intent
解决用户核心痛点——每次新会话 LLM 冷启动，需要重复喂养上下文。具体表现为三个层级的架构问题需要修复。

## Constraints
- 不能增加用户操作负担（零额外命令）
- SessionStart 注入控制在 ≤500 tokens（不挤占上下文窗口）
- `.context/sessions/*.md` 保留为人类可读备份，不再向 LLM 暴露
- 遵循 Anthropic 官方 Hook 最佳实践

## Key decisions

1. **MCP 工具注册**：创建 `.mcp.json` 注册 `mcp/server.py --mcp` 为 stdio MCP server。
   - Reason: 当前 server.py 有完整 MCP 实现但从未注册，LLM 看不到 20+ 工具，只能绕过 SQLite 直接读文件。
   - Alternative: `/engram` 命令（engram 做法）——需要用户手动触发，token 成本高，维护漂移风险。拒绝。

2. **源漂移消除**：SessionStart 不再提 `.context/sessions/` 目录，不输出 `ls` 文件列表。会话数据唯一入口是 MCP 工具。
   - Reason: 当前 SessionStart 引导 LLM 去看文件系统，导致 SQLite 被绕过。
   - Alternative: 同时暴露 SQLite 和文件——两个源必然漂移。

3. **Push/Pull 边界**：
   - Push（SessionStart 自动注入）：用户画像、行为规则、项目上下文、崩溃状态（1 行）、活跃陷阱（如有）、**briefing_generate 简报（≤500 tokens）**、checkpoint 路径指针
   - Pull（MCP 按需查询）：session_list、session_mine、memory_search、stats_overview、plan_status 等 20+ 工具
   - Reason: 高频不变信息 Push 避免重复喂养；低频深层查询 Pull 避免浪费上下文。
   - Alternative: A（纯指针式，LLM 自读文件）——增加延迟，LLM 可能不读。拒绝。

4. **会话连续性方案**：采用 **B（直接注入）**。briefing_generate 自动编译的会话简报为主，.lifecycle/checkpoints/ 路径作为指针附在末尾。
   - Reason: 对标 engram/session-context/Anthropic 官方全部使用直接注入。≤500 tokens 换取启动即热状态，ROI 极高（~$0.05/月）。
   - Alternative: A（仅指针）——对标项目无一采用，LLM 可能不主动加载。

## Surfaced assumptions
- 用户曾假设"数据在 SQLite 里 = LLM 能访问"——实际需要 MCP 注册才能让工具可见
- 用户曾假设"SessionStart 注入越多越好"——实际应该精简 Push、丰富 Pull，避免上下文膨胀
- `.context/sessions/*.md` 曾被视为"备份路径"，实际成了"漂移源"

## Out of scope
- 仪表盘/可视化（P3，后续）
- AST 代码索引 + 错误 déjà-vu（P3，后续）
- 跨会话挖掘/Session Mining（P2，后续）
- CSV 导出备份

## Implementation plan
按以下顺序实施：
1. 创建 `.mcp.json` — 注册 stdio MCP server
2. 精简 `session-start.sh` — 撤销 DB 速览、会话文件列表、.context/sessions/ 目录暴露
3. 新增 Push 块 — briefing_generate 简报注入（≤500 tokens）+ checkpoint 指针
4. 验证 — 启动新会话，确认 LLM 能看到 MCP 工具 + 简报自动注入 + 不再翻文件
