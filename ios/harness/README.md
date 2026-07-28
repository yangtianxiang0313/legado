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
- 显式启用 `supervisor-owned-verification-v1` 后，单次工作项按 Agent edit →
  Supervisor verify → Agent memory → Supervisor close 推进。Agent 不能通过直接调用
  `verify/close` 改变控制状态；Supervisor 在每个 Agent turn 后核对 event/status/
  Evidence binding，并独立产生验收 Evidence；
- required checks 在 Supervisor 宿主进程中运行，不继承 Codex workspace-write 对
  loopback、SwiftPM 二级 sandbox 或 iOS Simulator 的限制；验证失败仍由 Harness
  决定 implementing/rejected/exhausted，下一轮 Agent 读取最新 Evidence 后修复；
- 每次 Agent 调用都在新的 session/process group 中启动；超时按 TERM → 有界等待 → KILL 回收完整进程树，并结构化返回 `timed_out`、`process_leak`、`cleanup_error`；
- Supervisor 只向 adapter 传递显式环境白名单和临时 context 路径，结果只保留输出长度与 SHA-256，不回显 context、stdout/stderr 或宿主环境 secret；
- 普通候选不再要求点击确认：自动策略要求 repo/index clean，candidate、recipe、
  DAG、manifest 和依赖 provenance 都是 HEAD 中的普通文件，且 compiler 可重算、
  `gates=[]`、Requirement 为 `control_plane`、知识只产生 proposal、不修改产品、
  架构、配置、Schema、Golden、Approval 或 authority；
- `materialize-review` 仅保留为自动策略无法覆盖时的显式恢复入口，不是正常推进 Gate；
- CLI 没有非交互 `materialize` 或 `approve`，也不会更新 golden、发布知识或接受 ADR。

本地 Loop Engine 的成熟边界是：确定性 inspect、策略物化、受限 argv
adapter、真实 Harness 生命周期、Evidence/Capability/Checkpoint/Event 绑定，以及
进程树有界回收均有自动化 E2E。它足以在单机、单写者、真实 Human Decision 保留的前提下持续
推进工作项。

本地按钮产生的仍是 `local_unverified` 协作事实。跨机器无人值守、并行 DAG 调度、
签名控制状态、真实 Integrations 扫描和发布晋级，仍必须由隔离、签名的外部
Supervisor/CI 重验；这些属于下一阶段，不由本地 adapter 冒充。

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
`knowledge.produces` recovery。终态无恢复、replacement 成环、部分覆盖或多个恢复候选
都会保持 blocker。该 CLI 不改变 Harness queue/state/event/status/work-items，也不提供
物化、审批、发布或接受权威事实的命令。

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
