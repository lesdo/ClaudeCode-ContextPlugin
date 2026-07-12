# Checkpoint: KDNA 驱动插件改造（五轮）
**Saved:** 2026-07-11T23:00:00+08:00
**Task:** 用 KDNA 判断层驱动 ContextPlugin v3.0 代码质量提升
**Progress:** 5/7 轮完成（剩余：ax5 反馈闭环基础设施）

## Context
用自建的 `@lesdo/context-plugin-judgment` KDNA 资产（7 公理）逐轮审查和改造插件代码。每轮：对照公理找违规→改代码→测试→更新公理。已验证 KDNA 作为设计工具的定位正确——运行时不应依赖它。

## Decisions Made
- KDNA = 设计工具，不是运行时依赖：5 次 KDNA CLI 操作中有 3 次因 CLI 本身不成熟出错，证明嵌入 hook 管线会引入脆弱性
- 公理来源：审计代码反模式→反转→归纳为公理。不是凭空写的，是从现有代码的问题中提炼的
- 阈值全部用环境变量覆盖（CP_*），遵循 bash 层面已有的模式
- 文件复杂度上限（ax7）来自实战发现——session_ops.py 690 行是便利性累积的活证据
- 拆分文件不改调用方接口——耦合足够松才拆得动

## What's Next
1. 第 5 轮：ax5 反馈闭环——建 decision_audit 表 + outcome_review 机制
2. 第 6 轮：全局 ax6 异常可见性审查——扫描所有 except:pass 和 2>/dev/null
3. 第 7 轮：`server.py` 工具注册部分的硬编码审查 + KDNA 公理稳定化

## Gotchas
- KDNA CLI v0.29.0: `kdna pack` 对自建源目录有隐式校验（用 demo 目录当基底可绕过）；checksums 不要自建；Windows 下 PATH 不传给 Python subprocess
- 拆文件后 memory_ops.py 413 行——仍在 500 线上限内，但已接近警戒线
- decay_run 从批量 UPDATE 改为逐行计算——对大量记忆可能变慢，但当前数据量小，暂不优化
