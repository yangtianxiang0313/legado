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

Business Knowledge 与 Requirement 已切换到 Minimal Loop v2 的普通知识任务：直接
绑定源码锚点、真实 Android Golden 和完成事件，不再经过 WorkItem/Evidence/Checkpoint
发布器或人工 Gate。稳定知识仍由 `business_knowledge.py doctor` 校验；详细运行产物
不进入 Git。
