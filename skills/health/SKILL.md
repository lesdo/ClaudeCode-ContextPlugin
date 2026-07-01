---
name: health
description: 系统健康全量检查 — 架构底线验证、路径一致性、Hook 注册状态、备份新鲜度
---

# 系统健康检查

执行 `${CLAUDE_PLUGIN_ROOT}/scripts/check-health.sh` 进行全量健康扫描。

检查项：
- 架构底线（rules.redline）合规性
- Hook 脚本语法 + 完整性
- settings.json / hooks.json 一致性
- 备份新鲜度

用法: `/context-manager:health`
