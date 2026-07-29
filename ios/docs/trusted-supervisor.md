# 外部执行边界

本地 Minimal Loop 是协作式范围与验收约束，不是恶意代码安全沙箱。真正需要外部权威
的只有不能由 iOS 实现者自证的结果，当前主要是：

- 固定 Android 源码运行得到的 Oracle 输出；
- Android Golden 的 create-only 发布和内容摘要；
- CI 在冻结代码树上的最终复验。

这些结果由 GitHub Workflow/独立 runner 产生并以 commit、artifact 和 SHA-256 绑定。
普通实现 Task 不能修改 Golden。产品实现、业务知识整理和任务推进不再设置人工 Gate。
