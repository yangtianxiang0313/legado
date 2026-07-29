# Minimal Loop v2

Loop v2 只保留一个当前任务、一个追加事件流和一个紧凑状态投影：

```text
已发布业务知识 / Android Golden
→ next（纯派生）
→ task.json（唯一活动任务）
→ AI 实现
→ verify（结构化验收）
→ complete（摘要、踩坑、当前状态、下一步）
→ 下一任务
```

权威文件：

- `ios/project/loop/task.json`：仅在任务进行中存在；
- `ios/project/loop/events.jsonl`：短事件和完成知识；
- `ios/project/loop/current.json`：可重建的当前投影。

命令：

```bash
python3 -B ios/loop/loop.py doctor
python3 -B ios/loop/loop.py next
python3 -B ios/loop/loop.py start
python3 -B ios/loop/loop.py verify
python3 -B ios/loop/loop.py complete \
  --summary "完成内容" \
  --pitfall "可复发问题与预防办法" \
  --next-step "下一步"
```

普通失败只追加 `verification_failed` 并增加 attempt，不创建 Recovery
任务。完整 stdout/stderr 和 verification report 位于 `.harness-runtime/loop`，
不进入 Git。旧 Harness 在迁移期只读保留；新的任务不得再生成 Candidate、
Recipe、WorkItem、Checkpoint 或 Evidence 副本。
