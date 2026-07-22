# Evidence

`runs/<run-id>.json` 由 Harness 生成，绑定 work-item、代码树、diff、基准、工具链和每条验收命令。AI 不得手工编写 passing Evidence。

本地 Evidence 是开发证据；受保护 CI 必须在最终代码树重跑后才能作为合并/发布证据。敏感 Header、Cookie、token 和正文先按 redaction policy 清洗。
