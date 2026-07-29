# AI 自动推进协议

当前协议是 [Minimal Loop v2](minimal-loop-v2.md)。

新任务只使用：

```text
Business Knowledge / Requirement / Android Golden
→ task.json
→ AI 实现
→ 固定验收
→ events.jsonl 完成事件
→ 下一任务
```

Candidate、Recipe、WorkItem、Recovery、Evidence、Checkpoint 和人工 Gate 是 v1 历史，
不得为新能力重新生成。运行日志只进入 `.harness-runtime/loop`。
