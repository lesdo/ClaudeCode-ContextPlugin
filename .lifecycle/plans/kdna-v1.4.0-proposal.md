# KDNA v1.3.1 → v1.4.0 更新提案

**日期**: 2026-07-12
**触发**: v3.1.0/v3.1.1 开发中暴露 3 个现有 KDNA 盲区
**当前版本**: @lesdo/context-plugin-judgment v1.3.1 (11 axioms / 3 patterns / 10 self-checks / 3 failure modes)

---

## 新增 Axiom: ax12 — 迁移完成 = 全量扫描引用

```
applies_when:
  - 废弃/移除任何函数、变量、文件、数据格式
  - 完成一个迁移 Phase 后
does_not_apply_when:
  - 新增功能（不涉及旧API删除）
  - 纯新增文件
failure_risk:
  旧 API 的一半被删掉（如写函数）另一半残留（如读函数）
  → 测试因为缺失而失败但残留无人注意
  → 新人不知道哪个是旧API哪个是新API
  → 代码库出现废弃层+当前层双轨
  → 每隔几个版本就要清理一次"历史遗留"
self-check:
  grep -r <旧API名> . 返回零匹配吗？（不只是主要调用点，包括测试、脚本、文档）
evidence:
  - Phase D: session_index_append 被删, read/tail/find 仍残留（本次修复）
  - Phase B→C: .log 文件写入被禁止, 读逻辑在 test_post_tool.sh 中仍检查 .log 文件
```

## 新增 Failure Mode: 嵌套 get_db() WAL 写入死锁

```
name: 嵌套 get_db() WAL 写入死锁
symptom: "database is locked" 在原本不应有锁竞争的代码路径上
root_cause:
  get_db() 每次调用返回新连接
  SQLite WAL 模式: 多读并发, 单写互斥
  在 with get_db() as conn: 块内调用另一个也用 get_db() 的函数
  → 两个写连接同时存在 → sqlite3 拒绝
fix_pattern:
  - 两阶段: 在 conn 块内只读+收集结果, 退出块后再写
  - 或: 传递 conn 参数而非 project_dir, 复用同一个连接
evidence:
  - instinct 管线: run_analytics 持 conn → _analyze_patterns 调用 pattern_register
    → pattern_register 内部 with get_db() → 死锁（本次修复: 改为两阶段）
```

## 新增 Self-Check: 测试路径 = 生产路径

```
check: 测试中引用的路径变量是否来自生产代码同一个源头？
anti_pattern:
  测试: BRIEFING_FILE="$TEST_DIR/.claude/context/briefing/active.md"
  生产: BRIEFING_FILE="$PROJECT_DIR/.context/briefing/active.md"
  → 测试从未真正验证生产行为 → 3 个失败被隐藏数周
fix:
  测试中用 source 加载生产代码的变量定义, 或写 assert 时
  对路径字符串做 grep 确认无硬编码重复
evidence:
  - test_compact.sh 路径 .claude/context/ ≠ pre-compact.sh 路径 .context/
    差异存在至少 2 周, 无人发现
```

## 新增 Pattern: 安全正则的假阳性过滤

```
name: 安全扫描正则无假阳性过滤
description:
  正则规则匹配硬编码密钥时, 必须同时过滤:
  - 分隔线 (===, ---, ###)
  - 注释行 (//, #)
  - 示例/占位符 (example_key, your_token_here)
  否则假阳性淹没有效发现, 用户关闭扫描
evidence:
  - shield.py v0.1.0: Rule #14 (base64) 匹配 46 条 === 分隔线
    全部是假阳性, 零有效发现 → v0.2.0 修复: 排除 = 出字符类 + _is_separator_line()
```

---

## 版本规划

| 版本 | 内容 |
|------|------|
| v1.3.1 (当前) | 11 axioms / 3 patterns / 10 self-checks |
| v1.4.0 | +ax12 (迁移扫描) +failure_mode (WAL死锁) +self_check (测试路径) +pattern (正则过滤) |

## 实施方式

KDNA `.kdna` 文件重新打包需要 KDNA Studio 工具链。
当前通过本项目 `.lifecycle/lessons/` 生效，下次 KDNA 域维护时一并吸入。
