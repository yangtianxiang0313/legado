# Android Golden Publisher

这里是独立 GitHub Publisher 的 staging 逻辑，不是普通 Harness/Oracle CLI 的一部分。

`android_golden_publisher.py prepare` 必须先调用 source commit 中的
`trusted_import.py` 完成双 attestation、repository、workflow、source、run 和
payload 绑定验证。它只允许把结果写到仓库外的新目录，输出：

- `manifest.json`
- `android-legado-v1/sl-html-basic-001.json`
- `releases/sl-html-basic-001-<run>-<attempt>.json`

脚本本身不修改仓库、不提交、不推送、不创建 PR。只有
`.github/workflows/android-golden-publisher.yml` 在
`android-golden-publisher` Environment 获得用户批准后，才能把上述固定集合安装到
专用发布分支并创建 PR。目标分支禁止直接推送；PR 的最终批准和合并由 GitHub 用户身份
执行并留下审计记录。

普通 Agent、Harness、Oracle runner、candidate packager 和 trusted importer 都没有
Golden 写权限。回滚通过 revert Publisher PR 完成，不能覆写历史 release receipt。

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
