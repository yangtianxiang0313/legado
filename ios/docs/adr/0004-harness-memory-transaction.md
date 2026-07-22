---
schema: legado.adr/v1
id: ADR-0004
status: accepted
date: 2026-07-22
scope: [ai-harness, project-memory]
capabilities: [CAP-BOOTSTRAP, CAP-CONFORMANCE]
supersedes: []
superseded_by: null
deciders: [project-owner-request]
---

# 用工作项、Evidence 和项目记忆事务约束 AI 自动推进

## Context

AI 可以快速实现局部代码，但会受上下文丢失、范围漂移、弱化验收、重复踩坑和错误宣称完成影响。自然语言计划与开发日志无法机器判定。

## Decision

工作项 spec 不可变；Harness 单写状态和哈希链事件；claim 固定 scope/baseline，verify 固定验收并生成 tree-bound Evidence，close 强制能力状态、checkpoint、COMP/PIT/ADR 一起更新。架构、依赖、golden、权限和 intentional difference 进入人工门禁。

## Consequences

AI 可在明确停止条件内连续推进，聊天上下文不再是项目记忆；代价是每项能力要维护结构化元数据和证据。

## Validation

Harness 自带 unit tests，doctor 验证 schema、引用、事件链、状态页和架构；CI 需在最终 tree 重跑。

## Rollback

控制面可由 Python 迁移为 Swift CLI，但 JSON schema、状态事件与 Evidence 必须版本化兼容。
