# Pitfall Records

只有非显然、可复发、跨模块/版本相关且已有诊断或预防办法的问题，才写为 `PIT-NNNN.json`。普通编译错误不记录。

新增前按 `fingerprint` 搜索；复发时递增 occurrence 并更新 last_seen。每条记录必须给出症状、触发条件、根因、诊断、修复、预防测试/lint 和 Evidence。
