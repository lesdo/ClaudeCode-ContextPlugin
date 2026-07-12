# Bash Gotchas

- [2026-07-04] MSYS2 Git Bash 中 `${3:-{}}` 嵌套花括号解析异常（输出双 `}}` 而非单 `}`）。用 `if [ -n "${3:-}" ]; then ARGS="$3"; else ARGS="{}"; fi` 替代。
- [2026-07-04] `set -euo pipefail` 与空目录 glob 不兼容：`ls "$DIR"/*.md` 在无文件时触发 `set -e` 退出。加 `|| true` 兜底。`set -u` 要求所有变量使用前初始化（`LATEST=""`）。
- [2026-07-04] Windows Python `print()` 输出 `\r\n`，bash `read` 读到的字符串带 `\r` 后缀。用 `tr -d '\r'` 清理。
- [2026-07-08] **启动关键路径避免外部命令** — `claude-monitored.sh` 在检测 `CLAUDE_CODE_GIT_BASH_PATH` 时使用 `cut` + `tr` 做路径字符串处理。CMD→.bat→bash.exe 调用链中，非交互式 bash 可能在 PATH 未正确初始化时找不到 `cut`/`tr`，导致变量被赋为孤立冒号 `:`，Claude Code 无法定位 Git Bash 路径（报 `CLAUDE_CODE_GIT_BASH_PATH path ":"`）。改为 bash 4.0+ 内置参数展开（`${var:1:1}`、`${var^^}`、`${var//\\//}`、`${var,,}`、`[[ =~ ]]`），零外部依赖，在任何 PATH 状态下都能正常工作。同时抽出 `_path_to_unix()` 函数替代所有 `sed|tr|tr` 管道。Why: 启动脚本是唯一不可恢复的路径，必须保证极致鲁棒性，即使 PATH 完全损坏也要能正常完成初始化。
- [2026-07-12] **Hook 脚本用 `set -uo pipefail` 而非 `set -euo pipefail` 是设计决策，不是 bug** — Hook 运行在 Claude Code 主进程中，任何一个非零退出都可能中断整个会话。`-e`（遇错即停）对普通脚本是好习惯，但对 hook 是危险的——post-tool.sh 如果因为某个文件不可读就 exit 1，整个工具调用会被拒绝。因此 6 个 hook 脚本全部使用 `set -uo pipefail`（未定义变量报错 + 管道报错，但单条命令失败不退出）。lint 检查 `set -euo pipefail` 太死板，应改为检查是否至少包含 `set -uo pipefail`。
