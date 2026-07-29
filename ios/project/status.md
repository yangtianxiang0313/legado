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

当前 Loop：空闲；最近完成 `IOS-SOURCE-RUNTIME-POST-FORM-001`。`next` 已从
`AnalyzeUrl.getStrResponseAwait` 的源码 Claim 自动选择
`IOS-CHARACTERIZE-SOURCE-RESPONSE-XML-DECLARATION-NORMALIZATION-001`。

下一条产品主线：为 XML response normalization 扩展 SourceLab 场景，通过真实
Android runner 获得受保护 Golden，再生成对应 SourceRuntime Delivery。随后继续
raw/JSON 与 header/cookie/retry。Phase 1 的非 JS 单源链路稳定后，进入本地书架、
阅读器和 iOS Simulator UI 验收。

v1 的 WorkItem、Evidence、Checkpoint、proposal projection、Gate 和大状态文件只作为
Git 历史迁移材料；新任务不得继续写入。
