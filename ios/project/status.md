# iOS 当前状态

更新时间：2026-07-29

当前阶段：Phase 1，声明式书源能力扩展 + 原生 iOS App 最小壳。

已具备：

- 已批准的 iOS 分层架构与 Swift Package 边界；
- Android Fact Inventory、Requirement Catalog 和 Business Knowledge；
- SourceLab 本地书站、离线 FixtureTransport 和真实 Android Golden 发布链；
- SourceFormat 无损 round-trip；
- HTML/CSS 的 search、book info、toc、content 纵向解析；
- GET、POST Form、Header/Cookie/Retry、字段 charset 编码与 URL 模板编译；
- XML 字符串响应归一化；
- 按 source key 共享且逐字段对齐 Android 的限流语义；
- `android_expected / ios_actual / canonical_request_plan / first_divergence`
  结构化验收；
- 原生 SwiftUI App、共享 `AppRouter`、iPhone 四 Tab 与 iPad Split View；
- 固定 iPhone/iPad Simulator 上四 Root 与书架搜索的真实 XCUITest；
- Minimal Loop v2 的幂等 `advance`、事件投影恢复、结构化验收和真实项目记忆。

当前任务、最近完成项与下一项分别以
[`current.json`](loop/current.json)、[`events.jsonl`](loop/events.jsonl) 和
`python3 -B ios/loop/loop.py next` 的实时结果为准，本文不重复保存动态队列投影。

下一阶段仍沿冻结 Android Claim 逐项补齐 SourceRuntime，同时以已物化的 App/UITest
壳承接真实业务 UI 垂直切片。实时队列当前优先选择“请求派发与响应类型”的 Android
characterization；其 Golden 发布后再进入独立 SourceRuntime 实现。

v1 的 WorkItem、Evidence、Checkpoint、proposal projection、Gate 和大状态文件只作为
Git 历史迁移材料；新任务不得继续写入。
