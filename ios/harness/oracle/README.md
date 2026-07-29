# Android Oracle candidate control plane

This directory is a read-only validator. It accepts candidate artifacts, proves
their internal bindings, canonicalizes exact JSON, and compares protected shared
channels. It cannot publish, accept, record, promote, or update a golden.

Commands:

```text
doctor
canonicalize --input FILE
compare --expected-payload FILE --actual-artifact FILE
verify-proposal --proposal FILE --request-work-item ID
```

Every command also requires `--root REPOSITORY`. Output is stdout only; there is
no output-path or in-place option.

`--request-work-item` 是 v1 artifact 字段的兼容名称；实际授权源已经迁移到
`request-registry.json`，不再读取 WorkItem 文件。新增场景只需增加一个紧凑、
唯一的 scenario/request 绑定。

## Hash contracts

- Control JSON hashes are SHA-256 of the parsed document emitted with exact
  number tokens, sorted object keys, UTF-8, and no trailing newline.
- A generic fixture hash is SHA-256 of the canonical array of sorted
  `{path, sha256(raw_file_bytes)}` entries. It is not a SourceLab scenario hash.
- Payload hash and byte count bind the same raw bytes. A payload must already be
  canonical-v1 bytes.
- Proposal bindings cover the frozen Android commit/tree, clean checkout,
  runner/image digests, protected request registry entry, baseline, generic fixture
  manifest, Fact inventory, Requirement catalog, envelope schema, canonicalizer
  config/implementation, and comparator implementation.

The repository validator does **not** prove that a claimed runner, commit, or
attestation actually produced the payload. The trusted external Supervisor must
verify CI identity, job inputs, signatures, and attestation before a separate
publisher may change protected goldens. A valid proposal always remains
`candidate_only`.

## Comparison contract

The shared view compares envelope identity/profile, request plan, decode,
stages, result type, `portable_known_projection`, and issues. Android
`android_characterization`, iOS `ios_lossless_extension`, and engine
platform/revision are explicit extensions or provenance and are not compared.
Unknown result lanes fail closed.

## Android WebBook candidate runner

`android-runner/orchestrator.py` 是首条 SourceLab 业务 characterization 的本地
runner，命令只有 `doctor` 与 `run`。它从 `baseline.android_oracle.git_commit`
创建临时 detached worktree，验证 `app/src/main`、`modules` 与 Gradle 产品输入相对
冻结 commit 无漂移，然后只把内容寻址的 instrumentation test 叠加到
`app/src/androidTest`。仓内 Android 产品源码保持不变。

真实执行要求一个已启动、已 boot、且没有安装 `io.legado.app.debug` /
`io.legado.app.debug.test` 的专用模拟器：

```text
python3 ios/harness/oracle/android-runner/orchestrator.py doctor --root .
python3 ios/harness/oracle/android-runner/orchestrator.py run \
  --root . \
  --adb /absolute/android-sdk/platform-tools/adb \
  --serial emulator-5554
```

`doctor` 与 `run` 都接受显式 `--scenario`。省略时仍运行既有 reference
`sl-html-basic-001`；POST Form characterization 使用：

```text
python3 ios/harness/oracle/android-runner/orchestrator.py doctor \
  --root . \
  --scenario sl-post-form-001
python3 ios/harness/oracle/android-runner/orchestrator.py run \
  --root . \
  --scenario sl-post-form-001 \
  --adb /absolute/android-sdk/platform-tools/adb \
  --serial emulator-5554
```

Runner 使用 Gradle `--offline` 打包 baseline worktree；依赖和 Android SDK 必须由
控制面预先准备。运行时 SourceLab 只绑定本机 `127.0.0.1:0`，并通过该 serial 的
精确 `adb reverse tcp:<port> tcp:<port>` 暴露给设备。设备 source、全部 request 和
结果 URL 在 artifact 中恢复为 `http://sourcelab.test`，任何外部 authority、设备
端口泄漏、nominal case 异常或用例选择漂移都失败。结束时移除 reverse、卸载本次安装
的 debug/test 包并强制回收临时 worktree；若设备上预先存在同名包则运行前直接拒绝，
避免覆盖开发者数据。

输出固定在 `.harness-runtime/android-oracle/` 的 0600 文件，标记
`local_unverified/candidate_only`，绑定 Android commit/tree、Runner、Fixture、
SourceLab scenario、source/input/case 与 canonicalizer digest。它不是 Golden，也
不含 attestation 或发布权限。只有仓外受信 workflow 在相同输入上重跑、签名并生成
`android_oracle_proposal` 后，独立 publisher 才能晋级受保护 Golden。

`sl-post-form-001` 仍由冻结 Android 的真实 `WebBook.searchBookAwait` 发出请求；
Runner 同时从同一次 source/keyword 输入构造真实 `AnalyzeUrl`，输出 `POST` method、
逻辑 URL、headers、UTF-8 body、`body_base64` 与有序 `form_fields`。归一化器要求
body bytes 与 base64 精确一致，保留重复字段经 Android `LinkedHashMap` 处理后的最终
值与顺序。该结构化输出是可审查的 Android 真值候选，不会从 SourceLab input 或响应
HTML 推导 iOS expected。

## GitHub-hosted 双证明提案链

