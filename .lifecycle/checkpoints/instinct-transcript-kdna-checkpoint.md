# Checkpoint: instinct管线 + transcript解析 + KDNA进化
**Saved:** 2026-07-12T16:30
**Task:** 让插件变聪明的三个功能 + 错误提炼到KDNA
**Progress:** 全部完成

## Context
在遗孤回收 (v3.1.0) 基础上，本会话实现了 instinct 管线（events→patterns 自动提取）、transcript 解析（Stop hook→context_summary→简报增强）、以及将本会话暴露的 6 个错误提炼到 KDNA v1.4.0。同时修复了 4 个预存 bug（session_index 残留、compact 路径不匹配、assert_contains 误用、WAL 写入死锁）。

## Decisions Made
- **instinct 两阶段设计**: conn 块内只读收集 → 退出块后写库。避免嵌套 get_db() WAL 死锁（risk5）
- **patterns 用英文存储**: 标题/描述用英文（避免 GBK 乱码），SQL 聚合零 token 成本
- **transcript 走 context_summary 列**: 不新建表，直接在 sessions 表已有列上存储。简报增强用现有管道
- **KDNA 直接更新到 v1.4.0**: 不等"下次维护"——unpack→改 payload→pack→install，一步到位
- **Hook fail-open 是设计决策不是 bug**: `set -uo pipefail`（无 -e）保证 hook 永不中断主进程。lint 太死板

## What's Next
1. 下次会话启动观察 SessionStart 输出中的 briefing "Current" section（transcript 上下文注入）
2. 积累几轮 session 后跑 `run_analytics` → 观察 auto patterns 质量
3. 安全扫描剩余 88 条规则（permissions/hooks/mcp/agents）——接口已预留
4. Opus 对抗式审查管道 —— token 消耗大，需慎重设计触发条件

## Gotchas
- KDNA compact profile 3000 token 限制：sc11/risk5/pat9 在 compact 渲染中被裁剪，full profile 完整
- 旧版 KDNA v1.3.1 已移除，下次自动加载 v1.4.0
- memory-capture.sh 依赖 stdin JSON 中有 `transcript_path`——Claude Code 是否每次都传待观察
- Windows GBK 编码在 Python print 时仍可能乱码，用英文存储数据规避
