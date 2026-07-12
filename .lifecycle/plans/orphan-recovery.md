# 遗孤回收 + 扩展接口（KDNA v1.3.0 + ECC 对比后修订）

## Context

上次会话完成 FastMCP 迁移后，checkpoint 指向遗孤回收。经 KDNA 审视（v1.2.0→v1.3.0）+ ECC（Affaan Mustafa, 225K⭐）对比分析后，确定：

**现在做**：遗孤回收（按 KDNA ax9/ax10 修正）+ patterns.source 列（为 instinct 预留）
**预留接口**：Hook 分级、AgentShield 桩、transcript 解析
**跳过**：Worktree 感知、子Agent 编排、跨 Harness 适配

## Part A：遗孤回收（现在做）

### KDNA v1.3.0 新增约束

- **ax9**：活跃度信号优先级 `心跳 > 最后事件时间 > 事件计数` → last_event 维度改用时间间隔
- **ax10**：自动废弃必须二阶段 `suspect → 冷却 → 二次确认 → abandon` → 加 sessions.suspect_at 列

### 改动文件（6 个）

#### A1. `mcp/orphan_ops.py` — **新建**，~140 行

独立文件（Axiom 7：session_ops.py 442行→不加功能）。

**`session_orphan_scan(project_dir, auto_abandon=False)`**

排除 newest active 后的所有 active 会话，三维加权：

| 维度 | 权重 | 信号 | 环境变量（默认值） |
|------|------|------|------|
| last_event | 0–40 | 最后事件距当前时间 | `CP_ORPHAN_TIME_NONE`(40), `CP_ORPHAN_TIME_OLD_H`(2h→30), `CP_ORPHAN_TIME_RECENT_H`(1h→15) |
| pid | 0–35 | 进程存活 | `CP_ORPHAN_PID_DEAD`(35), `CP_ORPHAN_PID_NONE`(20) |
| checkpoint | 0–25 | 检查点时间窗口 | `CP_ORPHAN_CHK_NONE`(25), `CP_ORPHAN_CHK_WINDOW_H`(2) |

**关键修正（ax9）**：事件计数降级为辅助惩罚分——有事件时用时间间隔分档，<3次+时间旧→+10惩罚。不再以 event_count 为主信号。

**`_check_checkpoint_reference(checkpoint_dir, slug, start_dt)`**

同前版，±2h 窗口 + slug 子串匹配，异常收集到 errors[]。

**二阶段废弃（ax10）**：

- `auto_abandon=True` 时：score≥60 → 设 `suspect_at=NOW()` + `decision_log(type="orphan_suspect")`（Phase 1）
- 如果已有 `suspect_at` 且超过冷却期（`CP_ORPHAN_COOLDOWN_MIN`，默认 30）→ 执行 `session_mark_abandoned()` + `decision_log(type="orphan_abandon")`（Phase 2）
- PostTool hook 收到新事件时自动清除 `suspect_at`（逆转机制——后续 PR 实现）

**decision_audit 集成**：每次 suspect 和 abandon 各写一条 decision_log。

返回格式：
```python
{"scanned": N, "sessions": [...], "recommendations": {"abandon":N,"review":N,"keep":N,"suspect":N}, "current_session": {...}, "errors": [...]}
```

#### A2. `mcp/db_core.py` — sessions 表加列

`_migrate_v5()` 函数（模式同 `_migrate_v4`）：
```sql
ALTER TABLE sessions ADD COLUMN suspect_at TEXT;
```

#### A3. `mcp/server.py` — 3 处改动

- import 加 `from orphan_ops import session_orphan_scan`
- 加 `@mcp.tool(name="session_orphan_scan", ...)` 装饰器
- CLI handlers dict 注册 + `**args` 分支

#### A4. `hooks/session-start.sh` — ~25 行

Phase B，MCP_HEALTH=ok 守卫下。逻辑同前版，但解析新字段 `suspect`：
```
WARN_DB: N 个会话新标记为 suspect（下次启动二次确认后废弃）
WARN_DB: M 个 suspect 会话已确认废弃（二阶段完成）
WARN_ORPHAN: K 个会话疑似遗留，建议 /recover
```

#### A5. `hooks/lib/_common.sh` — 阈值声明 + CP_HOOK_PROFILE 预留

