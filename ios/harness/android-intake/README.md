# Android Requirement Intake

该目录把固定 Android commit 中的源码事实提取为确定性 Fact Inventory，并验证已接受 Requirement Catalog。它只做机械事实提取和引用校验，不把源码声明直接解释为运行语义，也不生成 iOS expected result。

```bash
python3 -B ios/harness/android-intake/android_intake.py inventory --root .
python3 -B ios/harness/android-intake/android_intake.py catalog --root .
python3 -B ios/harness/android-intake/android_intake.py doctor --root .
python3 -B ios/harness/android-intake/android_intake.py selection --root . --work-item IOS-SOURCE-FORMAT-001
```

新增 extractor、sensor、accepted Requirement 或 baseline 必须走受保护变更。普通实现工作项只能读取其 selection，不能修改这些输入。
