# Architecture Lessons

- [2026-07-04] 渐进迁移 (A→D 四个 Phase) 比大爆炸重写更安全：每步独立可验证，出错可精确定位。双写过渡 → 单写优先 → 编译生成 → 废弃旧索引，每一步都缩小了影响面。
- [2026-07-04] 审计工具 (audit-plugin.sh) 与测试框架互补：测试验证功能正确性 (153 tests)，审计检查架构合规 (10 维度)。测试捕获回归，审计发现代码异味和依赖漂移。
- [2026-07-04] SQLite 单源优于多文件协调：.md + .log + .session-index 三套并存的维护成本随功能增长而线性上升。统一到 SQLite 后查询效率从 O(n) grep 变为 O(1) 索引查找。
- [2026-07-04] 脚本的 LLM 成本审计很重要：wip-auto-save / track-file-change 等表面"零 token"的 command hook，在实际恢复流程中反而消耗大量上下文。SQLite events + crash_diagnose 启动报告更高效。
- [2026-07-08] **配置文件变量展开不可信** — `.mcp.json` 的 `env` 块中 `${CLAUDE_PROJECT_DIR}` 不会被 Claude Code 展开，字面量字符串直接传给子进程，导致 Python `os.makedirs()` 用字面量创建了垃圾目录树。配置文件中的变量引用必须实测，不可假设平台会展开。
- [2026-07-08] **代码审查必须模拟执行路径** — 上次只改了 `session-start.sh` 下半段的 MCP 统计段，没发现上半段未改动的 `exit 0` 让新代码永远不可达。diff 审查不足以发现控制流 Bug，必须从入口点走一遍执行路径。
- [2026-07-12] **迁移完成 = 全量扫描引用，不允许"删一半"** — Phase D 废弃 `.session-index` 时删了 `session_index_append()`（写函数），但 `session_index_read/tail/find`（读函数）仍残留。测试因为 `append` 缺失而失败，但残留函数无人注意。每次功能迁移/移除后必须 `grep -r <旧API名> .` 确认零引用，否则残骸随时间累积。本项目已发生 2 次（.session-index → SQLite; .log → SQLite events），模式明确。
- [2026-07-12] **SQLite WAL 模式：嵌套写入必死锁** — `get_db()` 每次调用返回新连接。在 `with get_db() as conn:` 块内调用另一个也开 `with get_db()` 的函数（如 `pattern_register`），两个写连接在 WAL 模式下互斥 → `database is locked`。解法：读数据在 conn 块内完成，收集结果，退出块后再写。或传递 conn 参数而非 project_dir。