追加遗孤阈值（改用时间间隔）：
```bash
CP_ORPHAN_TIME_NONE="${CP_ORPHAN_TIME_NONE:-40}"
CP_ORPHAN_TIME_OLD_H="${CP_ORPHAN_TIME_OLD_H:-2}"
CP_ORPHAN_TIME_OLD_SCORE="${CP_ORPHAN_TIME_OLD_SCORE:-30}"
CP_ORPHAN_TIME_RECENT_H="${CP_ORPHAN_TIME_RECENT_H:-1}"
CP_ORPHAN_TIME_RECENT_SCORE="${CP_ORPHAN_TIME_RECENT_SCORE:-15}"
CP_ORPHAN_EVENT_FEW="${CP_ORPHAN_EVENT_FEW:-3}"          # 辅助惩罚：事件数<此值+时间旧→+10
CP_ORPHAN_EVENT_FEW_PENALTY="${CP_ORPHAN_EVENT_FEW_PENALTY:-10}"
CP_ORPHAN_PID_DEAD="${CP_ORPHAN_PID_DEAD:-35}"
CP_ORPHAN_PID_NONE="${CP_ORPHAN_PID_NONE:-20}"
CP_ORPHAN_CHK_NONE="${CP_ORPHAN_CHK_NONE:-25}"
CP_ORPHAN_CHK_WINDOW_H="${CP_ORPHAN_CHK_WINDOW_H:-2}"
CP_ORPHAN_ABANDON_SCORE="${CP_ORPHAN_ABANDON_SCORE:-60}"
CP_ORPHAN_REVIEW_SCORE="${CP_ORPHAN_REVIEW_SCORE:-30}"
CP_ORPHAN_COOLDOWN_MIN="${CP_ORPHAN_COOLDOWN_MIN:-30}"   # 二阶段冷却期

# Hook 分级（预留，暂不实现门控逻辑）
CP_HOOK_PROFILE="${CP_HOOK_PROFILE:-standard}"  # minimal|standard|strict
```

#### A6. `tests/test_e2e.sh` — ~40 行

- 创建 orphan 会话（旧日期 + dead PID + 无事件）→ 验证 score ≥ 60，recommendation=suspect（首次）
- 创建 parallel 会话（alive PID + 有事件）→ 验证 score = 0，recommendation=keep
- 验证 errors 为空

---

## Part B：扩展接口（现在做，功能后续实现）

### B1. patterns 表加 source 列（为 instinct 预留）

**文件**：`mcp/db_core.py` `_migrate_v5()`

```sql
ALTER TABLE patterns ADD COLUMN source TEXT DEFAULT 'manual';
ALTER TABLE patterns ADD COLUMN extraction_method TEXT;
```

`source` 值域：`manual`（当前全部） / `auto`（未来 instinct 管线）
`extraction_method`：`null` / `llm_semantic` / `sql_statistical` / `transcript_parse`

**成本**：3 行 DDL，零运行时影响。**不留到未来 migration 链变长**。

### B2. AgentShield 桩（为安全扫描预留）

**文件**：`mcp/shield.py` — **新建**，~30 行

```python
def security_scan(project_dir=None, categories=None):
    """Placeholder for AgentShield-style security scanning.
    Planned rule categories: secrets(14), permissions(10), hooks(34), mcp(23), agents(25).
    Total: 102 static rules planned. Opus adversarial pipeline (Red/Blue/Auditor) deferred.
    """
    return {
        "status": "not_implemented",
        "planned_categories": ["secrets", "permissions", "hooks", "mcp", "agents"],
        "planned_rules": 102,
        "available": False,
        "eta": "v3.2.0"
    }
```

`server.py` 注册为 `@mcp.tool` + CLI handler。立即返回 planned 结构——**接口先行，实现在后**。

### B3. transcript 解析预留

**文件**：`mcp/session_ops.py`，`briefing_generate()` 函数上方加 TODO 注释

```python
# TODO(v3.2): transcript.jsonl parsing for richer session summaries
# Claude provides transcript_path in Stop hook stdin JSON.
# ECC pattern: parse last 10 user messages + tools used + files modified.
# Our advantage: events table already structured — transcript adds semantic layer.
```

---

## 实施顺序

| Step | 内容 | 文件 |
|------|------|------|
| 1 | sessions.suspect_at + patterns.source 列 | db_core.py |
| 2 | orphan_ops.py 完整实现 | orphan_ops.py（新建） |
| 3 | shield.py 桩 | shield.py（新建） |
| 4 | server.py 注册（orphan + shield） | server.py |
| 5 | session-start.sh 集成 | session-start.sh |
| 6 | _common.sh 阈值 + CP_HOOK_PROFILE | _common.sh |
| 7 | TODO 注释（transcript） | session_ops.py |
| 8 | 测试 | test_e2e.sh |
| 9 | 运行全量测试回归 | run_all.sh |

## 验证

1. `python3 mcp/server.py <test_dir> session_orphan_scan '{"auto_abandon":false}'` → JSON 含 suspect 推荐
2. `python3 mcp/server.py <test_dir> security_scan` → `"status": "not_implemented"`
3. `bash tests/test_e2e.sh` → 遗孤 section 全绿
4. `bash tests/run_all.sh` → 回归无退化
5. `sqlite3 .claude/context/memory.db "PRAGMA table_info(patterns)"` → source + extraction_method 列存在
6. 下次会话启动观察 SessionStart 输出
