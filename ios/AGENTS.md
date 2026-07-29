# Legado iOS AI 开发契约（Minimal Loop v2）

本目录由 AI 和人共同维护。产品架构见 `ios/docs/architecture.md`，自动推进协议见
`ios/docs/minimal-loop-v2.md`。

## 每次推进

1. 运行 `python3 -B ios/loop/loop.py doctor`。
2. 若当前为空，运行 `python3 -B ios/loop/loop.py start`；只实现
   `ios/project/loop/task.json` 中的唯一任务。
3. 阅读任务绑定的 Android 源码锚点、published Business Knowledge、accepted
   Requirement、Android Golden 和架构引用。
4. 只修改 `scope.allowed_paths`。已有且无关的用户改动不得覆盖或清理。
5. 完成后运行 `python3 -B ios/loop/loop.py verify`。失败只修复当前任务并重试，
   不得创建 Candidate、Recipe、WorkItem、Recovery、Checkpoint 或 Evidence 副本。
6. 验证成功后运行 `complete`，写入简短的完成摘要、当前状态、架构变化、可复发
   踩坑和下一步。详细日志只留在 `.harness-runtime/loop`。

## 架构与业务约束

- 书源逻辑必须位于独立 `SourceRuntime` package target；UI、Domain 不解释书源规则
  或请求语义。
- Android 源码用于提取业务知识和确定行为边界，不复制其代码架构。
- 书源以源码和受保护 Android 运行结果对齐为主，结构化测试为辅；本地 SourceLab
  提供稳定刺激，不充当业务期望。
- UI 验收以结构和导航拓扑为主、平台细节为辅；必须启动 iOS Simulator 验收。
- 依赖方向必须符合 `ios/harness/architecture-rules.json`。Core、Domain、
  RuleRuntime、ReaderCore 不得导入 UI、数据库或具体网络框架。
- 三方类型只能存在于 Adapter target，对内核暴露项目自有的不可变 Sendable 值。
- 不得自行修改 Android Golden、accepted Requirement、baseline、canonicalizer、
  架构依赖边、三方依赖或权限来让验收通过。
- `CancellationError` 原样传播；禁止业务全局单例、可变 static、未经决策的
  `Task.detached` 和 `@unchecked Sendable`。

## 不再使用人工 Gate

普通开发、架构既定范围内的能力扩展和 Loop 自身推进不设置确认文件或点击 Gate。
如果出现真正无法从既有架构和业务知识决定的产品取舍，AI 应直接说明选项和影响，
由用户在对话中决策；不得制造审批文件。
