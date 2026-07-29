# Android Golden Publisher

这里是独立 GitHub Publisher 的 staging 逻辑，不是普通 Harness/Oracle CLI 的一部分。

`android_golden_publisher.py prepare --scenario <id>` 必须先调用 Oracle source
commit 中的
`trusted_import.py` 完成双 attestation、repository、workflow、source、run 和
scenario/payload 绑定验证。它只允许把结果写到仓库外的新目录，输出：

- `manifest.json`
- `android-legado-v1/<scenario>.json`
- `releases/<scenario>-<run>-<attempt>.json`

`--oracle-root` 是只读历史验证根，`--root` 是当前 request SHA 的发布基底；两者必须
分离。Publisher 从历史根加载 Oracle contract 并验证 attestation，但始终在当前基底
Manifest 上追加事务，避免较早 Oracle commit 覆盖期间已发布的其他 fixture。

manifest schema v2 在每个 fixture entry 上独立绑定 Android commit、profile、
runner、runner image、canonicalizer 和 authorization；旧 schema v1 entry 在 staging
时确定性迁移，不再要求所有 fixture 共享同一 Runner。完全相同的已发布事务是幂等
`already_published`，任何同 ID 不同内容都 fail closed。

脚本本身不修改仓库、不提交、不推送。唯一安装方
`.github/workflows/android-golden-publisher.yml` 只监听
`feature/golden-<scenario>-<exact-sha>` 的 create-only push，从该提交中的唯一
verified-candidate Receipt 重新验证 Oracle Run/Artifact 与双 attestation，然后把
三个文件提交为 request SHA 的唯一子提交到
`golden/result-<scenario>-<request-sha>`。Workflow 不使用 Environment、
`workflow_dispatch`、PR 或人工 Gate；同时上传 run-bound `publisher-result.json`
供本地 Dispatcher 验证 result branch/commit/digest 后执行受限 fast-forward。

普通 Agent、Harness、Oracle runner、candidate packager 和 trusted importer 都没有
Golden 写权限。result branch 只能 create-only；回滚通过新 revert commit 完成，不能
覆写历史 release receipt。

## Business Knowledge Publisher

`business_knowledge_publisher.py prepare` 消费同一已完成 Work Item 产生的 Packet/Driver
proposal、受保护 Android Golden release receipt、精确 Requirement clauses、目标
Work Item、发布 run 和 source commit。它逐条重算：

- proposal 原始文件摘要、schema、authority、producer Work Item、Evidence 与 Checkpoint；
- Golden manifest/release/payload authority 及 Android commit、runner、canonicalizer；
- 每条 `runtime_verified` Claim 的 JSON Pointer 与 canonical observed SHA-256；
- Driver 的精确 Claim 集合、resolved ADR；
- 新 authority digest、Requirement Catalog digest、architecture digest 和一 Claim
  一 Coverage entry。

输出仍只能位于仓库外的新目录，目录中按仓库相对路径保存 published Packet、resolved
Driver、Coverage Ledger、派生 Catalog 和不可变 release receipt，并额外包含
`transaction.json`。事务明确列出每个安装文件的 SHA-256 与两个待删除 proposal；脚本
本身不修改源仓库。

`.github/workflows/business-knowledge-publisher.yml` 是唯一安装方。它固定
`business-knowledge-publisher` Environment、用户、目标分支、source commit、两个
proposal 摘要和 Golden receipt 摘要；安装后只允许事务声明的七个路径变化，重跑
Business Knowledge doctor、Harness doctor 和 Demand Compiler，再推专用发布分支并
创建 PR。它不能直接推目标分支，也不能修改 Requirement、Golden、ADR 或产品代码。
回滚通过 revert Publisher PR 完成；已发布 receipt 不允许被后续普通任务覆写。
