# iOS 项目当前状态

> 此文件由 `ios/harness/harness.py` 从 `state.json` 生成，请勿手工编辑。

- 更新时间：2026-07-28T14:33:30Z
- 当前阶段：`phase-0-control-plane-and-bootstrap`
- 架构版本：`1.0`
- 架构摘要：`fa6ab6cd2f4142848847c17a03d761e4cd4705a39babdf82bec3efa68ab4be9a`
- 活跃工作项：无
- 下一个可领取工作项：无
- 最近完成：IOS-BUSINESS-KNOWLEDGE-PUBLISHER-REMOTE-003

## 健康度

| 维度 | 状态 |
|---|---|
| active_candidate_repair | `bounded` |
| android_golden_publisher | `implemented_external_authority` |
| android_intake | `fact_inventory_ready` |
| android_oracle | `trusted_candidate_verified` |
| architecture | `designed` |
| auto_materialization_policy | `compiled_control_plane_v1` |
| business_knowledge_publisher | `checkout_remote_bound` |
| codex_agent_adapter | `cli_0_145_compatible_real_smoke_verified` |
| conformance | `scaffold_verified` |
| control_catalog_resume | `bounded_self_heal` |
| harness | `ready` |
| harness_tests_timeout | `calibrated` |
| harness_timeout_cleanup | `verified` |
| human_gate_policy | `decision_only` |
| ios_build | `package_verified` |
| knowledge_android_surfaces | `candidate_verified` |
| knowledge_book_domain | `candidate_verified` |
| knowledge_control_plane | `proposal_batch_claim_refs_verified` |
| knowledge_initialization_dag | `proposal_verified` |
| knowledge_integrations | `candidate_verified` |
| knowledge_reader_lifecycle | `candidate_verified` |
| knowledge_revision_tombstones | `v1_verified` |
| knowledge_source_runtime | `candidate_verified` |
| knowledge_source_runtime_html_css | `golden_characterized_candidate` |
| knowledge_ui_topology | `candidate_verified` |
| local_approval_ui | `verified` |
| loop_demand_autonomy | `bound_delivery_blueprint_v1` |
| loop_demand_compiler | `canonical_requirement_binding_v1` |
| loop_engine | `local_mature` |
| loop_supervisor | `local_verified` |
| loop_trusted_verification | `real_codex_verified` |
| proposal_compiler | `local_verified` |
| proposal_gate_policy | `authority_only` |
| proposal_lifecycle_tests | `state_aware` |
| recovery_compiler_binding | `content_addressed` |
| requirements | `catalog_ready_one_characterization_gap` |
| source_lab | `fixture_transport_integrated` |
| supervisor_run_journal | `local_replayable` |
| swiftpm_manifest_verification | `sandbox_isolated` |
| terminal_recovery_lineage | `typed_runtime_replacement` |
| terminal_recovery_resolution | `single_terminal_predecessor` |
| trusted_process_cleanup | `bounded_stable` |
| trusted_supervisor_reference | `local_verified` |

## 工作队列

