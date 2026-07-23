# iOS 项目当前状态

> 此文件由 `ios/harness/harness.py` 从 `state.json` 生成，请勿手工编辑。

- 更新时间：2026-07-23T08:27:10Z
- 当前阶段：`phase-0-control-plane-and-bootstrap`
- 架构版本：`1.0`
- 架构摘要：`fa6ab6cd2f4142848847c17a03d761e4cd4705a39babdf82bec3efa68ab4be9a`
- 活跃工作项：无
- 下一个可领取工作项：IOS-KNOWLEDGE-SELECTION-ROBUSTNESS-001
- 最近完成：IOS-KNOWLEDGE-LEDGER-GATE-REPAIR-001

## 健康度

| 维度 | 状态 |
|---|---|
| android_intake | `fact_inventory_ready` |
| android_oracle | `not_started` |
| architecture | `designed` |
| conformance | `scaffold_verified` |
| harness | `ready` |
| ios_build | `package_verified` |
| knowledge_control_plane | `ledger_close_and_review_gates_verified` |
| knowledge_initialization_dag | `proposal_verified` |
| requirements | `catalog_ready_one_characterization_gap` |
| source_lab | `fixture_transport_integrated` |

## 工作队列

| ID | 优先级 | 状态 | 依赖 | 标题 |
|---|---:|---|---|---|
| IOS-BOOT-001 | 100 | `completed` | 无 | 建立 Swift Package 与首批模块骨架 |
| IOS-KNOWLEDGE-DAG-REPAIR-001 | 95 | `completed` | IOS-KNOWLEDGE-CONTROL-PLANE-001 | 修复初始化 DAG 验收缺口并收紧知识演进门禁 |
| IOS-KNOWLEDGE-LEDGER-GATE-REPAIR-001 | 95 | `completed` | IOS-KNOWLEDGE-DAG-REPAIR-001 | 闭合知识台账选择与人工审批门禁 |
| IOS-KNOWLEDGE-SELECTION-ROBUSTNESS-001 | 95 | `ready` | IOS-KNOWLEDGE-LEDGER-GATE-REPAIR-001 | 加固知识条目选择合并与异常输入处理 |
| IOS-CORE-001 | 90 | `completed` | IOS-BOOT-001 | 实现稳定 ID、JSONValue、Clock、Trace 和错误基础 |
| IOS-KNOWLEDGE-CONTROL-PLANE-001 | 90 | `completed` | IOS-ORACLE-CONTROL-PLANE-001 | 建立业务知识与架构驱动控制面 |
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
