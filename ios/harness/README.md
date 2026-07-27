# Harness Control Plane

本目录是 AI 自动推进的确定性控制面，不包含“自动批准”或“更新 golden”命令。

```bash
python3 ios/harness/harness.py doctor
python3 -B ios/harness/android-intake/android_intake.py doctor --root .
python3 -B ios/harness/business-knowledge/business_knowledge.py doctor --root .
python3 -B ios/harness/business-knowledge/business_knowledge.py manifest --root .
python3 -B ios/harness/business-knowledge/business_knowledge.py selection \
  --root . --work-item IOS-KNOWLEDGE-CONTROL-PLANE-001
python3 -B ios/harness/source-lab/source_lab.py doctor --root .
python3 ios/harness/harness.py next --json
python3 ios/harness/harness.py context IOS-BOOT-001
python3 ios/harness/harness.py claim IOS-BOOT-001 --agent codex-main
python3 ios/harness/harness.py verify IOS-BOOT-001
python3 ios/harness/harness.py close IOS-BOOT-001
python3 ios/harness/loop_supervisor.py inspect
```

目录含义：

- `config.json`：受保护的验收命令、路径和预算策略；
- `architecture-rules.json`：Target/import/禁止符号的机器契约；
- `android-intake/`：固定 Android commit 的 Fact extractor、policy 与自测；
- `business-knowledge/`：Packet/Claim、Coverage Ledger 与 Architecture Driver 的只读校验、Catalog 重建和精确上下文选择；
- `work-items/`：不可变目标 spec；状态不写回这里；
- `schemas/`：控制面、fixture、envelope、Evidence 和项目记忆 schema；
- `fixtures/`：双端共同的确定性输入；
- `source-lab/`：本地书站、环境 coverage policy 与确定性 manifest；
- `goldens/`：受保护 Android oracle 输出 manifest；
- `normalization/`：版本化 canonicalizer 规则；
- `evidence/`：每次验证的结构化摘要；
- `tests/`：Harness 自身测试。

大体积 xcresult、trace、截图、DOM dump 放 `.harness-runtime` 或 CI artifact，不进入 Git。

Business Knowledge 的 candidate/published 目录、authority/coverage/proposal 摘要和
claim/verify/close 生命周期见
`ios/docs/business-knowledge-control-plane.md`。该 CLI 故意不提供
`publish`、`accept`、`promote` 或 Work Item `materialize`；初始化规划仅保存在
`ios/project/work-item-proposals/initialization-dag.json`，不会自动进入队列。

## Loop Supervisor

`loop_supervisor.py` 是 Harness 外层的本地 cooperative driver：

```bash
python3 ios/harness/loop_supervisor.py inspect
python3 ios/harness/loop_supervisor.py drive \
  --config ios/harness/supervisor.example.json \
  --agent local-agent \
  --max-transitions 3
python3 ios/harness/loop_supervisor.py materialize-review \
  ios/project/work-item-proposals/candidates/IOS-EXAMPLE-001.json
```

- `inspect` 输出互斥的结构化状态与稳定 reason code，不再把队列为空和已有活跃项合并；
- `drive` 只接受配置中的 argv 数组 Agent adapter，达到 transition 上限或遇到红基线、人工 Gate、终态失败、无进展时立即停；
- `materialize-review` 只接受 `work-item-proposals/candidates` 下的普通 JSON，重新校验依赖、写范围、预算和永久知识产出 reservation 后打开一次性按钮；
- CLI 没有非交互 `materialize` 或 `approve`，也不会更新 golden、发布知识或接受 ADR。

本地按钮产生的是 `local_unverified` 协作事实。真正无人值守与发布仍必须由隔离、签名的外部 Supervisor/CI 重验。
