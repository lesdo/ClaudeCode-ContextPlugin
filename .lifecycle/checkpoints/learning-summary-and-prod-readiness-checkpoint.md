# Checkpoint: 渐进式学习摘要 + 投产就绪评估
**Saved:** 2026-07-12T20:45
**Task:** 评估投产就绪 + 实现渐进式披露 Layer 1
**Progress:** 全部完成

## Context
用户询问插件是否可以投产使用。经过 KDNA 审查 + 安全自检 + 反馈闭环验证，确认可投产。用户指出"越用越聪明"的被动感知不足，经 grill 讨论确定渐进式披露方案：Layer 1 零 token stderr 摘要 → Layer 2 主动 MCP 查询。KDNA v1.4.0 审查通过后实现。

## Decisions Made
- **渐进式披露两层架构**: Layer 1 stderr 一行（零 token）→ Layer 2 MCP tools（stats_overview 等）。不新建东西，Layer 2 已完备
- **[learning] 格式**: 五维并列（sessions/patterns/memories/decayed/analysis），不评总分——KDNA ax3 禁止单维度坍缩
- **学习摘要放在 analytics 成功分支内**: 只在 analytics 成功时输出，失败或未触发不输出
- **Shield 安全自检 7 条告警全部非真实风险**: 5 条测试夹具 + 1 条 bare except:pass（已修复）+ 1 条 Shield 误报
- **decision_audit 为空是正常的**: 仅 1 条记忆不足以触发 decay/dedup 决策记录

## What's Next
1. 积累 20+ 会话后检查 `[learning]` 行中 patterns 和 decayed 是否产生有意义的变化趋势
2. 积累 3+ 轮 outcome_review 后评估 `CP_OPUS_INTERVAL` 阈值
3. 考虑把 `[learning]` 的指标选择做自适应（ax5 TODO：哪些指标长期无变化就停止展示）

## Gotchas
- analysis-scheduler.sh 的 CURRENT_COUNT 查询在 Windows 下依赖 `os.path.normpath` 修复混合分隔符——此修复也用于学习摘要查询
- `run_analytics` 返回 `error: null`（JSON null）导致 bash `-n` 检查误报为"分析失败: None"——已修复为过滤 None
- 手动测试 analysis-scheduler 需要 `CLAUDE_PLUGIN_ROOT` 用 `E:` 前缀而非 `/e/`——Python sqlite3 对 MSYS2 路径的 DB 文件定位不一致
- GBK 编码问题在 Python print 中文时仍存在——英文输出不受影响
