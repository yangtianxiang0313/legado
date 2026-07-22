# 可信 Supervisor 与无人值守边界

## 1. 威胁模型

仓内 `harness.py` 与 AI 共享文件权限，所以它能可靠防止正常 Agent 的范围漂移、弱验收和误更新参考答案，但不能证明一个恶意 Agent 没有重写 state、event、Evidence 或 reviewer 字符串。无密钥哈希链是篡改检测，不是外部信任锚。

因此分两层：

| 层 | 作用 | 信任 |
|---|---|---|
| Local Harness | doctor、queue、scope、架构、checks、Evidence、memory transaction | 协作式防误操作 |
| Trusted Supervisor/CI | 隔离、lease、Agent 调用、外部状态、签名审批、最终复验与 patch promotion | 无人值守安全边界 |

## 2. 每个工作项的隔离执行

Supervisor 必须：

1. 从受保护 base commit 创建一次性 git worktree/overlay；
2. 将 work-item、config、schema、架构、golden、Android Fact Inventory、accepted Requirement Catalog 和 accepted ADR 以只读方式挂载；
3. 只把 `scope.allow_write` 暴露为可写 overlay，拒绝 symlink、绝对路径和仓外写入；
4. 给进程最小、无 secret 环境，不挂载开发者 SSH、云凭据、Keychain 或浏览器会话；
5. T0～T5 默认断网，只允许显式 `live-probe` runner 的域名白名单；
6. 为进程组设置 CPU、内存、文件大小、进程数与 wall-clock 上限；
7. lease/heartbeat、状态 journal、Evidence head 与 approval 存在 AI 不可写服务或专用分支；
8. 默认禁止 egress；只有 T4 SourceLab 检查临时允许当前 run 的精确 IPv4 loopback authority，不能把 `localhost` 或任意私网加入通配白名单；
8. Agent 结束后冻结 Git tree，丢弃运行期间生成的后台进程与临时 HOME；
9. 在冻结 tree 上由可信 runner 重跑 required checks；
10. 只有受信 patch publisher 才把候选应用到集成分支。

Supervisor 负责发布 `AndroidSnapshotPublished / RequirementCatalogPublished / WorkItemMaterialized / RequirementDriftDetected` 等受信事件。普通 Agent 只能生成 proposal，不能调用 accept/publish 命令。

路径检查永远保留为第二道门，但不能代替 OS/container/VM 隔离。

## 3. 状态与恢复

Supervisor journal 是生产权威源，事件带单调 sequence、previous hash、work-item/spec/candidate digest 和受信签名；仓内 `state.json/status.md` 是投影。投影写入中断时，从 journal 重建，不允许 AI 自行“修复”事件历史。

lease 到期后 Supervisor 终止进程组，状态进入 `blocked: lease_expired`，保留候选 artifact，不直接复用旧 worktree。人工或策略创建新 attempt 后才能继续。

## 4. Approval

审批主题为：

```text
sha256(
  work-item spec
  + frozen product tree
  + capability/checkpoint/COMP/PIT/ADR
  + passing Evidence manifest
)
```

不包含 approval 自身和可变 dashboard/state。审批来自企业身份或代码托管平台的受保护 review，含 reviewer identity、时间、过期时间和签名；候选任一字节变化即失效。

## 5. Driver 状态循环

```text
doctor trusted inputs
→ select next ready item
→ create isolated attempt + lease
→ run baseline on clean base
→ invoke exactly one writer Agent
→ freeze candidate
→ trusted verify
→ validate memory transaction
→ await signed gate or promote patch
→ commit code + tests + memory atomically
→ continue
```

任何 baseline red、network escape、scope violation、protected input mutation、same failure twice、non-determinism、budget exhaustion 或 gate 都停止当前 attempt。Supervisor 不自动降低阈值，也不自动更新 golden。
