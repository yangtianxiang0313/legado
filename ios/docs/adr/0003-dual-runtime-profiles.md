---
schema: legado.adr/v1
id: ADR-0003
status: accepted
date: 2026-07-22
scope: [runtime-policy, distribution]
capabilities: [CAP-SOURCE-FORMAT]
supersedes: []
superseded_by: null
deciders: [project-owner-request]
---

# StoreSafe 与 FullCompat 使用同一内核、不同链接闭包

## Context

任意远程书源、JavaScript、动态页面和私网访问的兼容需求，与 App Store 审核及不可信代码安全边界存在冲突。

## Decision

维护 StoreSafe 与 FullCompat 两个 composition root。StoreSafe 在编译链接层排除任意脚本、动态页面执行和书源开发能力；两者都在运行时通过 RuntimePolicy 二次校验。

## Consequences

共享核心减少分叉，并保留完整兼容发行路线；代价是 CI 必须验证两套依赖闭包和 capability matrix。

## Validation

Harness 检查 StoreSafe forbidden targets；能力拒绝返回稳定 `.capabilityDenied`，不能静默降级。发布前独立复核 App Store、隐私与 GPLv3 分发义务。

## Rollback

可暂停某个发行 profile；不得为了发布临时在运行时隐藏但仍链接 forbidden target。
