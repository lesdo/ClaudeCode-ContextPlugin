# Checkpoint: fix-wrapper-startup-bugs
**Saved:** 2026-07-08T21:40:00+08:00
**Task:** 修复 claude-monitored.sh 两个启动阻塞 Bug
**Progress:** 2/2 完成

## Context
`Claude` 命令连续 4 次启动失败。第一个 Bug 阻塞启动（CLAUDE_CODE_GIT_BASH_PATH 路径错误），第二个 Bug 每次退出时报 command not found 但不影响功能。两个都已在 claude-monitored.sh 中修复。

## Decisions Made
- CLAUDE_CODE_GIT_BASH_PATH 检测：直接检查 C:/D: 盘 Git 安装路径，而非依赖 cygpath 等外部工具 — 更简单、零依赖
- wrapper_exit_cleanup：定义在 claude-monitored.sh 末尾而非创建新文件 — 避免文件碎片化，133 行脚本不需要拆两个文件

## What's Next
1. 用户启动 `Claude` 验证两个修复均生效
2. 如仍有问题，检查 D:/Program Files/Git/usr/bin/bash.exe 是否存在

## Gotchas
- Git Bash 路径含空格（`Program Files`），路径转换时注意引号
- `.exe` 后缀在 Windows 上是必须的，Node.js 无法识别无后缀的可执行文件
