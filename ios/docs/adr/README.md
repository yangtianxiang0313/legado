# Architecture Decision Records

ADR 只记录长期且难以局部撤销的设计决定。文件名为 `NNNN-short-title.md`，ID 为 `ADR-NNNN`。

状态：`proposed / accepted / rejected / superseded`。accepted ADR 的 Decision 不再编辑；
改变决定时新增 ADR，并互相填写 `supersedes / superseded_by`。ADR 是否 accepted 由当前
项目方向和对应 Task 的验证结果决定，不设置单独的文件审批 Gate。

必须包含：Context、Decision、Alternatives、Consequences、影响 Target/能力、数据与兼容影响、Validation、Rollback、人工审核项。

普通类名、局部算法、叶子 UI 和不改变契约的重构不写 ADR。
