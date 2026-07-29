# Android Requirement Intake

该目录把固定 Android commit 中的源码事实提取为确定性 Fact Inventory，并验证已接受 Requirement Catalog。它只做机械事实提取和引用校验，不把源码声明直接解释为运行语义，也不生成 iOS expected result。

```bash
python3 -B ios/harness/android-intake/android_intake.py inventory --root .
python3 -B ios/harness/android-intake/android_intake.py catalog --root .
python3 -B ios/harness/android-intake/android_intake.py doctor --root .
```

新增 extractor、sensor、accepted Requirement 或 baseline 时，需要重建 inventory 与 catalog。Minimal Loop v2 的 Task 直接引用相关 Requirement、Android 源码锚点和 Golden，不再生成 WorkItem selection 投影。
