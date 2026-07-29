---
schema: legado.adr/v1
id: ADR-0006
status: accepted
date: 2026-07-29
scope: [ios-ui, ai-loop]
capabilities: [CAP-BOOTSTRAP, CAP-CORE]
supersedes: []
superseded_by: null
deciders: [project-owner-request]
---

# 先物化原生 App 壳与双设备结构验收

## Context

书源 Loop 已能从 Android Golden 推进到独立 SourceRuntime，但仓库尚无 iOS App、
UITest Target 或可运行的 Simulator 验收。继续扩展全部 UI 动作合同会让控制面再次
超过产品代码，也无法证明 SwiftUI、导航和辅助功能在真实设备环境可用。

## Decision

先交付最小原生 UI Bootstrap：

- `AppNavigation` 保存四个稳定 Root 与每个 Root 的独立 Route path；
- App composition root 只链接 `LegadoStoreSafeKit` 根产品；
- compact iPhone 使用 `TabView + NavigationStack`，regular iPad 使用
  `NavigationSplitView + NavigationStack`，两者共享同一 Router；
- 第一条纵切只覆盖四个 Root、书架搜索入口和返回，不宣称其余 Android 菜单已实现；
- UITest 必须在固定 iPhone SE（第三代）和 iPad Pro 13-inch（M4）模拟器运行，
  输出结构化 observed JSON，由仓内 runner 与版本化 expected 逐字段比较；
- 截图不是结构 Gate，后续视觉细节按 Feature 增量验收。

`BKP-UI-TOPOLOGY-001/r0003` 继续作为待拆分知识，不整体晋级为实现合同。

## Alternatives

- 一次实现完整 UI Topology r3：合同规模远大于当前产品，无法增量验证。
- 只做 SwiftUI 单元测试：不能证明 App 可安装、启动和被 XCUITest 操作。
- 只做截图比较：无法稳定定位 Route、State 与辅助功能结构差异。
- 引入 TCA、Tuist 或运行时 UI 测试库：当前纵切不需要额外供应链。

## Consequences

Loop 首次具备真实 UI 跑道，且不会阻塞后续 Feature 扩展。初始界面只证明结构骨架，
不代表阅读器、书源管理或所有菜单已经完成。Xcode project 是受版本控制的产品构建输入。

## Architecture / Capability Impact

新增 SwiftPM `AppNavigation` 与测试 Target，新增 Xcode App/UITest Target。核心依赖
方向不变；AppNavigation 仅依赖 Core/Domain，App 仍只从根产品组装。

## Compatibility / Data Migration

不新增持久化 schema。Android Activity/Fragment 仅作为四 Root 与入口结构证据；
iOS 控件和平台投影采用原生实现。

## Validation

验证必须包含 Package 架构合同、AppNavigation 测试、两台 iOS 26 Simulator 的
`xcodebuild test`、结构化 expected/actual 和首差异 JSON Pointer。

## Rollback

可以删除 App/UITest 与 AppNavigation Target，恢复为纯 Swift Package；不得以此为由
删除已验证的 SourceRuntime。

## Human Review

正式发布前仍需 App Store 元数据、隐私、签名、视觉和完整 VoiceOver 人工审核；本 ADR
不替代这些审核。
