# SourceLab：确定性书源环境模拟系统

## 1. 定位

SourceLab 是可演进的本地书站与故障模拟器，目标是让书源能力不依赖公网网站、DNS、证书、反爬策略或第三方数据。它同时提供两种执行方式：

1. T2/T3：同一份 route/response 由 `FixtureTransport` 直接消费，完全不创建 socket；
2. T4：映射为 `127.0.0.1:随机端口` 的真实 HTTP 网站，只用于 `NetworkFoundation`/URLSession 集成测试。

`ConformanceCLI` 继续只依赖 FixtureTransport，不能为了 SourceLab 链接真实网络实现。可信 CI 仍需使用 runner/firewall 禁止外网；loopback server 本身不能证明 Swift 子进程没有访问其他地址。

## 2. 四个平面

```text
Scenario contract
├── source.template.json       Android BookSource，只有 origin placeholder
├── input.json                 操作与刺激，不含业务期望
├── responses/*                精确响应原始字节
└── case.json                  route、故障、资源、来源、覆盖
          │
          ├── FixtureTransport ── Android pinned runner ── protected golden
          ├── FixtureTransport ── iOS SourceRuntime ───── execution envelope
          └── Loopback server  ── NetworkFoundation integration tests
```

- 环境平面：静态响应、有限枚举故障、固定 clock/locale/seed 和资源预算；
- 书源平面：从 `${SOURCE_LAB_ORIGIN}` 构建可导入 BookSource JSON；
- 执行平面：Android/iOS 使用相同刺激，产出各自 envelope；
- 判定平面：受保护 comparator 比较 Android golden，SourceLab 不生成答案。

## 3. 防假绿边界

- Scenario 禁止 `expected_result`、`expected_issue`、canonical envelope 和可执行脚本；
- 场景、Android golden、iOS 产品实现必须是不同工作项；
- golden 绑定 Android commit、scenario hash、runner hash 和 canonicalizer hash；
- 普通能力任务不能修改 golden、normalizer、coverage policy 或 runner；
- 产品源码不得出现 fixture ID、test-only 分支或把 SourceLab 结果硬编码为业务结果；
- CI 保留 AI 不可写的 reference/held-out 场景；candidate 经 provenance review 后才提升；
- 除差分外始终执行重复性、网络边界、资源上限、取消与 round-trip 性质测试。

`reference` 只表示环境输入已经审核并可稳定复现，不表示 Android/iOS 业务输出已经验证。业务状态由独立的 Oracle attestation、golden 和 Capability Evidence 表达。

## 4. 演进机制

`coverage-policy-v1.json` 是书源环境能力矩阵。每项 behavior 有 phase、状态及所需 case-role。状态从 `planned` 升为 `active` 时，Harness 只判定“环境可复现”：

1. 至少满足该 behavior 的 nominal/boundary/malformed/denied 角色下限；
2. scenario schema、response bytes 和 manifest 全部内容寻址；
3. 对应工作项声明复用或扩展哪些 behavior；
4. 每个 role 绑定 Android fact/branch reference，避免用手写标签冒充语义覆盖；
5. 新限制和场景踩坑写入 checkpoint/PIT。

产品 Requirement 达到 `implementation_ready` 还必须另外满足：Android runner 生成受保护 golden，iOS targeted conformance 与性质测试通过，并把差异写入 Capability/COMP。环境 active 与产品 verified 不能互相代替。

推荐拆分：contract/policy → simulator engine → scenario proposal → Android golden promotion → iOS implementation。任何一个工作项都不能同时拥有“题目、答案、实现”。

## 5. 能力路线

- Phase 1：GET/query、相对 URL、HTML/CSS、搜索→详情→目录→正文；
- Phase 1 扩展：POST form/JSON、header、redirect、Cookie、分页、charset、gzip；
- Phase 3：XPath、JSONPath、Regex、JS、动态 Web、取消、限流、错误注入；
- Phase 4：StoreSafe capability denial、恶意归档/超限响应、隐私与私网策略。

每种能力都要覆盖 nominal、boundary、malformed、denied 中适用的组合。角色按 behavior 独立判断：“搜索为空”是 search pipeline 的 boundary，但仍是 GET query transport 的 nominal；HTTP 404 不是相对 URL 解析的反例。

## 6. Loopback 安全与确定性

- 只允许一次性绑定 `127.0.0.1:0`，禁止固定端口、`localhost` 和 `0.0.0.0`；
- 服务端只接受实际 authority，拒绝 absolute-form URL、CONNECT 和未声明 route；
- 固定 Date/Server，响应带 Content-Length，不读取任意文件、不代理 URL、不执行脚本；
- 查询字段、请求体、响应、并发、请求次数和超时全部有上限；
- teardown 必须 shutdown、close、join，并确认端口关闭；
- canonicalizer 只把本次精确 authority 映射到 `http://sourcelab.test`，禁止全局删除端口；
- Cookie 不按端口隔离，每个 case 必须拥有独立 CookieVault/URLSession storage；
- 首版只支持 macOS CLI 与 iOS Simulator；真机不得通过放宽监听地址接入。
