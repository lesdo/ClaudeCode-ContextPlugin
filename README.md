# ClaudeCode-ContextPlugin v3.2

> **Claude Code 每次 compaction 后都忘了你在做什么？** 本插件在 compaction 前自动保存完整会话状态，重启后恢复——你的 AI 永远不会再"失忆"。

## Before / After

```
# 没有插件 — compaction 后从零开始
❯ claude
AI: Hi! How can I help you today?

# 有插件 — compaction 后恢复上下文
❯ claude --continue
AI: 欢迎回来。上次我们在做登录模块的 OAuth2 集成，
    进度: ✅ 数据库 schema · ✅ 登录页面 UI · 🔄 token 刷新
    刚才在修改 src/auth/oauth.ts 的 refreshToken 函数。
    要继续吗？
```

## 一行安装

```bash
# 1. 添加 marketplace
/plugin marketplace add lesdo/ClaudeCode-ContextPlugin

# 2. 安装
/plugin install claudecode-context-plugin
```

安装后重启 Claude Code 即生效。不需要 API key，不联网，纯本地运行。

## 它做什么

| 时刻 | 自动动作 |
|------|---------|
| 会话启动 | 注入项目简报 + 崩溃诊断 + 上次未完成任务 |
| 每次工具调用 | 记录事件（文件/命令/git）+ 红线安全扫描（47 规则） |
| **compaction 前** | 保存完整会话快照到 SQLite |
| **compaction 后** | 自动恢复上下文——从哪里断从哪里续 |
| 会话结束 | 捕获记忆 + 衰减清理 + 生成检查点 |
| 崩溃后 | 遗孤扫描 + 状态恢复 |

## 内置 Skills（9 个）

| Skill | 用途 |
|-------|------|
| `checkpoint` | 保存思维快照——做什么、为什么、下一步 |
| `resume` | 从上次中断处继续工作 |
| `recover` | 从崩溃/中断会话中恢复 |
| `reflect` | 完工后提取经验教训并归档 |
| `plan` | 创建结构化实施计划 |
| `init` | 为新项目引导文档和生命周期 |
| `align` | 审计项目结构、文档健康度 |
| `health` | 系统全量健康检查 |
| `session` | 查看会话历史、归档管理 |

## 架构

```
6 Hooks (全生命周期)
  SessionStart → PostToolUse → Stop → PreCompact → PostCompact → 崩溃恢复
         │            │          │         │            │
         ▼            ▼          ▼         ▼            ▼
  ┌──────────────────────────────────────────────────────────┐
  │              SQLite (WAL + FTS5 全文搜索)                 │
  │  8 表: sessions · events · memories · decisions          │
  │        patterns · preferences · audits · checkpoints      │
  └──────────────────────────────────────────────────────────┘
```

- **零外部依赖**：不调外部 API，不联网，本地 SQLite
- **不会丢失上下文**：PreCompact 快照 → PostCompact 自动恢复
- **安全防线**：AgentShield v1.0 — 每次工具调用后扫描 47 条安全规则
- **渐进式披露**：stderr 一行 `[learning]` 零 token 消耗，需要深入时 MCP 查询

## 要求

- Claude Code v2.0+
- Python 3.9+
- Git Bash (Windows) / bash (Linux/macOS)

## 许可

MIT · [lesdo/ClaudeCode-ContextPlugin](https://github.com/lesdo/ClaudeCode-ContextPlugin)

## 鸣谢

- [Continuum](https://github.com/marylin/Continuum) (MIT) by Marylin Alarcon — 项目工作流层参考
