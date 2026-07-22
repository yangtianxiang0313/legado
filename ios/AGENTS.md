# Legado iOS AI 开发契约

本目录由 AI 和人共同维护。所有修改必须遵守以下规则；更深目录不得放宽这些规则。

## 开始任务前

1. 运行 `python3 ios/harness/harness.py doctor`。若失败，先停止并报告，不得把红色基线当作本任务问题顺手修复。
2. 运行 `python3 ios/harness/harness.py next`，只处理 Harness 选择的一个工作项。
3. 阅读以下文件：
   - `ios/project/state.json`
   - `ios/project/baseline.json`
   - 当前工作项绑定的 Android Fact 与 accepted Requirement revision/clause
   - `ios/docs/architecture.md`
   - 当前工作项列出的 `architecture_refs`、ADR、能力状态和上下文文件
4. 使用 `claim <WORK_ITEM_ID> --agent <稳定标识>` 领取工作项。未领取不得修改产品代码。
5. 只修改工作项 `scope.allow_write` 允许的路径。已有、但与本任务无关的用户修改不得覆盖或清理。

## 实现期间

- 依赖必须符合 `ios/harness/architecture-rules.json`；不得反转依赖方向。
- 不得自行新增或升级三方依赖、Target、数据库迁移、公开协议、权限或 Runtime capability。
- 不得把 Android 字段/方法声明直接解释为产品需求；只实现 Work Item 绑定的 accepted Requirement clause。运行行为未达到 `implementation_ready` 时只能补 characterization/场景/Oracle 前置。
- 不得修改 accepted Requirement、Fact Inventory、Requirement Catalog 或 intake policy 来让当前工作项通过；发现事实漂移必须停止并报告 `REQUIREMENT_DRIFT`。
- 不得修改 golden、兼容 normalizer、Harness schema、门禁或验收命令来让失败变绿。
- 书源行为工作项必须声明 `spec.source_lab`。扩展场景时只能写 candidate，不能在同一工作项修改 Android golden 或产品实现；SourceLab 场景不得保存业务 expected result。
- 不得删除、跳过或弱化测试，不得以扩大超时掩盖不确定性。
- 一次只推进一个工作项；子代理可以并行调研，但同一时刻只能有一个写入者。
- 发现 Android 与 iOS 差异时，先生成兼容差异记录；Android 是行为基准，不代表所有行为都应无条件复制。
- 出现非显然、可复发且已有预防办法的问题时，更新或新增 Pitfall；普通编译错误不进入长期记忆。
- 触发 ADR 条件时停止实现；仅当当前工作项明确允许写入一个新 ADR 时才起草 proposed ADR，否则报告并请求独立决策工作项，然后等待人工决定。

## 结束任务前

1. 运行 `verify <WORK_ITEM_ID>`；验收命令由 Harness 决定。
2. 只有验证成功后，才可写 `ios/project/checkpoints/<WORK_ITEM_ID>.json`。
3. 同一变更中更新能力状态，并明确填写：
   - Requirement clause 与 selection digest；
   - 验证证据；
   - 架构是否变化；
   - 是否有兼容差异；
   - 是否有值得长期保留的 Pitfall；
   - 未完成事项和下一步。
4. 若没有长期记忆变化，checkpoint 必须说明原因，不能制造空洞文档。
5. 运行 `close <WORK_ITEM_ID>`。只有 Harness 可把任务标记为完成。
6. 再次运行 `doctor`，保证状态、事件哈希链、架构和人类可读状态页一致。

## 必须人工批准的变更

- 架构边界、Target 或依赖边变化；
- 新增、删除或升级三方依赖；
- 数据库迁移或身份/阅读进度模型变化；
- 书源格式、规则语义、canonicalizer 或 Android baseline 变化；
- golden、snapshot 基准或测试阈值变化；
- JavaScript Bridge、网络、Cookie、文件、私网或 WebView 权限扩张；
- StoreSafe / FullCompat 能力或链接闭包变化；
- 接受一个有意的跨端不兼容行为。
- SourceLab schema、runner、coverage policy、reference 场景或场景 provenance 提升。
- Android baseline、Fact extractor/policy、accepted Requirement revision、Catalog 或需求 disposition。

AI 不得创建或伪造 approval 文件，也不得自行把 proposed ADR 改为 accepted。
