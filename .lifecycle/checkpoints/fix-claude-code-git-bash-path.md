# Checkpoint: 修复 CLAUDE_CODE_GIT_BASH_PATH 启动崩溃
**Saved:** 2026-07-08T23:59+08:00
**Task:** 诊断并修复 CMD 终端 `Claude` 启动时 `cut: command not found` → `CLAUDE_CODE_GIT_BASH_PATH path ":"` 崩溃
**Progress:** 已完成

## Context
用户在 CMD 窗口执行 `Claude`，`claude.bat`→`claude-monitored.sh` 调用链中 bash 找不到 `cut`/`tr` 命令，导致 Git Bash 路径检测失败，赋值为孤立冒号 `:`，Claude Code 无法定位 bash 路径。

## Decisions Made
- **根因**: 无法精确复现（穷举了 env -i / norc / MSYS2_PATH_TYPE 等所有组合），结论为该 CMD 会话的一次性 PATH 状态异常。但代码的脆弱性是确定的——启动路径依赖外部命令做字符串处理。
- **修复方案**: 全部改用 bash 4.0+ 内置参数展开 (`${:}`, `${^^}`, `${,,}`, `${/}` , `[[ =~ ]]`)，零外部命令依赖
- **重构方式**: 抽出 `_path_to_unix()` 纯 bash 函数，替换 4 处 `sed|tr|tr` 管道调用
- **踩坑已沉淀**: `.lifecycle/lessons/bash.md` — "启动关键路径避免外部命令"

## What's Next
1. 实际测试：在新 CMD 窗口执行 `Claude` 确认不再崩溃
2. 考虑 `claude.bat` 主动设置 `CLAUDE_CODE_GIT_BASH_PATH` 作为双重保险

## Gotchas
- `_path_to_unix` 使用 `${var,,}` 全小写转换（bash 4.0+），需确认所有目标环境 bash >= 4.0
- 原 `sed|tr` 链条也全小写了路径，行为已保持一致
- 如果 PATH 问题在其他 hook 脚本（`session-start.sh` 等）也出现过，同样应审查外部命令依赖
