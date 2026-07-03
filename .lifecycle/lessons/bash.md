# Bash Gotchas

- [2026-07-04] MSYS2 Git Bash 中 `${3:-{}}` 嵌套花括号解析异常（输出双 `}}` 而非单 `}`）。用 `if [ -n "${3:-}" ]; then ARGS="$3"; else ARGS="{}"; fi` 替代。
- [2026-07-04] `set -euo pipefail` 与空目录 glob 不兼容：`ls "$DIR"/*.md` 在无文件时触发 `set -e` 退出。加 `|| true` 兜底。`set -u` 要求所有变量使用前初始化（`LATEST=""`）。
- [2026-07-04] Windows Python `print()` 输出 `\r\n`，bash `read` 读到的字符串带 `\r` 后缀。用 `tr -d '\r'` 清理。
