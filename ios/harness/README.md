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
python3 ios/harness/loop_supervisor.py preflight \
  ios/project/work-item-proposals/candidates/IOS-EXAMPLE-001.json
python3 ios/harness/loop_supervisor.py drive \
  --config ios/harness/supervisor.example.json \
  --agent local-agent \
  --max-transitions 3
python3 ios/harness/loop_supervisor.py materialize-review \
  ios/project/work-item-proposals/candidates/IOS-EXAMPLE-001.json
```

- `inspect` 输出互斥的结构化状态与稳定 reason code，不再把队列为空和已有活跃项合并；
- `preflight` 是纯只读检查，能在 claim 前发现依赖、schema、显式 allow/deny/protected 冲突和永久知识 revision reservation；
- `drive` 只接受配置中的 argv 数组 Agent adapter；当显式启用
  `compiled-control-plane-v1` 时，可以先自动物化唯一的最高优先候选，再继续 claim 和
  Agent transition；
- 显式启用 `bound-delivery-blueprint-v1` 后，队列为空时还会扫描 HEAD 中的完整
  delivery blueprint。Supervisor 不生成需求或实现语义，只复核并绑定 accepted 且
  `implementation_ready` 的 Requirement revision/clauses、Capability revision 与
  owner、受保护 Android Golden release receipt、completed dependency Evidence/
  Checkpoint 和当前 HEAD；唯一最高优先且 `gates=[]`、无 authority effect、scope 完全
  落在 owner/对应 Tests/Checkpoint/Pitfall 的普通实现项会自动进入既有生命周期；
- 显式启用 `source-anchored-android-migration-v1` 后，Delivery 完成不会再次退回
  `queue_empty`。Demand Compiler 会读取 `ios/project/migration-intents/*.json`，
  逐项绑定冻结 baseline commit、Android source path/blob/symbol、SourceLab behavior
  状态、Capability revision、Requirement proposal identity 与完整 intake blueprint。
  唯一最高优先且所有绑定闭合的 `gates=[]` control-plane intake 会自动物化；它只能
  产出知识与 Requirement proposal，不能接受 Requirement、发布 Golden、修改
  SourceLab authority、Android 或 iOS 产品代码；
- 显式启用 `source-anchored-characterization-v1` 后，已完成 intake 且已存在
  accepted Requirement 的迁移项会继续绑定精确 revision/clauses 和完整
  characterization blueprint。Supervisor 只物化
  `requirements.mode=characterization`、`source_lab.mode=extend`、单一场景，
  且写范围精确限制在该 candidate 场景、CAP-CONFORMANCE、Checkpoint/Pitfall 的
  Work Item；SourceLab manifest/policy、Golden、Oracle、Android、Package、产品、
  Requirement、Approval 和架构路径必须显式 deny；
- `synthetic-source-provenance-v1` 不是通用审批绕过。它只处理由当前 Work Item
  新建、`provenance.kind=synthetic`、`source_refs` 覆盖全部 Android 源码锚点、
  `external_network=deny`、无额外动态 Gate 且已通过 Harness verify 的
  `scenario-provenance-review`。`sanitized_capture`、来源缺失、既有 reference
  修改、scope 越权或任何其他裁决仍 fail closed；
- 显式启用 `source-anchored-android-oracle-v1` 后，已完成 Characterization 会按
  WorkItem/Evidence/Checkpoint、Requirement/SourceLab selection、scenario manifest
  与 Capability revision 结算，不再重复物化场景任务。Supervisor 只物化
  `requirements.mode=characterization`、`source_lab.mode=reuse`、`gates=[]` 且仅能
  写 Android Oracle runner/tests、CAP-CONFORMANCE、Checkpoint/Pitfall 的 blueprint；
  Android 产品、Fixture、Golden、Publisher、Workflow、Requirement 和架构路径必须
  deny；
- 显式启用 `source-anchored-trusted-android-oracle-v1` 后，Demand Compiler 会沿
  replacement/recovery chain 结算原 Oracle 与唯一 completed resolution，绑定
  WorkItem/Evidence/Checkpoint、原 Requirement selection、candidate SourceLab
  selection/manifest、scenario digest 与 CAP-CONFORMANCE revision。Supervisor 只物化
  `requirements.mode=characterization`、`source_lab.mode=reuse`、`candidate-only`、
  `gates=[]` 且唯一依赖该 completion 的受信 proposal blueprint；它只能泛化既有
  GitHub Android Oracle workflow、`ci_proposal`/`trusted_import` 及测试，不能写
  Publisher、Golden、Fixture、Android/iOS 产品、Requirement 或架构；
- 受信 proposal Work Item 完成后，Demand Compiler 同时解析 state `replacement`
  与 Work Item `recovers`，只接受唯一、无环、同 Capability/场景且落到 completed
  末端的谱系。结算精确绑定 blueprint/WorkItem/Evidence/Checkpoint、Requirement
  与 SourceLab selection、scenario/manifest digest、共享 `verify_proposal`
  authority 以及待执行 commit，输出 `trusted_oracle_execution_required`。
  Supervisor 将其映射为 `external_execution_required` 并停止本地 drive；此时
  receipt 必须仍为 `null`，后续需在 GitHub-hosted runner 执行固定 workflow，
  下载双 attestation 后再由独立 receipt settlement/Golden Publisher 工作项处理；
- `external_execution.github_oracle` 只有在显式 `enabled=true` 时接管上述停止状态。
  它校验 clean HEAD、绑定 commit、remote repository 与 `gh` 登录，使用稳定的
  `feature/oracle-<scenario>-<sha>` create-only branch，并只查询固定 workflow、
  branch 与 `event=push` run；create-only push 是唯一服务端创建动作，零 run
  按本次是否创建 branch 分别返回 `dispatched` 或 `pending`。恢复状态写入
  `.harness-runtime/github-oracle/<execution-id>.json`；该 journal 不是 receipt、
  Evidence 或发布权威。成功 run 仍须独立下载、双证明 trusted import 与 receipt
  settlement；
- Receipt Settlement corrective 候选只有同时带
  `external-execution`、`android-oracle`、`receipt-settlement`、`corrective`
  四个标签，且为无 Gate 的 control-plane、Business Knowledge 与 SourceLab 均
  `not_applicable` 时，才进入专用自动策略。其 `allow_write` 必须精确等于 receipt
  settler/测试、Demand Compiler/测试、Loop Supervisor/测试、本 README、
  CAP-KNOWLEDGE-CONTROL、当前 Work Item Checkpoint 与 PIT；缺项、重复、额外路径、
  wildcard 或其他 Work Item Checkpoint 一律拒绝。Workflow、Oracle
  contract/packager/trusted import/runner、Dispatcher、Golden、Publisher、Fixture、
  SourceLab、Requirement、业务知识、Approval、产品、Package 与架构路径必须保持
  deny；缺少任一专用标签的候选继续走普通自动策略，不获得这些额外写权限；
- 显式启用 `supervisor-owned-verification-v1` 后，单次工作项按 Agent edit →
  Supervisor verify → Agent memory → Supervisor close 推进。Agent 不能通过直接调用
  `verify/close` 改变控制状态；Supervisor 在每个 Agent turn 后核对 event/status/
  Evidence binding，并独立产生验收 Evidence；
- required checks 在 Supervisor 宿主进程中运行，不继承 Codex workspace-write 对
  loopback、SwiftPM 二级 sandbox 或 iOS Simulator 的限制；验证失败仍由 Harness
  决定 implementing/rejected/exhausted，下一轮 Agent 读取最新 Evidence 后修复；
- 未发布 Packet/Driver proposal 只写候选区，不提升 published/accepted authority，
  因此默认不触发人工 `knowledge-review`/`architecture-review`。项目确实需要候选期
  方向决策时，必须在 Work Item 中显式声明对应 v1 decision contract；publish、
  promotion、product disposition 和 oracle adjudication 仍保持强 Gate；
- 单一 active knowledge producer 若暂时让全局知识图变红，Supervisor 只在错误全部
  属于 Business Knowledge、状态为 implementing、现有 diff 仍满足 scope 时提供
  repair implementation turn，并把 Doctor errors 绑定进 0600 context。其他 Doctor
  red、越权 diff、多 active 或控制状态变化仍立即停止；
- 合法 control-plane upgrade 修改 `harness.py` 或 Business Knowledge control 文件后，
  若 Supervisor 在同轮 verify 前中断，下一次 drive 只在单一 active implementing、
  `business_knowledge_control_upgrade`、非空 scope 合法 control diff，且每条 Doctor
  error 都精确归因于 Catalog stale 时，由 Supervisor 在 mutation lock 中刷新派生
  Catalog。刷新前后 event/runtime binding 必须不变，Doctor 必须恢复；随后复用原
  Work Item/attempt，跳过重复 Agent edit 并直接 verify。任何 graph 错误、其他 Doctor
  error、越权路径、刷新失败或控制状态变化都结构化停止；
- 每次 Agent 调用都在新的 session/process group 中启动；超时按 TERM → 有界等待 → KILL 回收完整进程树，并结构化返回 `timed_out`、`process_leak`、`cleanup_error`；
- Supervisor 只向 adapter 传递显式环境白名单和临时 context 路径，结果只保留输出长度与 SHA-256，不回显 context、stdout/stderr 或宿主环境 secret；
- trusted verification 使用忽略版本控制的
  `.harness-runtime/loop-runs/<work-item>--attempt-<n>.json` 保存本地可重放完成点。
  文件固定 0600、目录固定 0700，以原子替换写入有界 sequence/previous hash 链；记录只含
  Work Item、attempt、phase、HEAD、控制绑定和候选快照 digest，不含 prompt、context、
  stdout/stderr、环境或凭据。新 Supervisor 只有在所有绑定完全一致时才可跳过重复
  `implementation`/`memory_close` Agent turn，随后仍由 Harness `verify/close` 裁决；
  缺失、旧 attempt、候选/控制漂移、截断、权限异常或篡改均不授予跳过权限。若
  `verify/close` 已返回错误，Supervisor 追加 phase invalidation，防止失败结果被当成
  “进程中断”无限重放；
- 普通候选不再要求点击确认：自动策略要求 repo/index clean，candidate、recipe、
  DAG、manifest 和依赖 provenance 都是 HEAD 中的普通文件，且 compiler 可重算、
  `gates=[]`、Requirement 为 `control_plane`、知识只产生 proposal、不修改产品、
  架构、配置、Schema、Golden、Approval 或 authority；
- 普通产品交付同样不要求确认按钮。`bound-delivery-blueprint-v1` 的 blueprint 本身就是
  完整 Work Item，必须由版本库明确声明 scope、AC、checks、budget、memory、SourceLab
  和 stop conditions；readiness、Requirement record、Capability owner、Golden/
  receipt、依赖证据、优先级或 HEAD 任一漂移都 fail closed。它不能修改 Package
  manifest、entitlement、migration、CI、ADR、Schema、Golden、Requirement 或 Approval；
- 已存在受阻/终态任务时，若编译器提供唯一且内容寻址的 `recovers` 候选，Supervisor
  会先自动物化该 Recovery Work Item，不再把“已有恢复方案”误报成人工恢复决策；
- 当队列、编译候选和交付蓝图都为空时，Supervisor 最后统一读取 Delivery Intent 与
  Android Migration Intent。`structured-delivery-intent-v1` 只接受 HEAD
  中显式声明的目标 Work Item、Capability revision、Requirement revision/clauses、
  published Packet/Driver、protected Golden selector 和 blueprint path，并按固定顺序
  编译最短链：`knowledge_authority_required → requirement_readiness_required →
  blueprint_required → delivery_ready`。`source-anchored-android-migration-v1`
  则按 `migration_intake_ready → requirement_authority_required →
  characterization_blueprint_required → characterization_ready →
  oracle_blueprint_required → oracle_ready →
  trusted_oracle_blueprint_required → trusted_oracle_ready →
  trusted_oracle_execution_required` 推进，并要求
  completed WorkItem、Evidence、Checkpoint、Capability update、proposal digest、
  accepted Requirement record/catalog digest 与 characterization blueprint
  精确结算。因此“尚缺上游权威输入”或“下一条 Android 迁移切片已声明”都不会被
  误报为 `queue_empty`；
- Demand Plan 中的 `authority_transition=true` 不等于 Human Decision，也不授予普通
  Agent 写 accepted/published/protected 路径的权限；它表示下一步应由受信 Publisher
  消费已绑定的机器证据。只有产品取舍无法由证据推导时才 `requires_human=true`；
- `materialize-review` 仅保留为自动策略无法覆盖时的显式恢复入口，不是正常推进 Gate；
- CLI 没有非交互 `materialize` 或 `approve`，也不会更新 golden、发布知识或接受 ADR。

本地 Loop Engine 的成熟边界是：确定性 inspect、源码锚定迁移 intake、控制面与普通
交付策略物化、受限 argv adapter、真实 Harness 生命周期、Evidence/Capability/
Checkpoint/Event 绑定，以及
进程树有界回收、Agent 后/verify 前与 memory 后/close 前的跨进程故障恢复均有自动化
E2E。它足以在单机、单写者、真实 Human Decision 保留的前提下持续推进工作项。

本地 run journal 只减少协作式 Agent 重复执行，不是生产权威 journal；它与 Agent
共享用户权限，不能证明记录未被恶意重写。本地按钮产生的也仍是 `local_unverified`
协作事实。取消普通执行确认不等于取消 Human Decision 或 Authority Transition；
后二者仍必须按下节暂停。跨机器无人值守、并行 DAG 调度、
签名控制状态、真实 Integrations 扫描和发布晋级，仍必须由隔离、签名的外部
Supervisor/CI 重验；这些属于下一阶段，不由本地 adapter 冒充。

可单独查看当前需求链：

```bash
python3 -B ios/harness/demand_compiler.py --root . plan
```

输出中的 artifact path、revision 与 SHA-256 是后续 Publisher/blueprint 的输入绑定，
不能用 Capability `next_actions` 文案、标题或测试结果替代。

## Machine Gate、Human Decision 与 Authority Transition

Harness 不再把 `risk` 标签、文件数量或“安全/架构 review”文案本身当成人工暂停理由：

1. **Machine Gate**：required checks、scope、架构规则、安全策略、Evidence 和记忆事务
   都可确定性重算，成功后自动通过，失败时给出结构化错误；
2. **Human Decision**：只有多个方案都满足机器约束、但产品目标、兼容取舍或演进成本
   无法由 AI 推导时才暂停。每次只问一个具体问题并要求选择一个互斥方案；
3. **Authority Transition**：知识/Golden/Requirement/ADR/patch promotion 只能消费外部
   受信签名 artifact，本地 decision record 不具备发布权限。

新 candidate 的 `gates` 为空时无需人工步骤；非空时必须使用 v1 decision contract，
否则 `loop_supervisor preflight` 以 `LEGACY_HUMAN_GATE_REJECTED` 终止：

```json
{
  "gate_contract_version": 1,
  "gates": ["architecture-choice"],
  "decision_gates": [
    {
      "gate": "architecture-choice",
      "trigger": "always",
      "question": "采用哪个已验证的模块边界？",
      "why_human": "两个方案都通过机器约束，但长期演进成本不同。",
      "options": [
        {
          "id": "separate-package",
          "label": "独立 Package",
          "consequence": "替换边界更强，但增加一个模块。",
          "reversible": true
        },
        {
          "id": "existing-package",
          "label": "留在现有 Package",
          "consequence": "当前模块更少，后续拆分成本更高。",
          "reversible": true
        }
      ],
      "recommended_option": "separate-package"
    }
  ]
}
```

`trigger` 可为 `always`、`product-scope-change`、`knowledge-proposal-change`、
`architecture-proposal-change` 或 `oracle-difference`。动态变化若需要取舍却没有匹配
contract，close 返回 `UNSTRUCTURED_DECISION_REQUIRED`，不会临时生成一个空泛的
“批准全部”页面。Decision record 绑定当前 Work Item、tree、Evidence、contract hash
和 `selected_option`；多个未决事项必须逐个选择，取消不会写入记录。

历史已完成 Work Item/Approval 保持可读，但旧式非结构化 candidate 不能再物化，本地
review UI 也不再提供批量批准兼容入口。

## Proposal Compiler

`proposal_compiler.py` 把初始化规划连接到策略物化，但刻意保留四层边界：

1. `initialization-dag.json` 只描述 proposal 拓扑、约束与受信 Gate，不包含可执行权限；
2. `recipes/<proposal-id>.json` 由架构/业务分析写出完整 Work Item，编译器不会补写
   scope、AC、预算、Gate、Requirement、SourceLab 或知识合同；
3. `candidates/<proposal-id>.json` 与 `candidate-manifests/<proposal-id>.json`
   是 create-only 输出，manifest 冻结 DAG、recipe、依赖 Work Item、Evidence、
   Checkpoint 和 recovery lineage 摘要；
4. candidate 只有满足 `compiled-control-plane-v1` 才能由 `drive` 自动进入队列；
   否则保持结构化 blocker，恢复按钮不会被自动调用。

```bash
python3 ios/harness/proposal_compiler.py plan
python3 ios/harness/proposal_compiler.py compile IOS-KNOWLEDGE-INTEGRATIONS-001
python3 ios/harness/proposal_compiler.py check IOS-KNOWLEDGE-INTEGRATIONS-001
python3 ios/harness/loop_supervisor.py preflight \
  ios/project/work-item-proposals/candidates/IOS-KNOWLEDGE-INTEGRATIONS-001.json
```

依赖解析只接受直接完成、显式 `state.replacement`，或唯一的更高 revision
`knowledge.produces` recovery。新的非知识恢复 Work Item 用单值 `spec.recovers`
声明 predecessor；Harness 在它通过 Evidence、记忆事务和全部 Gate 后，才于 close
原子写入 predecessor 的 `state.replacement` 与 `WorkItemRecoveryBound` 哈希链事件。
predecessor 必须同 capability 且处于 blocked/rejected/exhausted/cancelled，已有不同
replacement、自引用、`depends_on` 冲突和 recovery cycle 都会 fail closed。
`recovery` 标签、标题与 `inputs.context_files` 只作为上下文，不再具有恢复 authority。
受保护 JSON Schema 的 authority 提升留给 Trusted Publisher；本地 Harness 先以严格
语义校验执行该字段，不能由 Agent 借恢复任务修改自己的 Schema。

由 Proposal Compiler 产生恢复任务时，DAG node 与 recipe Work Item 必须声明相同的
`recovers`。编译器在生成 candidate 前验证 predecessor 的 capability、终态和当前
replacement，并把 predecessor Work Item、runtime、Evidence、Checkpoint 的路径与
SHA-256 写入 manifest；其中任一事实变化都会让 `check` 变为 stale。Loop preflight
对手工 candidate 执行同一组检查，并拒绝已有未终结 recovery 的竞争写入。
`MaterializationPreview` 与 auto-materialization provenance 同样绑定该 predecessor，
因此错误恢复边不会先进入 ready queue 再等待 close 才暴露。

终态无恢复、replacement 成环、部分 knowledge output 覆盖或多个语义恢复候选都会保持
blocker。该 CLI 不改变 Harness queue/state/event/status/work-items，也不提供物化、
审批、发布或接受权威事实的命令。

知识 producer 终态退出但未写 artifact 时，reservation 不复用。独立 corrective
Work Item 可写 `business-knowledge/tombstones/**`，绑定原 producer 的 output、
terminal state、reason、Evidence 和 event lineage。Business Knowledge doctor 以
“物理 artifact + 有效 tombstone”检查 revision 连续性；tombstone 不提供 Claim、
Driver、Coverage 或 published authority，后续 recovery 必须使用下一 revision。

`compiled-control-plane-v1` 只授予“把已冻结 proposal 复制为本地 Work Item 并写入
queue/event/state/status”的权限。它不授予 Agent 超出 Work Item scope 的写权限，
不等同 Acceptance，也不允许知识发布、Golden 更新、ADR/Requirement 接受或 patch
promotion。策略每次都在 mutation lock 内重新核对 HEAD、clean 状态、manifest hash、
compiler check 和 preflight，不信任先前 `inspect` 的缓存结果。最高优先级并列、
未提交变化、manifest 漂移、Human Decision、`supersede`、critical risk 或 authority
scope 都会 fail closed，并给出稳定 blocker，不会退回一个“请确认”的橡皮图章。

## Codex exec Agent Adapter

`codex_agent_adapter.py` 是 Loop Supervisor 的 Codex CLI argv adapter。它使用稳定的
非交互 `codex exec`、显式 `workspace-write` sandbox、`never` approval 和 JSONL，
不会使用已弃用的 `--full-auto`，也不会启用 `danger-full-access`：

```bash
python3 ios/harness/codex_agent_adapter.py doctor \
  --codex /absolute/path/to/native/codex

python3 ios/harness/codex_agent_adapter.py smoke \
  --codex /absolute/path/to/native/codex \
  --codex-home /absolute/dedicated/codex-home

python3 ios/harness/loop_supervisor.py drive \
  --config ios/harness/codex-agent.example.json \
  --agent local-codex \
  --max-transitions 3
```

Codex CLI 的参数层级是兼容合同的一部分。当前 v3 adapter 的首次 turn 固定为：

```text
codex --sandbox <read-only|workspace-write> --ask-for-approval never \
  --cd <repo> exec --json --ignore-user-config -
```

续接固定为：

```text
codex --sandbox <read-only|workspace-write> --ask-for-approval never \
  --cd <repo> exec resume --json --ignore-user-config <thread-id> -
```

`sandbox`、`ask-for-approval` 和 `cd` 是顶层参数，不能放到 `exec` 或 `resume` 后面。
`doctor` 会实际探测 version、`exec --help` 和 `exec resume --help`，在 claim 前发现
CLI 漂移。`smoke` 总是创建临时 Git repo 并使用 `read-only`，连续执行首次 turn 和
同 thread resume，最后要求 repo clean；它只返回版本/hash、thread、事件计数、usage
和 stdout/stderr digest，不返回 prompt、agent message 或 stderr 内容。

示例中的 Codex executable 和 `CODEX_HOME` 必须替换为显式绝对路径；不要提交个人
路径或认证文件。adapter 只把专用 `CODEX_HOME` 路径传给单次 Codex 子进程，不读取、
复制、hash 或输出 `auth.json`；认证准备与清理由控制面在 adapter 外完成。宿主环境
按白名单重建，prompt 从 stdin 传入，最终 stdout 只含 thread、事件计数、usage 和
输出摘要。

成功 turn 的 thread ID 保存在忽略版本控制的
`.harness-runtime/codex-sessions/<work-item>.json`，绑定 Work Item hash 与 repo
commit；后续 transition 使用 `codex exec resume`。session 还绑定 adapter major
contract，旧 v1/v2 session 不会被 v3 静默复用。v3 prompt 还绑定
`implementation` / `memory_close` phase：前者只写候选，后者只在 passed Evidence
之后写记忆事务；`verify/close` 始终由 Supervisor 执行。失败、JSONL 漂移、
context 权限过宽或
绑定变化不会推进 session head。

若 `doctor` 报 `EXECUTABLE_BROKEN`、`VERSION_EXIT_NONZERO` 或其他 unavailable
reason，应先在控制面之外修复/重新安装 CLI，再重跑 doctor。adapter 不修改全局
安装。即使本地 CLI 可用，它仍与 Agent 共享用户权限；生产无人值守必须由隔离 runner
提供一次性凭据、签名 journal、受信复验和独立 patch promotion。

SwiftPM manifest 检查统一通过 `swiftpm_manifest.py`。适配器显式使用
`--disable-sandbox`，避免在 Codex workspace-write 内再次启动 `sandbox-exec`；
每次调用独立创建 SwiftPM cache/config/security/scratch 和 Clang module cache，
继承宿主环境但不覆写 `HOME`、`CODEX_HOME` 或使用宿主永久缓存，调用完成后立即清理。

## Trusted Supervisor Reference

`trusted_supervisor_reference.py` 把本地 cooperative loop 与生产边界之间最关键的
事务做成可执行 reference：

```bash
python3 ios/harness/trusted_supervisor_reference.py \
  --repo /absolute/repo \
  --control-root /absolute/external/control \
  --key-file /absolute/external/journal.key \
  doctor --base <commit>

python3 ios/harness/trusted_supervisor_reference.py \
  --repo /absolute/repo \
  --control-root /absolute/external/control \
  --key-file /absolute/external/journal.key \
  run-attempt --base <commit> --work-item <id> \
  --config /absolute/external/attempt-config.json
```

control root、0600 HMAC key 和 attempt config 必须位于 repo 外。runner 从明确 base
创建一次性 Agent worktree，以 secret-free argv 启动单 writer，冻结 tracked、
untracked、rename、delete 和 binary 变化并执行 Work Item scope；随后从同一 base
创建第二个干净 verifier worktree，重放 binary patch、核对 tree digest 并运行独立
verifier。通过后只生成 0600 patch、签名 manifest 和签名 journal 终态。

该 reference CLI 故意没有 promotion/merge/push/approval/publish 权限。HMAC 只证明
“持有本地外部 key 的 reference 进程”生成了记录，不等同企业身份、KMS/HSM 或透明
日志；git worktree 也不提供容器/VM、网络 deny、Keychain 或内核资源隔离。生产实现
仍需把 key/journal/publisher 放到 Agent 不可达的服务，使用一次性凭据、受保护 Gate、
deny-by-default egress、资源上限和独立 patch promotion。
