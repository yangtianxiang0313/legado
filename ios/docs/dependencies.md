# 三方依赖与供应链治理

版本基线日期：2026-07-22。最终版本以 Swift 6.2 / Xcode 26 实测、精确锁定的 `Package.resolved` 为准。

## 首版白名单

| 能力 | 依赖 | 使用边界 |
|---|---|---|
| SQLite | GRDB.swift 7.11.1 | 只允许 `DatabaseGRDB` import；Record/SQL 不得泄漏。 |
| HTML/CSS | SwiftSoup 2.13.6 | 只允许 `HTMLSwiftSoup` import；作为 jsoup 兼容后端。 |
| XML/XPath | Kanna 6.1.0 | 只允许 `XPathKanna` import；不用它执行默认 CSS。 |
| ZIP | ZIPFoundation 0.9.20 | 只提供容器能力；Zip Slip、尺寸和压缩比策略由项目负责。 |
| 图片 | Nuke 13.0.6 | 经 `ImageLoading` adapter 使用；Header/Cookie/cache key 归项目。 |
| Snapshot | SnapshotTesting 1.19.3 | 仅 test target；更新 reference 必须人工门禁。 |

条件依赖：需要完整 EPUB2/3、fixed layout、CFI 或无障碍时评估 Readium Swift Toolkit；系统 Keychain 能力不足时再评估 Valet；CryptoKit 缺少确切旧算法时才评估 CryptoSwift；7z/RAR 成为明确需求后再封装 libarchive XCFramework。

不进入首版：TCA、Swinject/Factory/Resolver、Alamofire/Moya、RxSwift、Quick/Nimble、Kingfisher、Fuzi、FolioReaderKit、SwiftyJSON、KeychainAccess、QuickJS。JSONPath 不直接依赖 SwiftPath；项目必须掌握 Jayway 兼容 parser/AST/evaluator。

## 系统框架优先

- URLSession、URLProtocol、Network；
- Swift Concurrency、AsyncStream；
- JavaScriptCore、WebKit；
- AVFoundation、AVSpeechSynthesizer；
- Codable、JSONSerialization、CoreFoundation 字符编码；
- Security.framework Keychain；
- VisionKit、CoreImage；
- OSLog；
- 工具链内置 `swift format`。

## 引入规则

1. 只使用 SwiftPM，精确 tag，提交 `Package.resolved`。
2. 禁止 branch、浮动版本、未经审查的 binary target、build plugin 和 macro。
3. 一个 PR 最多变更一个核心依赖。
4. 新依赖/升级必须有 ADR 和人工批准，记录用途、替代方案、传递依赖、许可证、Privacy Manifest、维护状态、包体增量、退出方案和责任人。
5. parser、数据库、归档、Readium 变更必须运行完整 conformance、迁移/恶意 fixture 与性能基线。
6. 生成 SBOM 和第三方声明；MIT/BSD/Apache 可进入普通审核，GPL/LGPL/MPL/AGPL 单独法律审核。
7. 当前仓库为 GPLv3，iOS 派生实现和 App Store 分发义务需要发布前独立法律评估。

机器权威为 `ios/harness/dependency-policy.json`，模块名白名单只负责快速 import 检查。Policy 额外冻结 canonical package identity、官方 HTTPS URL、exact version、resolved revision、允许 product/adapter/profile，以及 binary target、plugin、macro 和 traits 禁令。

普通 AI 工作项只能在 `ios/project/dependency-proposals/` 提交 `DEP-NNNN.json`，不能修改 Package manifest、lock 或 policy。可信 Supervisor 临时只放行对应官方仓库，完成解析、传递依赖/许可证/Privacy Manifest/安全/包体审查并获得 `dependency-review` 签名后，受信发布器才更新 policy、`Package.swift`、`Package.resolved`、SBOM 和 notices。随后所有普通检查恢复断网和禁止自动解析。

CI 必须使用锁文件，禁止静默更新：

```bash
xcodebuild \
  -onlyUsePackageVersionsFromResolvedFile \
  -skipPackageUpdates \
  -packageFingerprintPolicy strict \
  -packageSigningEntityPolicy strict
```

不得使用跳过 package signature、plugin 或 macro validation 的参数。

SourceLab server、场景校验和书源构建器只使用 Python 3.9 标准库，不为测试控制面新增网络服务器、模板或 DSL 三方依赖。
