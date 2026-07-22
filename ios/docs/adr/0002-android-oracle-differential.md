---
schema: legado.adr/v1
id: ADR-0002
status: accepted
date: 2026-07-22
scope: [conformance]
capabilities: [CAP-CONFORMANCE, CAP-SOURCE-FORMAT]
supersedes: []
superseded_by: null
deciders: [project-owner-request]
---

# 以冻结 Android Oracle 和离线 Fixture 做阶段级差分

## Context

规则语言存在大量空值、类型转换、DOM、编码和 URL 边角。仅用 iOS 自写测试容易验证“自洽”而非兼容；实时网站又不可重复。

## Decision

Android 和 iOS runner 消费同一离线 fixture，输出同一 execution envelope；canonicalizer 比较 request、decode、rule stage、URL 和 typed result。日常使用受保护 Android golden，nightly/专用流程重跑 oracle。

## Consequences

可以定位首个语义分叉并防回归；成本是维护 Android runner、fixture schema、canonicalizer 和 golden 审核流程。

## Validation

普通任务无 golden 写权限；manifest 绑定 fixture、oracle commit、runner 和 canonicalizer hash。发现 Android bug 时进入人工 adjudication。

## Rollback

不能退回实时网站作为主测试。可以替换 runner 实现，但 envelope 和已发布 compatibility profile 需保持版本化。
