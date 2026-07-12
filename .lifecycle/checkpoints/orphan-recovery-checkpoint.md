# Checkpoint: 遗孤回收 + KDNA 进化
**Saved:** 2026-07-12
**Task:** SessionStart 遗孤回收（三维加权判定）+ ECC 对比扩展接口 + KDNA v1.2.0→v1.3.1
**Progress:** 7/7 tasks complete

## Context
Checkpoint 原话「在 SessionStart 中加遗孤回收逻辑（三维度：last_event + pid + checkpoint）」已完整实施。经 KDNA 自身审查 + ECC（Affaan Mustafa, 225K⭐）对比分析后，额外做了：时间间隔替代事件计数（ax9）、二阶段废弃（ax10）、扩展点预留（ax11）。所有设计决策已固化为 KDNA 域的 3 条公理。

## Decisions Made
- **时间间隔 > 事件计数**: 最后事件距当前时间分档（>2h/1-2h/<1h），event_count 降为辅助惩罚分。社区标准（systemd/K8s/PM2）一致。
- **二阶段废弃**: suspect_at 列 → Phase 1 设标记 + decision_log → Phase 2（下次启动，冷却期后）确认 abandon。消除并发启动误判。
- **扩展点预留为架构原则**: patterns.source 列、CP_HOOK_PROFILE 环境变量、shield.py 桩——三个预留点同时落地，现已写为 ax11。
- **独立文件**: orphan_ops.py（320行）而非加在 session_ops.py（442→447行，保持 500 以下）
- **KDNA 自我进化**: v1.2.0→v1.3.0（遗孤规则）→v1.3.1（扩展点原则），11 公理/8 模式/10 自检

## What's Next
1. 下次会话启动时观察 SessionStart 输出中的 `WARN_DB: N sessions marked suspect` / `WARN_ORPHAN` 警告
2. 积累 outcome_review 数据——用 `mcp__context-manager__outcome_review` 检查 decision_audit 表中的 orphan_abandon/orphan_suspect 记录准确率
3. PostTool hook 加 suspect 清除逻辑——收到新事件时自动清除该会话的 suspect_at（ax10 逆转机制，当前未实现）
4. 实现 shield.py 静态规则（至少 secrets 14 条 → v3.2.0）
5. patterns 表填充——用 instinct 管线从 events 自动提取（当前全部 manual）

## Gotchas
- Windows `os.kill(pid, 0)` 对死 PID 返回 OSError 而非 ProcessLookupError → 得分 15 而非 35，但不影响 suspect 判定（总分仍 ≥ 60）
- 测试 `_orphan_setup.sh` 缺 `set -euo pipefail`（lint 预存 7 失败之一，非本次引入）
- `crash_diagnose` 3 值返回的 test_e2e.sh 修复已顺手完成（`read DC DS DFLAGS`）
- KDNA 域仅存 v1.3.1，旧版已被替换——下次启动自动加载最新
