# ClaudeCode-ContextPlugin

> Claude Code 会话生命周期管理 Plugin — 集成 Continuum 崩溃恢复 + 取证日志 + 红线守卫 + 备份归档

## 架构

```
ClaudeCode-ContextPlugin/
├── .claude-plugin/plugin.json    ← 元数据（name, version, credits）
├── hooks/
│   ├── hooks.json                ← 3 事件 8 脚本注册
│   ├── session-start.sh          ← SessionStart: 上下文注入（画像+规则+项目）
│   ├── post-tool.sh              ← PostToolUse: 取证日志(.log) + 红线守卫
│   ├── exit-check.sh             ← Stop: 会话完整性验证
│   └── lib/_common.sh            ← 共享库（路径+备份+索引）
├── scripts/
│   ├── detect-active-work.sh     ← Continuum: 启动时检测活跃工作
│   ├── track-file-change.sh      ← Continuum(适配): 追踪文件变更
│   ├── track-commit.sh           ← Continuum(适配): 追踪 git commit
│   ├── wip-auto-save.sh          ← Continuum: 每10次编辑自动 stash
│   ├── auto-checkpoint.sh        ← Continuum: 会话结束自动检查点
│   ├── claude-monitored.sh       ← 包装器: 崩溃监视+备份提醒+会话文件
│   ├── backup-claude.sh          ← 备份: ~/.claude/ tar.gz 快照
│   ├── check-health.sh           ← 健康检查: hooks/skills/redline 扫描
│   ├── session-archive.sh        ← 归档: 30天旧会话移入 archive/
│   └── claude-exit.sh            ← 退出: taskkill 清理僵尸进程
└── skills/
    ├── init/SKILL.md             ← Continuum: 初始化 .lifecycle/
    ├── plan/SKILL.md             ← Continuum: 任务规划
    ├── checkpoint/SKILL.md       ← Continuum: 认知检查点
    ├── resume/SKILL.md           ← Continuum: 续接工作
    ├── recover/SKILL.md          ← Continuum: 崩溃恢复
    ├── reflect/SKILL.md          ← Continuum: 经验提取
    ├── align/SKILL.md            ← Continuum: 项目健康评分
    ├── backup/SKILL.md           ← 我们的: 触发备份
    ├── health/SKILL.md           ← 我们的: 健康检查
    └── session/SKILL.md          ← 我们的: 会话管理
```

## 鸣谢

- [Continuum](https://github.com/marylin/Continuum) (MIT) by Marylin Alarcon — 崩溃恢复 + 生命周期管理核心
