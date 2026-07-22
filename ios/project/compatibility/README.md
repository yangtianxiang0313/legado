# Compatibility Records

Android 与 iOS 的任何已观察行为差异都写为独立 `COMP-NNNN.json`，不要只留在测试日志。

最少字段：ID/revision、capability、fixture、Android observed、iOS observed/expected、classification（bug/intentional_difference/unsupported/unknown）、decision、profiles、severity、root cause、tests、status、introduced/resolved work item。

`intentional_difference` 必须引用 accepted ADR。关闭记录前，相应 preventive fixture 必须通过。
