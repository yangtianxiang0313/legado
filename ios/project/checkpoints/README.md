# Work Item Checkpoints

`verify` 成功后，AI 按 `ios/harness/schemas/checkpoint.schema.json` 写 `<WORK_ITEM_ID>.json`。Checkpoint 是无聊天上下文续作的最小交接，不是开发日志。

必须引用最新 Evidence、能力 revision 变化、架构影响、Requirement mode/ref/selection digest、SourceLab mode/behavior/scenario/selection digest、COMP/PIT 记录、剩余风险和下一步。没有兼容或 Pitfall 变化时填写具体 `none_reason`。
