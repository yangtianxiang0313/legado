# Minimal Loop v2

Loop v2 只保留一个当前任务、一个追加事件流和一个紧凑状态投影：

```text
已发布业务知识 / 源码锚定 Candidate Claim
→ next（纯派生）
→ task.json（唯一活动任务）
→ 默认 iOS Delivery；仅语义不明确时显式选择 Android characterization
→ verify（结构化验收）
→ complete（摘要、踩坑、当前状态、下一步）
→ 下一任务
```

权威文件：

- `ios/project/loop/task.json`：仅在任务进行中存在；
- `ios/project/loop/events.jsonl`：短事件和完成知识；
- `ios/project/loop/current.json`：可重建的当前投影。

AI 日常只需要反复调用一个幂等入口：

```bash
python3 -B ios/loop/loop.py advance
```

它会按当前状态自动执行一个安全转换：空闲时派生并启动下一任务；产品发生变化时
执行验收；相同失败工作区不会重复烧 attempt；验证通过后要求 AI 提交项目记忆。
验证指纹只覆盖产品、测试与 Harness 执行代码，不覆盖 `ios/docs`、`ios/project`
和 Markdown。验证后补充当前状态、架构变化或踩坑不会让已经通过的产品验证失效；
只有产品或测试代码继续变化时才重新验证。

## P0 关键路径调度

`ios/project/migration-priorities/active.json` 是当前迁移里程碑的可执行优先级，
不是展示路线图。Loop 会先把 planned Delivery 和待 Characterization 映射到
其中的 stage/selector，再按以下顺序选出唯一任务：

1. 更靠前的主链路阶段；
2. 同一 selector 下，已发布 Golden 的 Delivery 优先于新的 Characterization；
3. 最后才用任务 ID 做稳定排序。

`mode=critical_path_only` 时，未命中 selector 的候选只会被延后，不会丢失，也
不会在 P0 完成前抢占活动任务。`next` 与 `doctor` 的 `queue` 字段会同时报告
eligible 和 deferred 数量，防止“有大量候选却显示成迁移完成”的假性空队列。
没有活动里程碑时，历史扫描得到的 Characterization 候选也只作为库存报告，
不会被自动启动。AI 必须先从冻结 Android 源码确认下一条用户主链并声明一个
可交付里程碑；只有该里程碑显式选择了运行时语义不明确的 Claim，Loop 才运行
Characterization。这样“队列空”不会退化成批量生产 Golden。
当前 P0 目标是可阅读主链路：获得书籍、目录、正文、阅读器、进度恢复，并最终
以真实书源结构化验收和 iPhone Simulator 端到端 UI 验收收口。
验证通过时可在同一次调用中完成当前项并启动下一项：

```bash
python3 -B ios/loop/loop.py advance \
  --summary "完成内容" \
  --current-status "当前能力及未覆盖边界" \
  --architecture-change "none，或 ADR/依赖变化" \
  --pitfall "可复发问题与预防办法" \
  --next-step "下一步"
```

`doctor/next/start/verify/complete/supersede/reconcile` 保留为诊断原语。
当需求策略变化使当前任务失去价值时，`supersede` 记录原因和替代路径后直接
回到 idle；它不要求为旧任务伪造验证产物，也不会让该任务再次入队。`advance` 会先从
`events.jsonl` 重建并对齐 `current.json`，可以续接控制文件写入中断；它不会在
仓库内再次启动另一个 AI 进程，AI Executor 由当前 Codex 任务承担。

普通失败只追加 `verification_failed` 并增加 attempt，不创建 Recovery
任务。完整 stdout/stderr 和 verification report 位于 `.harness-runtime/loop`，
不进入 Git。旧 Harness 仅保留在 Git 历史；新的任务不得再生成 Recipe、
WorkItem、Checkpoint 或 Evidence 副本。

## 按风险验证

Loop 不再让每个小切片重复承担发布级验证：

- 普通业务 Delivery：1～3 个相关聚焦测试；
- 阶段里程碑：在聚焦测试之外只增加一次 App 构建；
- 真实 UI 结构或平台边界变化：才运行一台主 iPhone Simulator；
- Harness 自测、完整 Swift 测试、双设备矩阵与 Publisher 回归：仅在对应
  基础设施被修改或发布检查时运行，不阻塞日常迁移。

Android 真源 Golden 仍是迁移语义的权威。瘦身只移除重复验证，不把 iOS
测试结果反向当作 Android expected。

普通 Characterization 只允许一次真实 Android runner 生成 Golden，并直接校验
Golden 内的 fixture、Android commit 和 runner digest；fixture 与 Golden 不再要求
额外 manifest、registry、receipt 或 publisher 互相背书。普通业务
切片重复执行全局 Source Lab/Business Knowledge Doctor，也不要求
Oracle → Receipt → Publisher → Release 的多段发布往返。普通 Delivery 只跑
ConformanceCLI 跨端比较；模块测试与 Package 全局合同留到 checkpoint。
