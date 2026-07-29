# iOS 验收基础设施

自动推进已经迁移到 [`ios/loop`](../loop/README.md)。本目录不再包含 WorkItem、
Supervisor、Recovery 或人工 Gate 控制面，只保留可复用的验收基础设施：

- `fixtures/` 与 `source-lab/`：稳定书源刺激和本地网站；
- `goldens/`：受保护 Android 运行结果；
- `oracle/`：Android characterization 与 canonical comparison；
- `business-knowledge/`、`android-intake/`：业务知识和冻结源码事实检查；
- `probes/`：Swift package、依赖和 fixture 结构检查。

常用命令：

```bash
python3 -B ios/loop/loop.py doctor
python3 -B ios/harness/source-lab/source_lab.py verify-site \
  --root . --scenario sl-html-basic-001
python3 -B -m unittest discover -s ios/harness/source-lab/tests -p 'test_*.py'
swift test --package-path ios/Packages/LegadoKit --disable-automatic-resolution
```
