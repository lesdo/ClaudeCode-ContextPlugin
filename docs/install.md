# ClaudeCode-ContextPlugin v3.0 — 安装指南

> 5 分钟部署：`git clone` → `claude plugin install` → 完成。

## 前置条件

- Claude Code CLI 已安装并认证
- `bash` (Linux/Mac 自带, Windows 需 Git Bash)
- `python3` + pip (MCP 管线)
- 可选: `jq` (部分脚本 fallback 时使用)

## 安装

### 1. 克隆仓库

```bash
git clone https://github.com/lesdo/ClaudeCode-ContextPlugin.git ~/claude-context-plugin
```

### 2. 安装 Python 依赖

```bash
pip install -r ~/claude-context-plugin/mcp/requirements.txt
# 或精确版本:
# pip install -r ~/claude-context-plugin/mcp/requirements.lock
```

### 3. 注册为 Plugin

```bash
claude plugin marketplace add ~/claude-context-plugin
claude plugin install claudecode-context-plugin --scope user
```

或项目级安装（团队成员共享）：
```bash
claude plugin install claudecode-context-plugin --scope project
```

### 4. 初始化全局配置 (首次)

创建 `~/.claude/profile/user.md`:
```markdown
# 用户画像
## 角色
（你的角色、负责领域）
## 技能领域
（擅长的技术栈）
## 工作偏好
- 沟通语言：简体中文
```

创建 `~/.claude/profile/rules.md`:
```markdown
# 行为规则
## 文档按需消费
只加载与任务相关的文档，不全文通读。
## 冲突必报
用户要求与架构原则冲突时必须当场指出。
```

创建 `~/.claude/.backup-config`:
```bash
backup_check_min_interval_hours=6
backup_expire_days=7
backup_check_on_start=yes
BACKUP_DIR="$HOME/ClaudecodeBackup"
```

### 5. 验证

启动 Claude Code 任意项目，应看到：
```
=== 用户画像 ===
...
=== 行为规则 ===
...
=== 项目上下文 ===
...
=== 会话简报 (DB) ===
...
DB 速览: 0 会话, 0 记忆
```

## Hook 清单 (自动注册)

| 事件 | 脚本 | 功能 |
|------|------|------|
| SessionStart | `session-start.sh` | 画像+规则+简报+崩溃诊断 |
| PostToolUse | `post-tool.sh` | 事件记录(SQLite)+红线守卫 |
| Stop | `memory-capture.sh` | 记忆捕获+衰减 |
| Stop | `auto-checkpoint.sh` | 自动检查点 |
| PreCompact | `pre-compact.sh` | 简报快照 |
| PostCompact | `post-compact.sh` | 上下文恢复 |

## 测试

```bash
cd ~/claude-context-plugin
bash tests/run_all.sh          # 功能测试 (111 tests)
bash scripts/audit-plugin.sh   # 架构审计 (10 维度)
```

## 故障排查

| 症状 | 检查 |
|------|------|
| 无 SessionStart 输出 | `claude plugin list` 确认已安装 |
| DB 速览显示 0 | `pip list \| grep mcp` 确认 Python 依赖 |
| SQLite 管线不可用 | `python3 -c "import mcp"` 验证 |
| 中文乱码 | `export PYTHONIOENCODING=utf-8` |
