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

## Hash contracts

- Control JSON hashes are SHA-256 of the parsed document emitted with exact
  number tokens, sorted object keys, UTF-8, and no trailing newline.
- A generic fixture hash is SHA-256 of the canonical array of sorted
  `{path, sha256(raw_file_bytes)}` entries. It is not a SourceLab scenario hash.
- Payload hash and byte count bind the same raw bytes. A payload must already be
  canonical-v1 bytes.
- Proposal bindings cover the frozen Android commit/tree, clean checkout,
  runner/image digests, protected request work item, baseline, generic fixture
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

The exact parser preserves arbitrary number tokens, rejects duplicate and
canonically-equivalent object keys, non-finite values, invalid UTF-8, unpaired
surrogates, excessive nesting, and oversized inputs. Object keys are preserved;
their deterministic order uses NFC identity followed by raw UTF-8.
