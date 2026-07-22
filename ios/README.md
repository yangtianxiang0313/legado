# Legado iOS

这里是 Legado iOS 兼容性重写的控制面和后续产品代码根目录。目标不是逐类翻译 Android，而是保留书源与阅读行为兼容性，同时用原生 iOS 架构重新实现。

## 五个互相约束的系统

1. **Android Requirement Intake**：从固定 Android commit 提取可验证 Fact，发布带证据成熟度的 Requirement Catalog。
2. **架构契约**：规定模块、依赖方向、并发所有权、数据流和发布 profile。
3. **AI Harness**：从 Requirement 编译出的工作队列选择任务，限制写入范围，执行固定验收并生成与代码树绑定的 Evidence。
4. **项目记忆**：保存当前能力状态、ADR、兼容差异、Pitfall、checkpoint 和冻结基准。
5. **SourceLab**：把受版本控制的响应同时作为离线 FixtureTransport 和本地书站，按 behavior case-role 持续扩展书源环境能力。

AI 只有在五者同时一致时才能声明一项能力完成。

## 入口

- [架构设计](docs/architecture.md)
- [Android 源码驱动需求机制](docs/android-requirement-intake.md)
- [依赖治理](docs/dependencies.md)
- [测试与跨端一致性](docs/testing-and-conformance.md)
- [SourceLab 本地书源模拟系统](docs/source-lab.md)
- [AI 自动推进协议](docs/ai-harness.md)
- [可信 Supervisor 与无人值守边界](docs/trusted-supervisor.md)
- [项目记忆](docs/project-memory.md)
- [路线图](docs/roadmap.md)
- [当前状态](project/status.md)

## 立即可用的命令

```bash
python3 ios/harness/harness.py doctor
python3 -B ios/harness/android-intake/android_intake.py doctor --root .
python3 ios/harness/harness.py next
python3 ios/harness/harness.py context IOS-BOOT-001
python3 -m unittest discover -s ios/harness/tests -p 'test_*.py'
python3 ios/harness/source-lab/source_lab.py verify-site --root . --scenario sl-html-basic-001
```

领取并推进任务：

```bash
python3 ios/harness/harness.py claim IOS-BOOT-001 --agent codex-main
python3 ios/harness/harness.py verify IOS-BOOT-001
python3 ios/harness/harness.py close IOS-BOOT-001
```

`close` 前必须按 schema 写 checkpoint 并更新能力状态。Harness 不提供 golden 更新命令；golden 只能走独立、受保护的人工工作流。

## 计划中的产品目录

```text
ios/
├── Apps/
│   ├── LegadoStoreSafe/
│   └── LegadoFullCompat/
├── Packages/LegadoKit/
│   ├── Package.swift
│   ├── Sources/
│   └── Tests/
├── harness/
│   ├── android-intake/
│   ├── source-lab/
│   └── fixtures/source-lab/
├── docs/
└── project/
```

当前提交先建立设计、推进器和记忆系统；第一个工作项负责生成并验证 Swift Package 骨架。