| ID | 优先级 | 状态 | 依赖 | 标题 |
|---|---:|---|---|---|
| IOS-ANDROID-GOLDEN-PUBLISHER-001 | 100 | `completed` | IOS-ANDROID-ORACLE-ATTESTATION-RECOVERY-009 | 建立独立 Android Golden Publisher |
| IOS-ANDROID-ORACLE-ATTESTATION-001 | 100 | `completed` | IOS-ANDROID-ORACLE-RUNNER-001 | 建立 GitHub-hosted Android Oracle 双证明提案链 |
| IOS-ANDROID-ORACLE-ATTESTATION-RECOVERY-002 | 100 | `completed` | IOS-ANDROID-ORACLE-ATTESTATION-001 | 恢复 GitHub workflow runner.temp 上下文 |
| IOS-ANDROID-ORACLE-ATTESTATION-RECOVERY-003 | 100 | `completed` | IOS-ANDROID-ORACLE-ATTESTATION-RECOVERY-002 | 恢复 GitHub-hosted Android SDK tools 路径 |
| IOS-ANDROID-ORACLE-ATTESTATION-RECOVERY-004 | 100 | `blocked` | IOS-ANDROID-ORACLE-ATTESTATION-RECOVERY-003 | 恢复 GitHub-hosted adb 显式路径 |
| IOS-ANDROID-ORACLE-ATTESTATION-RECOVERY-005 | 100 | `completed` | IOS-ANDROID-ORACLE-ATTESTATION-RECOVERY-003, IOS-HARNESS-TEST-TIMEOUT-RECOVERY-002 | 恢复被基线超时阻断的 adb 显式路径 |
| IOS-ANDROID-ORACLE-ATTESTATION-RECOVERY-006 | 100 | `completed` | IOS-ANDROID-ORACLE-ATTESTATION-RECOVERY-005 | 建立有界 emulator 启动诊断 |
| IOS-ANDROID-ORACLE-ATTESTATION-RECOVERY-007 | 100 | `completed` | IOS-ANDROID-ORACLE-ATTESTATION-RECOVERY-006 | 绑定并验证 hosted Runner 的 AVD home |
| IOS-ANDROID-ORACLE-ATTESTATION-RECOVERY-008 | 100 | `completed` | IOS-ANDROID-ORACLE-ATTESTATION-RECOVERY-007 | 建立 hosted Runner 的 KVM 访问合同 |
| IOS-ANDROID-ORACLE-ATTESTATION-RECOVERY-009 | 100 | `completed` | IOS-ANDROID-ORACLE-ATTESTATION-RECOVERY-008 | 对齐 GitHub 当前 SLSA provenance 身份 |
| IOS-ANDROID-ORACLE-RUNNER-001 | 100 | `completed` | IOS-ORACLE-CONTROL-PLANE-001, IOS-SOURCELAB-ENGINE-001 | 建立冻结 Android WebBook 的 SourceLab Oracle Runner |
| IOS-AUTO-MATERIALIZATION-POLICY-001 | 100 | `completed` | IOS-PROPOSAL-COMPILER-001, IOS-DECISION-GATE-POLICY-001, IOS-LOOP-SUPERVISOR-E2E-001 | 让无决策、无权威迁移的编译候选自动进入队列 |
| IOS-BOOT-001 | 100 | `completed` | 无 | 建立 Swift Package 与首批模块骨架 |
| IOS-BUSINESS-KNOWLEDGE-PUBLISHER-001 | 100 | `completed` | IOS-ANDROID-GOLDEN-PUBLISHER-001, IOS-KNOWLEDGE-SOURCE-RUNTIME-GOLDEN-002 | 建立受信 Business Knowledge Publisher |
| IOS-BUSINESS-KNOWLEDGE-PUBLISHER-REMOTE-003 | 100 | `completed` | IOS-BUSINESS-KNOWLEDGE-PUBLISHER-YAML-002 | 修复 Publisher checkout remote 绑定 |
| IOS-BUSINESS-KNOWLEDGE-PUBLISHER-YAML-002 | 100 | `completed` | IOS-BUSINESS-KNOWLEDGE-PUBLISHER-001 | 修复 Business Knowledge Publisher workflow YAML |
| IOS-CODEX-AGENT-ADAPTER-001 | 100 | `completed` | IOS-LOOP-SUPERVISOR-E2E-001, IOS-PROPOSAL-COMPILER-001 | 接入可诊断、可续接的 Codex exec Agent adapter |
| IOS-CODEX-AGENT-ADAPTER-COMPAT-002 | 100 | `completed` | IOS-CODEX-AGENT-ADAPTER-001, IOS-AUTO-MATERIALIZATION-POLICY-001 | 对齐当前 Codex CLI 并固化真实 turn/resume smoke |
| IOS-CONTROL-CATALOG-RESUME-001 | 100 | `completed` | IOS-RECOVERY-COMPILER-BINDING-001 | 恢复控制面变更后的 Supervisor 续跑 |
| IOS-DECISION-GATE-POLICY-001 | 100 | `completed` | IOS-HARNESS-APPROVAL-UI-001, IOS-TRUSTED-SUPERVISOR-REFERENCE-001 | 将盲批 Gate 替换为结构化决策暂停 |
| IOS-HARNESS-APPROVAL-UI-001 | 100 | `completed` | IOS-KNOWLEDGE-BOOK-DOMAIN-001 | 提供本地一键人工审批界面 |
| IOS-HARNESS-TEST-TIMEOUT-RECOVERY-002 | 100 | `completed` | IOS-HARNESS-TIMEOUT-CLEANUP-001 | 校准全量 Harness 测试有效超时预算 |
| IOS-HARNESS-TIMEOUT-CLEANUP-001 | 100 | `completed` | IOS-HARNESS-APPROVAL-UI-001 | 让 Harness 超时清理失败保留结构化 Evidence |
| IOS-KNOWLEDGE-SOURCE-RUNTIME-GOLDEN-002 | 100 | `completed` | IOS-ANDROID-GOLDEN-PUBLISHER-001, IOS-LOOP-DEMAND-COMPILER-003 | 从受保护 Android Golden 提炼 HTML/CSS 书源纵向知识 |
| IOS-KNOWLEDGE-TOMBSTONE-PROTOCOL-001 | 100 | `completed` | IOS-KNOWLEDGE-CONTROL-PLANE-001, IOS-PROPOSAL-LIFECYCLE-RECOVERY-002, IOS-CODEX-AGENT-ADAPTER-COMPAT-002 | 建立失败知识产出 revision tombstone 协议 |
| IOS-KNOWLEDGE-UI-TOPOLOGY-CONTINUATION-001 | 100 | `cancelled` | IOS-KNOWLEDGE-ANDROID-SURFACES-001, IOS-KNOWLEDGE-BOOK-DOMAIN-001, IOS-KNOWLEDGE-SOURCE-RUNTIME-001, IOS-KNOWLEDGE-READER-LIFECYCLE-001 | 续接并冻结 UI Topology 知识候选 |
| IOS-KNOWLEDGE-UI-TOPOLOGY-RECOVERY-002 | 100 | `completed` | IOS-KNOWLEDGE-ANDROID-SURFACES-001, IOS-KNOWLEDGE-BOOK-DOMAIN-001, IOS-KNOWLEDGE-SOURCE-RUNTIME-001, IOS-KNOWLEDGE-READER-LIFECYCLE-001 | 按知识 revision 规则恢复 UI Topology 候选 |
| IOS-LOOP-DEMAND-AUTONOMY-001 | 100 | `blocked` | IOS-AUTO-MATERIALIZATION-POLICY-001, IOS-SUPERVISOR-OWNED-VERIFY-RECOVERY-002, IOS-ANDROID-GOLDEN-PUBLISHER-001 | 让 Loop 从受控交付蓝图持续生成并自动推进普通工作项 |
| IOS-LOOP-DEMAND-AUTONOMY-RECOVERY-002 | 100 | `completed` | IOS-AUTO-MATERIALIZATION-POLICY-001, IOS-SUPERVISOR-OWNED-VERIFY-RECOVERY-002, IOS-ANDROID-GOLDEN-PUBLISHER-001 | 恢复 Golden 发布后可重复基线并实现 Loop Demand Autonomy |
| IOS-LOOP-DEMAND-COMPILER-003 | 100 | `completed` | IOS-LOOP-DEMAND-AUTONOMY-RECOVERY-002, IOS-ANDROID-GOLDEN-PUBLISHER-001 | 建立结构化 Delivery Intent 与 Loop Demand Compiler |
| IOS-LOOP-DEMAND-COMPILER-RECOVERY-004 | 100 | `completed` | IOS-LOOP-DEMAND-COMPILER-003 | 修复 Requirement 规范化摘要绑定 |
| IOS-LOOP-SUPERVISOR-001 | 100 | `cancelled` | IOS-HARNESS-APPROVAL-UI-001, IOS-HARNESS-TIMEOUT-CLEANUP-001, IOS-KNOWLEDGE-UI-TOPOLOGY-RECOVERY-002 | 建立可执行 Loop Supervisor 与按钮化物化控制面 |
| IOS-LOOP-SUPERVISOR-E2E-001 | 100 | `completed` | IOS-LOOP-SUPERVISOR-RECOVERY-002 | 完成 Loop Supervisor 自托管 E2E 与进程组回收 |
| IOS-LOOP-SUPERVISOR-RECOVERY-002 | 100 | `completed` | IOS-HARNESS-APPROVAL-UI-001, IOS-HARNESS-TIMEOUT-CLEANUP-001, IOS-KNOWLEDGE-UI-TOPOLOGY-RECOVERY-002 | 恢复并验证 Loop Supervisor 控制面 |
| IOS-MATERIALIZATION-CATALOG-REFRESH-001 | 100 | `cancelled` | IOS-RECOVERY-COMPILER-BINDING-001 | 将知识 Catalog 刷新纳入物化原子事务 |
| IOS-PROCESS-GROUP-REAP-001 | 100 | `completed` | IOS-CODEX-AGENT-ADAPTER-COMPAT-002, IOS-SWIFTPM-VERIFY-SANDBOX-001 | 稳定受信 Supervisor 进程组回收判定 |
| IOS-PROPOSAL-COMPILER-001 | 100 | `completed` | IOS-KNOWLEDGE-DAG-REPAIR-001, IOS-LOOP-SUPERVISOR-E2E-001 | 建立 initialization DAG 到不可变候选的编译器 |
| IOS-PROPOSAL-GATE-REPAIR-001 | 100 | `completed` | IOS-SUPERVISOR-OWNED-VERIFY-RECOVERY-002, IOS-KNOWLEDGE-INTEGRATIONS-RECOVERY-004 | 移除 proposal 橡皮图章并允许受限修复 turn |
| IOS-PROPOSAL-LIFECYCLE-RECOVERY-002 | 100 | `completed` | IOS-PROPOSAL-COMPILER-001, IOS-AUTO-MATERIALIZATION-POLICY-001 | 修复 proposal 测试对物化生命周期的自阻断 |
| IOS-RECOVERY-COMPILER-BINDING-001 | 100 | `completed` | IOS-TYPED-RECOVERY-LINEAGE-001 | 将 typed recovery 绑定进编译与物化链路 |
| IOS-SUPERVISOR-OWNED-VERIFY-001 | 100 | `blocked` | IOS-CODEX-AGENT-ADAPTER-COMPAT-002, IOS-SWIFTPM-VERIFY-SANDBOX-001 | 将受信 verify 与 close 移出 Agent 沙箱 |
| IOS-SUPERVISOR-OWNED-VERIFY-RECOVERY-002 | 100 | `completed` | IOS-CODEX-AGENT-ADAPTER-COMPAT-002, IOS-SWIFTPM-VERIFY-SANDBOX-001, IOS-PROCESS-GROUP-REAP-001 | 恢复 Supervisor-owned verify 与 close |
| IOS-SUPERVISOR-RUN-JOURNAL-001 | 100 | `completed` | IOS-CONTROL-CATALOG-RESUME-001 | 为 Loop Supervisor 增加可重放运行日志 |
| IOS-SWIFTPM-VERIFY-SANDBOX-001 | 100 | `completed` | IOS-CODEX-AGENT-ADAPTER-COMPAT-002, IOS-KNOWLEDGE-TOMBSTONE-PROTOCOL-001 | 隔离 SwiftPM manifest 验证沙箱与缓存 |
| IOS-TERMINAL-RECOVERY-RESOLUTION-001 | 100 | `completed` | IOS-PROPOSAL-GATE-REPAIR-001, IOS-KNOWLEDGE-INTEGRATIONS-RECOVERY-004, IOS-SUPERVISOR-OWNED-VERIFY-RECOVERY-002 | 按恢复谱系消解历史终态 blocker |
| IOS-TERMINAL-RECOVERY-RESOLUTION-002 | 100 | `completed` | IOS-TERMINAL-RECOVERY-RESOLUTION-001 | 收紧显式恢复关系并补齐最终证据 |
| IOS-TRUSTED-SUPERVISOR-REFERENCE-001 | 100 | `completed` | IOS-LOOP-SUPERVISOR-E2E-001, IOS-CODEX-AGENT-ADAPTER-001 | 建立仓库外签名 journal 与隔离复验 reference runner |
| IOS-TYPED-RECOVERY-LINEAGE-001 | 100 | `completed` | IOS-TERMINAL-RECOVERY-RESOLUTION-002, IOS-SUPERVISOR-OWNED-VERIFY-RECOVERY-002 | 将恢复谱系升级为强类型控制边 |
| IOS-KNOWLEDGE-PROPOSAL-BATCH-REFS-REPAIR-001 | 96 | `completed` | IOS-KNOWLEDGE-ANDROID-SURFACES-001 | 闭合同批知识候选引用契约 |
| IOS-KNOWLEDGE-DAG-REPAIR-001 | 95 | `completed` | IOS-KNOWLEDGE-CONTROL-PLANE-001 | 修复初始化 DAG 验收缺口并收紧知识演进门禁 |
| IOS-KNOWLEDGE-LEDGER-GATE-REPAIR-001 | 95 | `completed` | IOS-KNOWLEDGE-DAG-REPAIR-001 | 闭合知识台账选择与人工审批门禁 |
| IOS-KNOWLEDGE-SELECTION-ROBUSTNESS-001 | 95 | `completed` | IOS-KNOWLEDGE-LEDGER-GATE-REPAIR-001 | 加固知识条目选择合并与异常输入处理 |
| IOS-CORE-001 | 90 | `completed` | IOS-BOOT-001 | 实现稳定 ID、JSONValue、Clock、Trace 和错误基础 |
| IOS-KNOWLEDGE-ANDROID-SURFACES-001 | 90 | `completed` | IOS-KNOWLEDGE-SELECTION-ROBUSTNESS-001 | 提取 Android 业务表面与领域索引 |
| IOS-KNOWLEDGE-BOOK-DOMAIN-001 | 90 | `completed` | IOS-KNOWLEDGE-ANDROID-SURFACES-001, IOS-KNOWLEDGE-PROPOSAL-BATCH-REFS-REPAIR-001 | 提取 Book、Shelf 与 Progress 领域知识 |
| IOS-KNOWLEDGE-CONTROL-PLANE-001 | 90 | `completed` | IOS-ORACLE-CONTROL-PLANE-001 | 建立业务知识与架构驱动控制面 |
| IOS-KNOWLEDGE-INTEGRATIONS-RECOVERY-002 | 90 | `exhausted` | IOS-KNOWLEDGE-ANDROID-SURFACES-001, IOS-PROPOSAL-LIFECYCLE-RECOVERY-002, IOS-CODEX-AGENT-ADAPTER-COMPAT-002 | 恢复外部集成、权限、依赖与发布约束知识 |
| IOS-KNOWLEDGE-INTEGRATIONS-RECOVERY-003 | 90 | `exhausted` | IOS-KNOWLEDGE-ANDROID-SURFACES-001, IOS-KNOWLEDGE-TOMBSTONE-PROTOCOL-001, IOS-CODEX-AGENT-ADAPTER-COMPAT-002 | 恢复外部集成、权限、依赖与发布约束知识 revision 3 |
| IOS-KNOWLEDGE-INTEGRATIONS-RECOVERY-004 | 90 | `completed` | IOS-KNOWLEDGE-ANDROID-SURFACES-001, IOS-KNOWLEDGE-TOMBSTONE-PROTOCOL-001, IOS-SUPERVISOR-OWNED-VERIFY-RECOVERY-002 | 验证恢复 Integrations 知识 revision 4 |
| IOS-KNOWLEDGE-SOURCE-RUNTIME-001 | 89 | `completed` | IOS-KNOWLEDGE-ANDROID-SURFACES-001, IOS-KNOWLEDGE-PROPOSAL-BATCH-REFS-REPAIR-001 | 提取书源格式、规则与执行流水线知识 |
| IOS-KNOWLEDGE-READER-LIFECYCLE-001 | 88 | `completed` | IOS-KNOWLEDGE-ANDROID-SURFACES-001, IOS-KNOWLEDGE-BOOK-DOMAIN-001, IOS-KNOWLEDGE-SOURCE-RUNTIME-001 | 提取阅读会话、正文、进度与预取知识 |
| IOS-KNOWLEDGE-UI-TOPOLOGY-001 | 87 | `exhausted` | IOS-KNOWLEDGE-ANDROID-SURFACES-001, IOS-KNOWLEDGE-BOOK-DOMAIN-001, IOS-KNOWLEDGE-SOURCE-RUNTIME-001, IOS-KNOWLEDGE-READER-LIFECYCLE-001 | 提取页面结构、导航图与多级菜单知识 |
| IOS-KNOWLEDGE-INTEGRATIONS-001 | 86 | `blocked` | IOS-KNOWLEDGE-ANDROID-SURFACES-001 | 外部集成、权限、依赖与发布约束知识 |
| IOS-RUNTIME-PORTS-001 | 85 | `completed` | IOS-BOOT-001, IOS-CORE-001 | 定义确定性 HTTP 请求响应与 Transport port |
| IOS-CONFORMANCE-001 | 80 | `completed` | IOS-BOOT-001, IOS-CORE-001, IOS-RUNTIME-PORTS-001 | 建立离线 Fixture 与 canonical execution envelope 骨架 |
| IOS-SOURCELAB-ENGINE-001 | 75 | `completed` | IOS-CONFORMANCE-001 | 将 SourceLab 场景接入 FixtureTransport 与 ConformanceCLI |
| IOS-SOURCE-FORMAT-001 | 70 | `completed` | IOS-BOOT-001, IOS-CORE-001, IOS-CONFORMANCE-001, IOS-SOURCELAB-ENGINE-001 | 实现 BookSource 最小无损 JSON round-trip |
| IOS-SOURCE-FORMAT-FIXTURES-001 | 69 | `completed` | IOS-SOURCE-FORMAT-001, IOS-SOURCELAB-ENGINE-001 | 建立 BookSource 双轨一致性 fixture 与 iOS 执行骨架 |
| IOS-ORACLE-CONTROL-PLANE-001 | 68 | `completed` | IOS-SOURCE-FORMAT-FIXTURES-001 | 建立只读 Android Oracle golden proposal 控制合同 |
| IOS-SOURCE-FORMAT-CONFORMANCE-001 | 65 | `superseded` | IOS-SOURCE-FORMAT-001, IOS-SOURCELAB-ENGINE-001 | 接入 BookSource Android golden 差分 |

## 风险

- `RISK-DISTRIBUTION-001`：App Store 动态代码政策与 GPLv3 分发义务需在外部发布前完成法律评估

## 常用命令

```bash
python3 ios/harness/harness.py doctor
python3 ios/harness/harness.py next
python3 ios/harness/harness.py context <WORK_ITEM_ID>
```
