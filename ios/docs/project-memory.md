# 项目记忆机制

## 1. 八类权威事实

| 事实域 | 权威源 | 回答的问题 |
|---|---|---|
| 设计意图 | `docs/architecture.md`、accepted ADR、能力契约 | 应该怎样？ |
| 实际实现 | Swift/Kotlin 源码、Package.swift、数据库 schema | 现在怎样？ |
| Android 源事实 | Fact Inventory | 固定 baseline 机械证明了什么？ |
| 产品需求 | accepted Requirement Catalog | 哪些行为进入产品范围、成熟到哪一步？ |
| 兼容基准 | `project/baseline.json`、fixture、Android golden | 要对齐什么？ |
| 验证事实 | Harness Evidence | 当前代码是否满足？ |
| 书源环境能力 | SourceLab coverage policy + manifest | 哪些网站行为已有正反 reference 场景？ |
| 当前进度 | capability state、`project/state.json` | 接下来做什么？ |

AI 对话、scratch、PR 描述、手写 dashboard、无输入指纹的截图和“我记得”都不是权威源。冲突时按领域解释：契约给期望，代码给事实，Evidence 给判定，State 只汇总。

## 2. 文件分类

```text
ios/project/
├── baseline.json
├── android-intake/            # 固定 baseline 的确定性 Fact Inventory
├── requirements/              # accepted Requirement 与生成的 Catalog
├── requirement-proposals/     # AI 候选，非权威需求
├── state.json
├── status.md                 # Harness 生成，人类只读
├── events.jsonl              # Harness 写入的哈希链
├── capabilities/             # 一项能力一个当前快照
├── checkpoints/              # 每个完成工作项的交接摘要
├── compatibility/            # COMP-*：Android/iOS 行为差异
├── pitfalls/                 # PIT-*：非显然、可复发知识
├── approvals/                # 人工门禁记录
└── archive/                  # release/季度压缩摘要

ios/docs/adr/                 # ADR-*：长期设计决策
ios/harness/evidence/         # 结构化验证事实
```

禁止所有人向一个 `notes.md` 或 `memory.log` 追加流水账。能力、ADR、COMP、PIT 都是独立 ID 文件，降低冲突并便于精确取上下文。

## 3. 能力状态

能力快照只保存当前事实：契约、owner Target/path、声明状态、profile 支持、依赖、open COMP/PIT/blocker、required/latest Evidence、最多五个 next action、revision 与 `updated_by`。

状态允许：

```text
proposed → implementing → partial → verified
                   ↘ blocked
verified → regressed / stale / partial
任意状态 → deprecated
```

`declared_status=verified` 不足以证明完成。有效状态还要求 required Evidence 通过、未过期、输入 digest 一致且 baseline revision 未落后，否则由 Harness 计算为 stale/regressed/incomplete。架构输入采用内容寻址摘要，覆盖 `architecture.md`、`dependencies.md`、可执行架构规则以及全部 accepted ADR；其中任一内容变化都会使旧 Evidence 失效。

能力文件带 `revision`。claim 记录 base revision；close 时若 revision 已被他人改变，必须中止并语义合并，禁止最后写入者覆盖。

## 4. 四种长期记录

### ADR

记录架构、协议、依赖、安全能力、并发所有权、存储模型及接受兼容差异。accepted ADR 不改写决定正文；新决策通过 `supersedes` 替代。

### COMP

只要 Android 与 iOS 输出不同，就记录 fixture、双方观察、分类、决策、影响 profile、严重性、原因、修复/变通和验证。`intentional_difference` 必须引用 accepted ADR。

### PIT

只记录非显然、复发概率高、跨模块/版本相关且有诊断或预防办法的问题。以 fingerprint 去重；复发时更新次数，不新建重复记录。普通编译错误、日志和堆栈不长期保存。

### Checkpoint

每个 work item 的收尾事务，引用 passing Evidence、能力 revision、架构影响、Requirement revision/clause/selection digest、SourceLab mode/behavior/scenario/selection digest、COMP、PIT、剩余风险和可执行下一步。聊天中断后，新 AI 从 checkpoint 续作。

模板位于对应目录的 README/template 文件。

## 5. 开始与结束清单

开始时按顺序读取：baseline → Android facts → accepted Requirement → architecture → capability → active ADR → open COMP/PIT → latest Evidence → work item → SourceLab selection → 相关代码。`harness context` 只聚合引用，不复制新的权威文档。

结束时必须确认：

- acceptance 是否全部执行并生成 Evidence；
- capability revision/status 是否更新；
- 差异是否创建 COMP；
- 新知识是否达到 PIT 标准；
- 是否触发 ADR/人工门禁；
- next actions 是否准确且不超过五项；
- checkpoint 是否能让另一个 AI 无聊天上下文续作；
- doctor、memory lint 和架构检查是否通过。

若确无长期变化，要在 checkpoint 填明确原因，不能创建空洞记录。

## 6. 过期与矛盾检测

`doctor` 检查：Android inventory/catalog 可复现、Fact 无静默遗漏、Requirement revision/clause 引用有效、claim 后 selection drift、Evidence 缺失/失败/过期、baseline 落后、resolved COMP fixture 仍失败、PIT 无预防测试、被 supersede ADR 仍活跃、orphan 引用、过期 claim、能力 revision 冲突、模块图与 Package.swift 不一致、status.md 非最新。

## 7. 控制体积

长期保留当前 baseline/architecture、active/accepted ADR、每项能力快照、open COMP/PIT、每个 suite 最新成功和失败 Evidence、release Evidence。归档 completed work、已解决超过两个 release 的 COMP/PIT、superseded ADR 索引和旧 Evidence manifest。

不长期保留聊天全文、完整构建日志、stack trace、每日流水、重复失败、xcresult/截图/DOM dump 本体以及仅复述 git diff 的实现细节。

季度或 release 压缩时生成 summary 和 manifest，保留原 ID、结论、commit range 与 checksum。禁止压缩 open record、active ADR 和 latest Evidence，也不把 Markdown/JSON 压成 zip 放 Git。