`.github/workflows/android-oracle-attestation.yml` 保留显式 scenario choice 的人工
`workflow_dispatch`，并接受 `feature/oracle-*` branch push，在 `ubuntu-24.04`
GitHub-hosted runner 上执行。push ref 必须精确为
`feature/oracle-<allowlisted-scenario>-<40位GITHUB_SHA>`；Workflow 的第一个 step
按 event、ref 与 source SHA fail closed 地解析唯一 `ORACLE_SCENARIO`，之后 doctor、
run、prepare、finalize 与 artifact name 只消费该 selector 输出。create-only branch
因此成为 GitHub 服务端可查询的创建事实，run-name 同时暴露完整 ref。它不读取
repository secrets，不提交分支，不上传 APK，也不接触外部书站。官方 actions 均固定
到完整 commit SHA；job 权限只有 `contents:read`、`id-token:write` 和
`attestations:write`。

dispatch 的 `scenario` 是显式 choice，默认保持 `sl-html-basic-001`，并支持
`sl-post-form-001`。packager 不把 selector 当路径使用：它按仓内 SourceLab manifest
解析 allowlist，并核对场景状态、路径、scenario digest、完整 SourceLab manifest
digest 与 `input.json` digest。unknown、retired、路径穿越、digest 漂移或跨场景
archive 重放都会失败关闭。Orchestrator 的 `doctor` 和 `run` 均收到同一个显式
`--scenario`。

CI 分为两个不可交换的证明阶段：

真实 GitHub run `30401218234` 已完成冻结 Android Oracle 步骤，但旧版 evidence
prepare 随后失败：真实 RequestPlan 含 `User-Agent`，canonical-v1 合同要求 header
名 ASCII 小写，而 packager 把这个合法转换误报为
`PAYLOAD_CANONICALIZATION_DRIFT`。修复只更正下述 prepare 转换边界；不重跑或改写
该失败 run。

1. 在线阶段只安装明确的 Android 35 system image，并把冻结 baseline 的 Gradle 依赖
   预热进 cache；实际 Orchestrator 仍使用 `--offline`，网络面仍只有本次 SourceLab
   loopback 与精确 `adb reverse`。
2. `ci_proposal.py prepare` 把 Android local-run 转成 canonical-v1 payload，并生成
   确定性的 `android-oracle-evidence.tar`。它保留原始 local-run 与 artifact 的
   SHA-256 provenance 绑定，同时以 canonicalizer 的返回 bytes 作为 evidence
   payload：只执行 header 名 ASCII 小写、换行 LF、固定 ignore pointers 与 object
   key sort，不要求 Android raw payload 预先 canonical。GitHub OIDC/Sigstore 先为
   这个 evidence subject 生成 provenance attestation。
3. `ci_proposal.py finalize` 才能生成 candidate proposal。proposal 内绑定上一步
   attestation URL、原始 bundle SHA-256、scenario/source/input/manifest digest、
   Android baseline、Runner 与 canonical payload。
4. 确定性的 `android-oracle-proposal.tar` 作为第二个独立 subject 再生成 provenance
   attestation。这样 proposal 不需要把“自己的签名哈希”嵌入自己，避免不可解的循环
   哈希。

workflow artifact 只包含以下 review inputs，保留 14 天：

```text
android-oracle-evidence.tar
android-oracle-proposal.tar
evidence-attestation.json
proposal-attestation.json
SHA256SUMS
```

下载指定 run 的 artifact 后，必须在与该 run 相同的 source commit 上执行：

```text
python3 -B ios/harness/oracle/trusted_import.py verify \
  --root . \
  --proposal-archive /absolute/review/android-oracle-proposal.tar \
  --proposal-attestation-bundle /absolute/review/proposal-attestation.json \
  --evidence-archive /absolute/review/android-oracle-evidence.tar \
  --evidence-attestation-bundle /absolute/review/evidence-attestation.json \
  --repository yangtianxiang0313/legado \
  --scenario sl-post-form-001 \
  --gh /absolute/path/to/gh
```

Importer 会对两个 archive 分别执行 `gh attestation verify`，固定 repository、
signer workflow、当前 `HEAD` source digest、SLSA provenance，并拒绝 self-hosted
runner；之后才安全读取 tar、核对 evidence bundle、run identity、payload、Runner
environment 和 proposal contract。成功结果仍是
`candidate_only/verified_for_human_review`，下一 authority 明确为
`independent_golden_publisher`。
Importer 要求调用者重述 scenario selector，并从仓内 manifest 复算同一组 digest；
因此 HTML evidence 不能作为 POST proposal 重放，反之亦然。

`ci_proposal.py` 只有 `environment`、`prepare`、`finalize`；
`trusted_import.py` 只有 `verify`。两者均没有 `accept`、`publish`、`promote`、
`record` 或 `update-golden`，也不会写 `ios/harness/goldens`。GitHub attestation
只证明“哪个 workflow、在哪个 source commit 生成了哪些 bytes”，不证明业务结果应被
接受；首个 Golden 仍需独立 Publisher 审查 Android portable mapping 后完成受保护
晋级。

The exact parser preserves arbitrary number tokens, rejects duplicate and
canonically-equivalent object keys, non-finite values, invalid UTF-8, unpaired
surrogates, excessive nesting, and oversized inputs. Object keys are preserved;
their deterministic order uses NFC identity followed by raw UTF-8.
