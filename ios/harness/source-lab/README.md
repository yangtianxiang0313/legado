# SourceLab

SourceLab 把受版本控制的离线响应同时暴露为 `FixtureTransport` 输入和一次绑定的 IPv4 loopback 网站。它用于稳定复现网站行为，不是兼容性答案；书源解析结果仍由固定 Android commit 生成的受保护 golden 判定。

常用命令：

```bash
python3 ios/harness/source-lab/source_lab.py doctor --root .
python3 ios/harness/source-lab/source_lab.py verify-site --root . --scenario sl-html-basic-001
python3 ios/harness/source-lab/source_lab.py build-source --root . --scenario sl-html-basic-001
python3 ios/harness/source-lab/source_lab.py serve --root . --scenario sl-html-basic-001
```

`serve` 只绑定 `127.0.0.1:0`，打印实际 origin。把该 origin 传给 `build-source --origin` 即可得到当前运行实例的书源。逻辑 origin 始终是 `http://sourcelab.test`，随机端口不得进入 golden 或 canonical envelope。

场景位于 `ios/harness/fixtures/source-lab/<id>/`。`case.json` 只描述请求、原始响应、资源上限、来源与覆盖行为，禁止保存业务 expected result。新增能力时先在 coverage policy 登记，再按每个 behavior 分别增加 nominal/boundary/malformed/denied case-role，并绑定 Android Fact/branch；Android golden、iOS 实现和场景不得由同一工作项同时修改。

`source_lab.mode=reuse` 默认只接受已经晋级的 `reference` 场景。唯一例外是
Android Oracle characterization：它可以消费一个 `candidate`，但必须同时满足
`android-oracle` 与 `candidate-only` 标签、`requirements.mode=characterization`、
无 Gate、唯一依赖该场景的已完成 `introduced_by` WorkItem，并且写范围不得覆盖
Fixture、SourceLab 控制文件、Golden、Publisher、Workflow 或产品代码。这个例外只赋予
“运行并生成 local candidate”的权限，不会把场景变成 reference，也不带发布权限。
