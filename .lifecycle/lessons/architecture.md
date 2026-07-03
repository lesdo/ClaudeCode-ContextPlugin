# Architecture Lessons

- [2026-07-04] 渐进迁移 (A→D 四个 Phase) 比大爆炸重写更安全：每步独立可验证，出错可精确定位。双写过渡 → 单写优先 → 编译生成 → 废弃旧索引，每一步都缩小了影响面。
- [2026-07-04] 审计工具 (audit-plugin.sh) 与测试框架互补：测试验证功能正确性 (153 tests)，审计检查架构合规 (10 维度)。测试捕获回归，审计发现代码异味和依赖漂移。
- [2026-07-04] SQLite 单源优于多文件协调：.md + .log + .session-index 三套并存的维护成本随功能增长而线性上升。统一到 SQLite 后查询效率从 O(n) grep 变为 O(1) 索引查找。
- [2026-07-04] 脚本的 LLM 成本审计很重要：wip-auto-save / track-file-change 等表面"零 token"的 command hook，在实际恢复流程中反而消耗大量上下文。SQLite events + crash_diagnose 启动报告更高效。
