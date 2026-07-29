---
schema: legado.adr/v1
id: ADR-0008
status: accepted
date: 2026-07-30
scope: [IntegrationKit, WebDAVFoundation, AppUseCases]
capabilities: [CAP-CONFORMANCE]
supersedes: []
superseded_by: null
deciders: [loop-v2:verified-android-golden]
---

# IntegrationKit 与 WebDAV Foundation 适配边界

## Context

冻结 Android `WebDav` 源码及受保护 Golden 已证明基础协议行为：PROPFIND、MKCOL、
GET、PUT、DELETE、DAV XML 元数据、路径编码、Basic 认证方案与若干错误边界。它没有
证明 iOS Target、依赖方向、凭据存储或三方库选择；合法无 body 204、TLS、重定向、
非 Basic 认证、ETag、锁、并发覆盖、原子上传和真实服务器矩阵仍未验证。

如果直接把 Android 类翻译进 AppUseCases 或 UI，URLSession、XML、Keychain 和服务器
兼容差异会扩散到业务层。若直接引入 WebDAV 三方库，又会在协议范围尚小时提前承担
许可证、维护、类型泄漏、并发和供应链成本。因此必须先固定可替换边界。

## Decision

在 `LegadoKit` 中预留两个独立 Target，但本 ADR 不创建 Target 或产品代码：

- `IntegrationKit` 是平台无关协议内核，只依赖 `LegadoCore`。它拥有项目自有且
  `Sendable` 的 `RemotePath`、DAV 元数据、请求计划、响应投影、稳定错误阶段以及它
  自己消费的 HTTP/凭据/时钟端口；不导入 SwiftUI、UIKit、WebKit、Security 或真实
  网络实现。
- `WebDAVFoundation` 是 live adapter，只依赖 `LegadoCore` 和 `IntegrationKit`。
  它使用 Foundation `URLSession` 执行请求、使用 Foundation `XMLParser` 解析 DAV
  XML，并在实现内部使用 Keychain/Security 解析凭据引用。平台类型和 secret 不得
  越过 adapter。
- `AppUseCases` 增加对 `IntegrationKit` 的单向依赖，编排备份 snapshot/envelope 与
  远端操作；UI 只调用 UseCase。composition root 是唯一可实例化
  `WebDAVFoundation` live 实现的位置。

首版不引入 WebDAV 三方库。当前方法集可由 URLSession 与 XMLParser 完成，并且
IntegrationLab/Android Golden 已提供足够的可替换合同。只有后续真实服务器矩阵证明
Foundation 方案存在明确协议缺口时，才能新建 ADR 比较候选库的许可证、维护活跃度、
二进制体积、隐私清单、认证挑战、重定向策略、Swift 6 并发与类型隔离。

持久配置只保存不透明 `CredentialReference`；用户名、密码、Authorization 值由
adapter 在请求前即时取出。跨 origin 重定向不得携带认证，认证值、Cookie、原文、
文件内容和 Keychain 错误正文不得进入 DTO、日志、trace、fixture 或 Golden。

Android 对齐分为两层：协议内核保留可结构化比较的 Android compatibility projection；
产品 UseCase 消费明确的安全语义。`check` 的“非 401 即 true”、目录自身项、
ObjectNotFound 降级和非法 204 body 只作为已观测兼容事实，不自动升级为产品正确性。
任何有意差异必须由结构化 policy 和测试记录，不能散落为条件分支。

## Alternatives

1. 复用 `NetworkFoundation` 并把 WebDAV XML 与凭据逻辑塞入同一 Target。拒绝：书源
   HTTP 与备份协议生命周期、secret 边界和错误模型不同，会扩大适配器职责。
2. 直接在 `AppUseCases` 使用 URLSession/XMLParser。拒绝：违反消费方端口和平台 I/O
   隔离，无法在 IntegrationLab 中替换 transport。
3. 首版引入 WebDAV 三方库。暂不采用：当前受证据支持的方法集很小，尚无实际缺口能
   抵消依赖、许可证、维护和类型泄漏成本。
4. 单一 `IntegrationKit` 同时包含协议与 live I/O。拒绝：会使 ConformanceCLI 和
   单元测试被迫链接网络、Security 与平台副作用。

## Consequences

收益是协议语义、live 网络和产品编排三层可独立替换、验收和审计；凭据边界可机器
检查；未来增加 S3、SMB 或其他远端适配器时不会污染 WebDAV DTO。

成本是多两个 Target 和一组显式 mapper/ports；DAV XML 与 HTTP 状态必须映射到项目
错误，不能把 Foundation 类型直接透传。首个产品切片还需独立 Requirement 才能修改
Package.swift 和实现源码，本 ADR 本身不授权实现。

## Architecture / Capability Impact

机器依赖矩阵新增：

```text
IntegrationKit      → LegadoCore
WebDAVFoundation    → LegadoCore, IntegrationKit
AppUseCases         → LegadoCore, LibraryDomain, SourceRuntime,
                      ReaderCore, IntegrationKit
```

`WebDAVFoundation` 不出现在 `IntegrationKit`、Domain、ReaderCore 或 SourceRuntime
的反向依赖中。StoreSafe 与 FullCompat 均可包含用户主动发起的 WebDAV client，但
实际 product closure 只能在后续产品 Task 中修改并由 profile 检查验证。

## Compatibility / Data Migration

本 ADR 不定义备份 envelope、数据库迁移或冲突合并。远端 path 和 DAV metadata 使用
项目值类型；Android `WebDavFile` 仅是事实来源，不成为跨平台 DTO。合法无 body 204
删除必须用新版本 IntegrationLab fixture 和 Android Oracle 补测，旧 Golden 保留为
“204 携带 body 的协议错误”证据，禁止原地改写。

## Validation

- `architecture-rules.json` 固定三个 Target 的精确依赖边，dependency contract 拒绝
  越界 import。
- ADR、resolved Driver、Coverage 与依赖矩阵由 Loop 的
  `architecture_decision` 结构化验收同时校验。
- 产品实现前必须新增或绑定 accepted Requirement；实现验收复用受保护 Android
  Golden，并补充合法 204、重定向认证剥离、取消传播和凭据脱敏测试。
- 真实服务器兼容矩阵是后续 spike，不得使用公网可用性替代确定性 IntegrationLab。

## Rollback

在产品 Target 尚未创建时，回滚只需用新 ADR supersede 本决定并更新机器依赖矩阵。
产品实现后如需替换 Foundation 或调整 Target，保留 `IntegrationKit` 公共值和端口，
在 composition root 替换 adapter；不得通过泄漏三方类型缩短迁移。

## Human Review

产品实现进入发布前仍需安全/隐私审核 Keychain access group、ATS、跨 origin 重定向、
凭据错误展示和隐私清单。任何三方库引入必须单独审核许可证与供应链；本 ADR 没有
批准任何三方 WebDAV 依赖。
