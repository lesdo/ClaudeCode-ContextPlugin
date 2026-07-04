# ClaudeCode-ContextPlugin v3.0

> Claude Code 会话生命周期管理 Plugin — SQLite 结构化存储 + 6 Hook 全生命周期 + 崩溃恢复 + 红线守卫

## 架构

```
ClaudeCode-ContextPlugin/
├── .claude-plugin/plugin.json    ← 元数据 (v3.0.0)
├── hooks/
│   ├── hooks.json                ← 6 事件 7 脚本注册
│   ├── session-start.sh          ← SessionStart: 画像+规则+项目+简报+崩溃诊断
│   ├── post-tool.sh              ← PostToolUse: 事件(SQLite)+红线守卫
│   ├── memory-capture.sh         ← Stop: 记忆捕获+衰减+清理
│   ├── pre-compact.sh            ← PreCompact: 简报快照→DB+文件
│   ├── post-compact.sh           ← PostCompact: 文件→上下文恢复
│   └── lib/
│       └── _common.sh            ← 共享库: PATH+备份+索引+crash_diagnose
├── mcp/                          ← SQLite MCP Server (Python)
│   ├── server.py                 ← CLI + MCP/stdio 入口
│   ├── db_core.py                ← Schema (8表+FTS5+WAL) + 连接管理
│   ├── session_ops.py            ← 会话 CRUD (创建/终结/事件/编译)
│   ├── memory_ops.py             ← 记忆/决策/偏好 CRUD + 衰减
│   ├── vectors.py                ← TF-IDF + sqlite-vec 混合搜索
│   ├── migrate.py                ← .md/.log → SQLite 迁移
│   ├── demo.py / stress_test.py  ← 演示+压力测试
│   └── requirements.txt          ← Python 依赖
├── scripts/
│   ├── claude-monitored.sh       ← 包装器: 骨架→监视→编译→退出
│   ├── mcp-cli.sh                ← bash↔Python CLI 桥接
│   ├── check-health.sh           ← 健康检查: 全量系统验证
│   ├── session-archive.sh        ← 归档: 30天旧会话→archive/
│   ├── claude-exit.sh            ← 退出: taskkill 清理
│   ├── auto-checkpoint.sh        ← Stop: 自动检查点
│   ├── audit-plugin.sh           ← 架构自审计: 10维度报告
│   └── validate.sh               ← SKILL.md 验证
├── skills/                       ← 9 个 skill (7 Continuum + 2 自建)
├── tests/                        ← L2 测试框架 (111 tests)
├── CLAUDE.md                     ← 本文件
└── .gitignore
```

## 存储迁移 (A→D 全部完成)

| Phase | 内容 | 状态 |
|-------|------|:--:|
| A | .md + SQLite 双写 | ✅ |
| B | .log → SQLite events, post-tool.sh SQLite优先 | ✅ |
| C | .md 编译化, bash 停止 sed 注入 | ✅ |
| D | .session-index 移除, SQLite 替代 | ✅ |

## 测试

```bash
bash tests/run_all.sh       # 功能测试 (111 tests)
bash scripts/audit-plugin.sh # 架构审计 (10 维度)
```

## 鸣谢

- [Continuum](https://github.com/marylin/Continuum) (MIT) by Marylin Alarcon — 项目工作流层 (skills/auto-checkpoint)
