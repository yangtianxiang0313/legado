---
schema: legado.adr/v1
id: ADR-0009
status: accepted
date: 2026-08-03
scope: [IntegrationKit, ArchiveZIPFoundation, AppUseCases, DatabaseGRDB]
capabilities: [CAP-RUNTIME-PORTS, CAP-CONFORMANCE]
supersedes: []
superseded_by: null
deciders: [project-owner:dual-platform-interoperability-priority]
---

# Android 备份双向互通边界

## Decision

iOS 备份以 Android 当前 `backup*.zip` / `backup.zip` 为互通格式，而不是另建 iOS 私有
snapshot。ZIP 容器只属于 `ArchiveZIPFoundation`；格式 DTO、逐域预检、恢复计划和结果报告
属于 `IntegrationKit`；`AppUseCases` 编排用户操作与原子提交；`DatabaseGRDB` 仅实现自己的
repository port，不接触 ZIP、AES、Android JSON 或 WebDAV。

格式合同必须由 Android 实际备份和恢复的受保护 Golden 冻结。静态源码目前只提供候选清单：
Android 可以省略空 JSON 成员，`servers.json` 与 WebDAV 密码使用本地密码派生 AES/Base64，
并按数据域插入或合并。iOS 不能据此猜测 Hutool 的 transformation、padding 或恢复细节。

每次恢复先解包、限额校验、识别成员、解析为版本化中间 DTO，并生成逐域计划；只有计划通过
才调用 repository port。未支持、未知、损坏和不安全的数据域必须体现在结构化结果中，不能
静默丢弃或把 Android SQLite 当成输入格式。

## Consequences

- 第一阶段先取 Android 真源的 archive/restore Golden，再启用已批准的 ZIPFoundation。
- 书源是首个优先数据域；其独立 `SourceFormat` 保持不被 UI 或数据库实现绑死。
- 书架、书签、阅读进度、替换规则、RSS、主题/阅读配置、服务器与其他 Android 成员按同一
  兼容矩阵持续推进。完成一个域才声明该域双向可用，不以“ZIP 可打开”宣称整体互通。
- Android 本地密码并不自动等价于 iOS Keychain；只有 Golden 证明算法后才允许 iOS 生成
  Android 可解密的敏感成员，原始密码始终在 adapter 边界内短暂使用。
