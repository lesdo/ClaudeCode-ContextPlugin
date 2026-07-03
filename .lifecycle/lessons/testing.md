# Testing Lessons

- [2026-07-04] 先建测试框架再重构：153 tests 让 Phase B/C/D 存储迁移零回归。测试套件 5 秒跑完全量，每次提交前自动验证。
- [2026-07-04] bash `while read` 管道在右侧时创建子 shell，pass/fail 计数器在父 shell 不更新。用临时文件 + `< "$TMPFILE"` 重定向替代。
