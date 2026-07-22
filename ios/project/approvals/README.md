# Human Approvals

此目录只允许人或受保护 CI 写入。AI 不得创建、复制或修改 approval。

Approval 必须符合 `ios/harness/schemas/approval.schema.json`，并绑定 work-item hash、Evidence tree hash、gate、reviewer 和有效期。代码树变化后 approval 失效。
