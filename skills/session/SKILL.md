---
name: session
description: 会话管理 — 查看当前项目会话历史、手动触发月归档、检查会话索引一致性
---

# 会话管理

查看当前项目会话状态、手动触发月归档、检查会话索引。

命令：
- `list` — 列出当前项目最近会话文件
- `archive` — 手动触发 30 天归档（`${CLAUDE_PLUGIN_ROOT}/scripts/session-archive.sh`）
- `index` — 检查 `.session-index` 一致性（行数 vs 文件数）

用法: `/context-manager:session [list|archive|index]`
