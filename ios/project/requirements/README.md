# Requirement Catalog

`accepted/` 保存已接受、不可原地改写语义的 Requirement revision；变化通过新 revision 与 `supersedes` 表达。`catalog.json` 由 Android Intake 确定性生成。

Requirement 的 `accepted` 只表示它已进入产品范围，不等于已具备实现条件。`readiness.state=characterization_required` 时，只能创建 characterization、SourceLab、Oracle 或基础设施工作项，不能直接创建 iOS 行为实现任务。

Android 源码事实、iOS 产品决定和 iOS 工程前置必须分开标注。AI 草稿进入 `ios/project/requirement-proposals/`，不能自行移动到 `accepted/`。
