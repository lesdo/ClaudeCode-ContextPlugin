# Checkpoint: outcome_review 缺口修复 + shield 扩展预留 + Opus 审查管道
**Saved:** 2026-07-12T19:00
**Task:** 全部完成 — outcome_review 自动触发 + 47 静态规则 + Opus 对抗式审查管道 + KDNA 审查改进
**Progress:** 5/5 + KDNA 审查改进

## Context
修复了唯一真实缺口（outcome_review 自动触发），逐个实现了 shield.py 4 个预留类别（47 规则），建立了基于确定性调度的 Opus 对抗式审查管道（adversarial.py）。KDNA 审查发现 2 个 ax6 静默异常和 ax4 阈值无理由注释，已全部修复。

## Decisions Made
- 审查管道执行模型：scheduler 确定性调度 → Agent 执行 → opus_review_submit 提交（不走 Agent 触发路径）
- 静态规则数从 aspirational 102 精简为 47 高信号规则
- shield.py 重构为通用 `_scan_category()` 架构
- KDNA 审查后：git 操作加 stderr 诊断，阈值加"为什么是这个数"注释，留 ax5 自适应调优 TODO

## What's Next
1. 积累 20+ 会话后观察 outcome_review 输出
2. 积累 3+ 轮 opus_review 后评估 CP_OPUS_INTERVAL 阈值
3. shield.py 再增规则 → 拆分为 mcp/shield_rules/ 目录（ax7）
4. adversarial.py prompt 模板 >100 行时可提取到独立文件

## File Changes (8 files)
- mcp/shield.py: 237→379 行, v1.0.0, 5 类别 47 规则
- mcp/adversarial.py: 新文件 331 行, Red/Blue/Auditor 管道
- mcp/db_core.py: SCHEMA_VERSION 5→6, +review_pipeline_state 表
- mcp/server.py: +3 MCP tools + CLI handlers
- hooks/analysis-scheduler.sh: +outcome_review +opus_review_prep 触发
- hooks/lib/_common.sh: +3 阈值变量（含理由注释）

## Gotchas
- 状态文件 6 行格式（analytics×2 + review×2 + opus×2）
- adversarial.py 的 git diff 基于 HEAD~1，初始提交会失败（已有 stderr 诊断）
- 审查管道的 Phase B（Agent 执行）依赖 Agent 主动调用 opus_review_submit
