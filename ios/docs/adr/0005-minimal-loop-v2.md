---
schema: legado.adr/v1
id: ADR-0005
status: accepted
date: 2026-07-29
scope: [ai-loop, project-memory]
capabilities: [CAP-BOOTSTRAP, CAP-CONFORMANCE]
supersedes: [ADR-0004]
superseded_by: null
deciders: [project-owner-request]
---

# 用单 Task、短事件和固定验收驱动 AI

## Context

旧 Harness 把同一交付重复表示为 Candidate、Recipe、WorkItem、Recovery、Evidence、
Checkpoint、Approval 和大状态投影。控制代码与历史 JSON 已超过产品代码，并让 AI
优先维护控制面自洽，而不是推进 iOS 能力。

## Decision

采用 Minimal Loop v2。Planner 从 Business Knowledge、Requirement、Architecture
Driver 和 Android Golden 派生唯一 `task.json`；`current.json` 只保存当前投影；
`events.jsonl` 保存短完成知识。验证输出和大产物只进入 `.harness-runtime/loop`。
失败增加当前 Task attempt，不生成 Recovery Task。产品推进不设置人工 Gate；Golden
仍由独立 Android runner 发布。

## Consequences

控制面明显缩小，恢复上下文只需当前 Task、短事件和权威业务知识。历史审计材料继续由
Git 历史保存。代价是 v1 的细粒度状态机与本地伪审批不再作为运行能力。

## Validation

Loop 必须通过 `doctor/next/start/verify/complete` 自测，并至少完成一个绑定真实 Android
Golden 的 SourceRuntime 交付。Task 必须绑定实际修改路径和 workspace SHA-256。

## Rollback

若未来需要多 Agent 调度，可在外部增加队列和隔离执行器，但不得在仓内恢复重复的
Candidate/Recipe/WorkItem/Evidence/Checkpoint 投影。
