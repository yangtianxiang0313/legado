# Business Knowledge

Business Knowledge 保存从冻结 Android 源码和真实运行结果中提取的稳定业务结论：

- Packet / Claim：事实、行为、风险和待决问题；
- Architecture Driver：影响模块边界的质量属性与决策；
- Coverage Ledger：Claim 是否已有 Requirement、Golden 和产品交付。

`published` 是可被 Planner 消费的当前知识，`proposals` 是仍需源码核对、Android
characterization 或产品决策的候选。校验入口：

```bash
python3 -B ios/harness/business-knowledge/business_knowledge.py doctor --root .
```

Minimal Loop v2 直接从 Coverage Ledger 派生 Task。知识补全也按普通 Task 推进，不再
经过 WorkItem/Evidence/Checkpoint 发布事务或人工 Gate。Android commit、Fact revision、
source anchor、runtime evidence、Packet/Driver revision 和 Coverage 引用仍必须精确。
