# AI 自动推进协议

当前协议是 [Minimal Loop v2](minimal-loop-v2.md)。

新任务只使用：

```text
Source-anchored Candidate Claim / Published Business Knowledge / Requirement
→ task.json
→ 真实 Android characterization 或 iOS 实现
→ 固定验收
→ events.jsonl 完成事件
→ 下一任务
```

Candidate、Recipe、WorkItem、Recovery、Evidence、Checkpoint 和人工 Gate 是 v1 历史，
不得重新生成控制面副本。Business Knowledge 中的 Candidate Claim 是源码知识状态，
不是任务投影。运行日志只进入 `.harness-runtime/loop`。
