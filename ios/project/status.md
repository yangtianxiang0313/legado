# iOS 当前状态

更新时间：2026-07-29

当前阶段：Phase 1，声明式书源最小纵切。

已具备：

- 已批准的 iOS 分层架构与 Swift Package 边界；
- Android Fact Inventory、Requirement Catalog 和 Business Knowledge；
- SourceLab 本地书站、离线 FixtureTransport 和真实 Android Golden 发布链；
- SourceFormat 无损 round-trip；
- HTML/CSS 的 search、book info、toc、content 纵向解析；
- GET 与 POST Form 的确定性 RequestPlan；
- `android_expected / ios_actual / canonical_request_plan / first_divergence`
  结构化验收；
- Minimal Loop v2 的 `next/start/verify/complete/doctor`。

当前 Loop：空闲；最近完成 `IOS-SOURCE-RUNTIME-POST-FORM-001`。

下一条产品主线：从 `AnalyzeUrl` 源码和已有 Source Request 知识中选择一个未覆盖的
独立请求切片（raw/JSON/XML、header/cookie/retry 之一），先获得真实 Android Golden，
再扩展 SourceRuntime。Phase 1 的非 JS 单源链路稳定后，进入本地书架、阅读器和
iOS Simulator UI 验收。

v1 的 WorkItem、Evidence、Checkpoint、proposal projection、Gate 和大状态文件只作为
Git 历史迁移材料；新任务不得继续写入。
