# Dependency proposals

AI 只能在这里提交 `DEP-NNNN.json` 提案，格式见 `dependency-proposal.schema.json`。提案必须绑定专用 ADR、精确版本/revision、产品与 Target 范围、传递依赖、许可证、Privacy Manifest、安全与包体审查、退出方案及按 adapter 类型选择的检查。

普通工作项不得修改 `Package.swift`、`Package.resolved` 或 `dependency-policy.json`。可信 Supervisor 在隔离环境中临时放行官方仓库域名，解析并扫描依赖，人工签名批准后才由受信发布器更新 policy、manifest、lock、SBOM 与 notices；随后在断网、禁止自动解析的环境中复验。
