# iOS 能力路线图

路线按“可验证的纵向能力”推进，不按页面数量推进。每一阶段必须先有离线 fixture 和机器验收，再接 UI。

## Phase 0：架构、验收与骨架（已完成）

- 架构、Minimal Loop v2 和项目记忆；
- Android Fact Inventory、Requirement Catalog 与 Business Knowledge；
- LegadoKit Swift Package、Swift 6 strict concurrency；
- Core ID/JSON/Clock/Trace/Error；
- Conformance envelope 和 FixtureTransport 骨架。
- SourceLab 本地书站、书源构建器、正反场景覆盖策略与无 socket/loopback 双通道。

退出条件：`Android intake + Business Knowledge + Loop doctor + swift test + SourceLab`
全绿，AI 能从 published knowledge 派生并完成一个 Task。

## Phase 1：声明式书源最小纵切（进行中）

- BookSource JSON round-trip 和 unknown fields；
- URL 模板、GET/POST、header/body、charset；
- HTML/CSS 基础规则、字段类型转换、相对 URL；
- search → book info → chapters → content 单源链路；
- Android oracle 对应的离线 T2/T3。
- 每增加 GET/POST、相对 URL、charset、Cookie 或 redirect 能力，同步增加 SourceLab 正反 reference 与 Android golden。

退出条件：一组真实但离线的非 JS 书源在两端 canonical result 一致。

## Phase 2：本地书架与阅读器

- GRDB schema/migrations/repository；
- 书架、详情、目录原生 Feature；
- ContentNormalizer、语义锚点、分页与 ReaderSession；
- 进度恢复、预取、缓存、TTS 基础；
- iPhone/iPad 导航与固定模拟器 snapshot。

## Phase 3：规则兼容扩展

- XPath 双 DOM 兼容；
- Jayway JSONPath 高频子集；
- Regex/Java Pattern shim；
- JavaScriptCore/Rhino host bridge 的 FullCompat 实现；
- Cookie/session、动态 Web 登录、错误 trace；
- held-out fixtures、fuzz 和恶意输入。

## Phase 4：格式、迁移与发布

- Android 备份显式导入；
- EPUB 最小 codec，按需求评估 Readium；
- ZIP 安全、图片/TTS/下载完整能力；
- StoreSafe 与 FullCompat 独立链接闭包和发布门禁；
- SBOM、第三方声明、隐私清单、GPL/App Store 法律结论；
- 性能、稳定性、可访问性、release Evidence。

## 工作项拆分原则

- 1 个工作项只改变 1 个可验证行为；
- 运行行为未达到 L4 时只生成 characterization/SourceLab/Oracle 前置 DAG，不生成产品实现项；
- 典型上限 8 个文件、500 行、3 次 edit/verify；
- 先增加 fixture/contract，再实现；golden 必须由独立 Android runner 产生；
- Target/依赖/协议/迁移/capability 变化不能混在普通能力任务中；
- UI 任务引用已 verified 的 UseCase，不在 View 内补业务兼容逻辑。
