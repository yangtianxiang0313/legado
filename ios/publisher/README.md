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
