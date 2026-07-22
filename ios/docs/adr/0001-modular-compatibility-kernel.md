---
schema: legado.adr/v1
id: ADR-0001
status: accepted
date: 2026-07-22
scope: [ios-architecture]
capabilities: [CAP-BOOTSTRAP, CAP-CORE, CAP-SOURCE-FORMAT, CAP-CONFORMANCE]
supersedes: []
superseded_by: null
deciders: [project-owner-request]
---

# 使用兼容内核、用例层、平台适配器和原生 Feature

## Context

Android 当前实现把 Room、Android 生命周期、全局阅读状态和书源执行紧密组合。逐类翻译会把平台耦合和全局可变状态带入 iOS，也无法建立稳定的跨端行为判定。

## Decision

采用 `LegadoCore / Domain / SourceFormat / RuleRuntime / SourceRuntime / ReaderCore / AppUseCases / Adapter / Feature / App composition root` 分层。协议由消费方拥有，三方类型停在 Adapter，SwiftUI Feature 不直接做 I/O。

详细 Target 依赖以 `ios/harness/architecture-rules.json` 为机器权威，`ios/docs/architecture.md` 为人类说明。

## Alternatives

- 把 Android 类一一翻译为 Swift：平台耦合和测试边界不可控。
- 单一 App target：启动快，但 AI 很容易绕过边界，无法机器审计。
- 首版引入 TCA 与完整 Clean Architecture 框架：增加额外抽象和供应链，不解决规则兼容的核心风险。

## Consequences

核心可由 CLI 和 fixture 独立验证，平台框架可替换；代价是初期 Target、mapper、ports 和 composition root 较多。

## Validation

Harness 校验 imports、禁止模块/符号和 profile 闭包；Swift 编译开启 strict concurrency complete。

## Rollback

允许在不改变依赖方向的前提下合并过细 Target。反转边界或引入新架构框架需新 ADR。
