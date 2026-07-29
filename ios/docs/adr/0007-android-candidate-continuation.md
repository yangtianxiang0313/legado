---
schema: legado.adr/v1
id: ADR-0007
status: accepted
date: 2026-07-29
scope: [ai-loop, android-migration, business-knowledge]
capabilities: [CAP-KNOWLEDGE-CONTROL, CAP-CONFORMANCE]
supersedes: []
superseded_by: null
deciders: [project-owner-request]
---

# 用项目级迁移章程续接未领取的 Android 真源候选

## Context

Minimal Loop v2 能从 `candidate_source_anchored` Claim 派生 Characterization，但原实现
只接受与逐切片 `AndroidMigrationIntent` 源码路径重叠的 Claim。首个 Intent 覆盖的
候选完成后，仍有满足依赖的 Android 真源候选，却错误返回 `queue_empty`。

逐 Claim 手写 Intent 会重新引入已经删除的控制面膨胀，也不符合项目所有迁移需求来自
冻结 Android 源码、无需逐项人工 Gate 的决策。

## Decision

保留逐切片 `AndroidMigrationIntent` 作为更具体的 Requirement authority；若候选没有
匹配 Intent，Planner 使用已接受的
`REQ-ANDROID-MIGRATION-CHARACTERIZATION-001@1#RC-01` 作为项目级兜底 authority。

兜底仅适用于：

- Packet 与 Requirement 绑定同一冻结 Android commit；
- Claim 明确标记为 `candidate_source_anchored` 和
  `runtime_requirement=android_characterization`；
- Claim 的全部知识依赖已经闭合；
- Requirement 为 `ios_product_decision + policy_auto + accepted`。

它只授权真源刻画，不允许跳过 Android runner、手写 expected 或直接实现 iOS 产品。
Characterization 仍必须发布受保护 Golden、业务知识和 Coverage，之后才能派生 Delivery。

## Alternatives

- 为每个 Candidate 手写一个 `AndroidMigrationIntent`：authority 最细，但会重新产生大量
  一次性控制文件，并让 AI 等待人工建档。
- 删除 Requirement 约束直接选择所有 Candidate：实现最短，但会把 baseline 漂移、
  人工裁决候选和未闭合依赖一起放入队列，无法 fail closed。
- 只扩大现有 Source Runtime Intent 的 anchors：只能掩盖当前一组候选，不能覆盖 Book、
  Reader、UI 与 Integration 等后续业务域。

## Consequences

队列是否为空由真实候选耗尽决定，不再由逐切片 Intent 覆盖率决定。项目只保留一个
迁移章程，而不是为每个候选增加中间 WorkItem/Recipe/Gate。Android baseline 漂移、
依赖未闭合或章程缺失时继续 fail closed。

## 影响 Target、数据与兼容性

只修改 `ios/loop` Planner 和 Requirement control data，不改变任何 iOS 产品 Target、
Swift Package 依赖边或持久化模型。已有逐切片 Intent 的任务 ID、Golden、Coverage 和
完成事件保持不变；新增路径只会让此前不可见的候选进入 Characterization。

## Validation

- 单元测试证明无逐切片 Intent 的候选可由章程续接；
- 单元测试证明 Android baseline 漂移时不会续接；
- 在真实仓库中 `loop.py next` 必须选择此前被误报为空的下一条 Android 候选。

## 人工审核项

无逐候选审核 Gate。项目所有者只需在架构变更时审核本 ADR；每个行为的业务真值继续由
冻结 Android source、独立 runner 和受保护 Golden 验证。

## Rollback

删除项目级 Requirement 并移除 Planner fallback，即恢复为逐切片 Intent-only 模式。
