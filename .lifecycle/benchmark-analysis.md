# 七大对标项目深度分析

**分析日期**: 2026-07-08
**目的**: 为 ClaudeCode-ContextPlugin v3.0 → v4.0 演进提供设计参考

---

## 一、项目总览

| 项目 | Stars | 语言 | 最后更新 | 维护度 | 存储 | Hook 数 | License |
|------|:--:|------|----------|:--:|------|:--:|:--:|
| [claude-engram](https://github.com/20alexl/claude-engram) | 17 | Python | 2026-07-01 | 9.6 | SQLite+向量 | 8+ | MIT |
| [context-analyzer](https://github.com/manavgup/context-analyzer) | 3 | Python/HTML | 2026-06-13 | 7.2 | SQLite 9表 | 10 | 无 |
| [hookwatch](https://github.com/PabloLION/claude-hookwatch) | 2 | TypeScript | 2026-03-22 | 5.5 | SQLite(bun) | 18 | MIT |
| [session-context](https://github.com/sethyanow/session-context) | 3 | TypeScript | 2026-06-30 | 8.1 | 文件系统 | 5 | MIT |
| [gaslighter](https://github.com/LarryGF/gaslighter) | 5 | Python | 2026-07-07 | 9.9 | N/A | 1 | MIT |
| [SkillScope](https://github.com/joeykokinda/SkillScope) | 0 | JavaScript | 2026-06-11 | 8.6 | SQLite | 4 | MIT |
| [claude-dev-insights](https://github.com/kanopi/claude-dev-insights) | 5 | Shell | 2026-01-03 | 3.6 | CSV | 3 | 无 |
| **本插件 v3.0** | — | Bash+Python | 当前 | — | SQLite 8表+FTS5 | 6 | — |

---

## 二、逐个深度分析

### 🥇 claude-engram — 最值得对标

**定位**: 记忆系统做到极致的 Claude Code 插件，v4.0 蓝本。

**核心架构**:
```
Hooks (remind.py) → 实时拦截
    ├── PreToolUse(Edit): 代码索引摘要 + 历史错误注入
    ├── PostToolUseFailure: 错误déjà-vu → 自动注入过去修复方案
    ├── PreCompact/PostCompact: checkpoint 保存/恢复
    └── SessionEnd: 触发后台 Session Mining

Session Mining (mining/)
    ├── JSONL 解析器 → 结构化提取器 → 搜索索引
    ├── 跨会话模式检测（编辑循环、重复错误、相关文件）
    └── 首次安装追溯挖掘全部历史会话

MCP Server (server.py)
    ├── memory: 存储/搜索/归档
    ├── session_mine: 跨会话搜索（按 kind: decision/next-step/error）
    ├── checkpoint_save/restore/list
    └── deps_map(symbol="X"): AST 代码索引查询

Scorer (scorer_server.py) — TCP localhost 持久化语义编码器 (~1.1GB RAM)
Embed Worker (embed_worker.py) — GPU 批量嵌入，完成后退出释放 VRAM
```

**记忆模型**: Episodic / Semantic / Procedural 三级 + 热度冷热分层
- rules / manual mistakes: 永不过期
- auto-captured mistakes: 自动归档

**检索性能**: 43ms/查询，112ms 跨会话（7,310+ chunks）

**Benchmarks**:
- LongMemEval: 0.966 R@5 / 0.982 R@10
- 决策捕获精度: 97.8%
- 错误捕获召回: 100%
- 压缩生存: 6/6
- 多项目隔离: 11/11

**可借鉴清单**:

| # | 功能 | 实现要点 | 本插件差距 |
|---|------|----------|:--:|
| 1 | 编辑循环检测 | 同文件 3 次编辑无进展 → 告警（per-session state） | ❌ |
| 2 | 错误 déjà-vu | 失败匹配历史错误 → 注入过去修复方案 | ❌ |
| 3 | TDD 感知 | 测试失败 ≠ 代码错误，不污染 mistake store | ❌ |
| 4 | 代码索引 (AST) | 编辑前自动注入模块摘要 + importers + 历史错误 | ❌ |
| 5 | 跨会话挖掘 | 每次 SessionEnd 后自动后台挖掘全量历史 | ❌ |
| 6 | 注入精度反馈 | 追踪注入后测试是否通过 → 调节注入置信度(0.8-1.2) | ❌ |
| 7 | 子项目隔离 | 项目 A 会话不看到项目 B 错误 | ✅ 已有 |
| 8 | 错误因果归因 | "struggle" 要求错误追溯到具体文件 | ❌ |

---

### 🥈 context-analyzer — SQLite 分析粒度标杆

**定位**: 上下文窗口的"性能剖析器"。

**核心架构**:
```
Hooks (10 事件) → JSONL trace 文件 → SQLite 9 表 → FastAPI Dashboard + MCP Server
```

**9 表 Schema**（每会话 2900+ 行）:
`sessions` / `api_calls` / `blocks` / `turns` / `hook_events` / `subagents` / `subagent_api_calls` / `tool_result_offloads`

**真实数据发现**:

| 发现 | 数值 | 对本插件启示 |
|------|------|-------------|
| 成本随上下文缩放 | 4.3x（63K→721K） | 加"成本效率"维度 |
| 工具 I/O 占比 | 60%+ | 追踪 tool_input/output 体积 |
| 上下文过期速度 | 30% 在 5 轮内过期 | 衰减模型参考 |
| 缓存命中率 | 96-98% | 加"缓存效率"监控 |
| 成本阈值 | 超 50% 上下文后飙升 | 加预警 |

**可借鉴清单**:
1. 预算线 + 危险带可视化（200K/500K/700K/1M）
2. Token 构成饼图（Tool I/O vs Conversation vs System prefix）
3. 跨会话散点图（成本/Call vs 峰值上下文）
4. 消息检查器（可折叠内容块，按 turn 回放）

---

### 🥉 hookwatch — Hook 可观测性标杆

**定位**: 全 18 个 Hook 事件的调试利器。

**核心特色**:

| 维度 | 实现 |
|------|------|
| 事件覆盖 | 全部 18 个 Hook（含 InstructionsLoaded SDK 独有） |
| 校验 | Zod 运行时校验所有 18 种 stdin 负载 |
| 耗时追踪 | `hook_duration_ms` — **本插件应加此字段** |
| 存储 | `bun:sqlite` + WAL，零外部依赖 |
| UI | SSE 实时推送 + localhost:6004 |
| Wrap 模式 | 捕获子进程 stdin/stdout/stderr 与 Hook 事件关联 |

**Schema（单表）**:
```
id | timestamp | event | session_id | cwd | tool_name | session_name
hook_duration_ms | stdin | wrapped_command | stdout | stderr
exit_code | hookwatch_log
```

**可借鉴清单**:
1. `hook_duration_ms` — 每个 Hook 加执行耗时统计
2. `hookwatch_log` — 内部诊断日志（`[error]`/`[warn]` 前缀）

---

### ④ gaslighter — Stop Hook 做到极致

**定位**: Claude 说"做好了"时拦住它，重新验证需求。

**三种模式**:

| 模式 | 机制 | 上限 | 效果 |
|------|------|:--:|------|
| lite | 软提示，不可见 | 3/会话 | +1.5% correctness |
| full | 硬阻塞，必须重新验证 | 无限 | +4.2% correctness，+45% turns |
| smart | Haiku 判断是否有遗漏再阻塞 | 2/会话 | 实验中 |

**核心发现**（1090 个测试单元）:
> 同样的"重读验证"文本塞进 system prompt 反而比什么都不做更差。
> **时机 > 措辞**——Hook 在模型宣布完成那一刻的打断才是有效的。

**可借鉴清单**:
- memory-capture.sh（Stop Hook）加"任务完成度校验"开关
- 低成本方案：检查 plan 中 `[ ]` 是否有残留

---

### ⑤ session-context — 压缩生存 + 标记嵌入

**定位**: `<!-- session:abc123 -->` 标记在压缩后存活。

**可借鉴清单**:
- post-compact.sh 恢复机制加"压缩存活标记"嵌入到消息中
- Rolling checkpoint + 显式 handoff 双模式

---

### ⑥ SkillScope — Skill 使用分析

**定位**: Google Analytics for Skills。

**可借鉴清单**:
- 7 维分析加"Skill 使用分析"作为第 8 维
- "死权重"检测：安装但从未触发的 Skill

---

### ⑦ claude-dev-insights — 29 数据点/会话

**定位**: CSV 存储 + Google Sheets 同步 + `#ticket:` `#topic:` 标记约定。

**可借鉴清单**:
- CSV 导出备份方案
- `#ticket:` 标记自动关联到 event 表

---

## 三、关键维度横向对比

```
                     本插件  engram  ctx-analyzer  hookwatch  gaslighter
                     ──────  ──────  ────────────  ─────────  ─────────
记忆系统             ⭐⭐⭐⭐  ⭐⭐⭐⭐⭐  ⭐⭐          ⭐         ⭐
Hook 覆盖            6/18    8+/18    10/18         18/18      1/18
崩溃恢复             ⭐⭐⭐⭐⭐  ⭐⭐⭐     ⭐⭐          ⭐⭐        ⭐
SQLite 分析          8 表    多表      9 表          单表        N/A
跨会话挖掘           ❌       ✅        ✅            ❌          N/A
代码索引 (AST)       ❌       ✅        ❌            ❌          N/A
编辑循环检测         ❌       ✅        ❌            ❌          N/A
错误 déjà-vu         ❌       ✅        ❌            ❌          N/A
TDD 感知             ❌       ✅        ❌            ❌          N/A
注入精度反馈         ❌       ✅        ❌            ❌          N/A
上下文预算分析       ❌       ❌        ✅            ❌          ❌
仪表盘               ❌       ❌        ✅            ✅(SSE)     ❌
耗时统计             ❌       ❌        ❌            ✅          N/A
红线守卫             ✅       ❌        ❌            ❌          ❌
记忆衰减             ✅       ✅        ❌            ❌          ❌
任务验证 (Stop)      ❌       ❌        ❌            ❌          ✅
压缩生存             ✅       ✅        ✅            ❌          ❌
子项目隔离           ✅       ✅        ❌            ❌          N/A
```

## 四、本插件独特优势

1. ✅ **红线守卫** — 配置保护，防误改 `~/.claude/`
2. ✅ **崩溃恢复** — `crash_diagnose` + `.crash` 残留检测
3. ✅ **7 维行为画像** — 自动化定量分析 + user.md 同步
4. ✅ **记忆衰减** — Type-aware 衰减（episodic 7天/semantic 30天/pattern 永久）
5. ✅ **三路冗余** — SQLite + .md + .log

## 五、建议实现路线

| 优先级 | 做什么 | 学谁 | 预估复杂度 |
|:--:|------|------|:--:|
| P0 | Hook 耗时统计（每个 Hook 加 `hook_duration_ms`） | hookwatch | 低 |
| P0 | 上下文预算分析（追踪 tool I/O 体积，算成本效率） | context-analyzer | 中 |
| P1 | 编辑循环检测（同文件 3+ 次编辑无进展） | engram | 中 |
| P1 | Stop 任务验证（检查 plan 残留 `[ ]`） | gaslighter | 低 |
| P2 | Skill 使用分析（第 8 维） | SkillScope | 低 |
| P2 | 跨会话挖掘（Session Mining） | engram | 高 |
| P3 | 仪表盘（FastAPI + 前端） | context-analyzer | 高 |
| P3 | AST 代码索引 + 错误 déjà-vu | engram | 高 |
