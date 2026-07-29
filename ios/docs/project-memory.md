# 项目信息沉淀

项目记忆只保存会影响后续实现的事实，不保存控制面流水账。

| 事实 | 权威位置 |
|---|---|
| iOS 架构与依赖方向 | `ios/docs/architecture.md`、ADR、`Package.swift` |
| 冻结 Android 源码事实 | `ios/project/android-intake/` |
| 已进入范围的业务合同 | `ios/project/requirements/accepted/` |
| 业务知识、架构驱动与覆盖 | `ios/project/business-knowledge/` |
| 网站刺激与真实 Android 期望 | SourceLab fixture、Android Golden |
| 当前任务和进度 | `ios/project/loop/current.json`、`task.json` |
| 完成摘要、踩坑和下一步 | `ios/project/loop/events.jsonl` |
| 可复发问题 | `ios/project/pitfalls/` |

完成一个 Task 时必须沉淀：

- 本次增加的能力和当前状态；
- 架构是否变化；变化时引用 ADR；
- 可复发的坑以及预防办法；
- 仍未覆盖的边界和下一步。

构建日志、stdout/stderr、截图、xcresult、DOM dump 和结构化 actual 放入
`.harness-runtime/loop`，不进入 Git。稳定结论进入 Business Knowledge；一次性的实现
过程只留在 Git 历史。旧 WorkItem、Evidence、Checkpoint、Gate 和大状态投影属于 v1
历史，不能作为新任务的权威输入。
