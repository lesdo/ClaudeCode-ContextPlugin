# Plan: 修复工具可发现性 + 源漂移 + 会话连续性

**日期**: 2026-07-08
**来源**: `.grill/session-continuity-and-tool-discovery.md`

## Context

三个相互关联的架构问题需要修复：
1. **L1 工具不可见**：`server.py` 有完整 MCP stdio 实现但未注册 `.mcp.json`，LLM 看不到 20+ 工具
2. **L2 源漂移**：SessionStart 暴露 `.context/sessions/` 路径，LLM 绕过 SQLite 直接读文件
3. **L3 会话冷启动**：checkpoint/briefing 存了但未注入，每次新会话需用户重新喂养上下文

## Files to modify/create

| 文件 | 操作 | 说明 |
|------|------|------|
| `.mcp.json` (项目根目录) | **新建** | stdio MCP 注册，暴露 22 个工具 |
| `hooks/session-start.sh` | **修改** | 精简输出 + 新增简报注入 |
| `mcp/server.py` | **修改** | 补齐 tool annotations (readOnlyHint) |

---

## Step 1: 创建 `.mcp.json`

参考 serena/playwright 的隐式 stdio 模式：

```json
{
  "mcpServers": {
    "context-manager": {
      "command": "python3",
      "args": ["${CLAUDE_PLUGIN_ROOT}/mcp/server.py", "--mcp"],
      "env": {
        "CLAUDE_PROJECT_DIR": "${CLAUDE_PROJECT_DIR}"
      }
    }
  }
}
```

**风险点**：`${CLAUDE_PLUGIN_ROOT}` 变量在 `.mcp.json` 中是否可用需实测。如果不可用，fallback 到绝对路径。

---

## Step 2: 精简 `session-start.sh`

删除/改写以下 4 个代码块：

### 2a. 删除 "会话记录状态" 中的文件系统操作（第 177-335 行）

- 删除：`SESSION_FILES=$(ls ...)` 文件列表
- 删除："当前会话: xxx" / "历史统计: 共 N，已记录 M" 文件计数
- 删除：`.current-session` 指针写入
- 保留：首次运行判定、崩溃诊断逻辑
- 替换为：`session_stats` MCP 查询（一行）

### 2b. 删除 "DB 速览" 输出（第 364-367 行）

`echo "DB 速览: ${DB_SESSIONS} 会话, ${DB_MEMS} 记忆"` 删除。

### 2c. 替换 "会话简报 (DB)" 为精简版（第 352-361 行）

```bash
BRIEFING=$(bash "$MCP_CLI" "$PROJECT_DIR" briefing_generate '{"max_tokens":500}' 2>/dev/null)
if [ -n "$BRIEFING" ] && [ "$BRIEFING" != "null" ]; then
  echo "=== 上次会话 ==="
  echo "$BRIEFING"
  LATEST_CHECKPOINT=$(ls -t .lifecycle/checkpoints/*.md 2>/dev/null | head -1)
  if [ -n "$LATEST_CHECKPOINT" ]; then
    echo "深度恢复: Read $LATEST_CHECKPOINT 或调用 session_mine"
  fi
fi
```

### 2d. 清理所有 `.context/sessions/` 的对外输出

---

## Step 3: 补齐 MCP tool annotations

给 `mcp/server.py` 的 TOOLS 字典中只读工具添加：
```python
"annotations": {
    "readOnlyHint": True,
}
```

---

## Step 4: 验证

每步完成后立即测试：

1. **`.mcp.json`**：启动 Claude Code，确认 22 个工具可见，无连接错误
2. **session-start.sh**：启动新会话，确认不再暴露文件系统路径，有简报块
3. **端到端**：说 "看看上次会话做了什么"——LLM 应调用 MCP 工具而非 `ls` + `Read`

## 回滚方案

每个修改独立、可逆：
- `.mcp.json` 删除即可回滚
- `session-start.sh` 通过 `git checkout` 回滚
- tool annotations 不影响功能
