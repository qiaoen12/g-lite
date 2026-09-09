---
id: framework-freeze
type: decision
status: active
topic: [g-lite, freeze, meta]
scope:
  - repo
  - meta
primary_scope: repo
confidence: high
created: 2026-09-09
review: 2027-03-09
---

# Project-qiaoen 停止作为 G-lite framework 上游

> 2026-09-09 人工治理决定（human governance override）：当前原型已足够稳定，不再增加新的 Pre-Freeze framework 功能，直接完成本仓最终收尾并 prototype Freeze。原设计中的两天 Soak 与 30-task 硬门槛见下文「原设计为什么那样写」；那些理由仍然解释当初的选择，但不再是本决策的执行前置。

## 背景与约束

Project-qiaoen 一直是 G-lite 的开发母体：Contract 进 main、claim/derive、zmerge、Portable Runtime、Git Guard、metrics、独立 Review、prompt diet，以及冻结前的 metrics / Review / finalize follow-up，都在这个仓库里完成。

继续在本仓当 canonical framework 上游有三个已经显性的代价：

1. **自举盲区。** #38/#40 证明过：用正在改的 runtime 给自己 claim/review/merge，会把控制面和 SUT 叠在一起。framework 任务必须走外部 `g-lite-harness`。
2. **身份混杂。** 本仓同时是个人工作区、framework 原型和未来的 personal 仓。不冻结、不抽出，下一阶段的 `qiaoen12/g-lite` 没有唯一 source baseline。
3. **永远差最后一轮优化。** Harness 不够通用、repo 名还没改、adapter 可以更薄、PowerShell / GitLab / merge queue 都还没有——这些都可以无限排进下一轮。它们不是当前 main 不能当迁移 source 的证据。

原 Issue #31 把执行条件写成：先做 3–5 个项目约两天 Pre-Freeze Soak，再以 30 个 business task 作为冻结期硬门槛。2026-09-09 的人工决定把该条件改成 GO：不再等待 Soak，30-task 改为使用量与证据强度指标。真正的长期稳定版本不在本仓发布。

本决策不执行：`g-lite-template → g-lite` rename、`Project-qiaoen → g-lite-personal` rename、正式 `v1.0.0` Release、Harness 泛化、新 framework 功能、consumer 升级机制。那些属于从本 Freeze SHA 提取到 `qiaoen12/g-lite` 之后的阶段。

## 原设计为什么那样写

两天 Soak 是为了避免把单次体验摩擦立刻写成 framework 变更，用真实使用窗口看保护边界是否失效。

30 个 distinct business Issue 是为了避免在没有足够真实使用量时凭印象解冻；同一 framework reason_code 必须命中至少 2 个不同 business Issue，或发生一次 P0，才形成下一轮候选。完成 30-task 也不是自动解冻，只触发一次人工评估。

这些理由仍然成立。被覆盖的是「必须先做完才能 Freeze / 必须凑满才能离开本仓」这一层门闩，不是「真实使用量和跨 Issue 重复故障才构成结构性证据」这一层判据。

## 考虑过的选项

| 方案 | 优 | 劣 |
| --- | --- | --- |
| 继续按原 #31：两天 Soak + 30-task 硬门槛后再冻结，本仓仍当 canonical 上游 | 使用证据更密，和最初设计一致 | 把已经稳定的原型继续留在个人仓里当上游；Soak 窗口本身又会诱发出新的非 P0 改动 |
| **现在 prototype Freeze，本仓停止当 framework 上游，下一阶段从 Freeze SHA 提取 `qiaoen12/g-lite` 并在那里发 v1.0.0**（选定） | 有唯一 source；个人仓与 framework 仓分离；非 P0 优化不再阻塞迁移 | 正式 v1.0.0 和使用期 15 天冻结要到下一阶段才发生；本仓 ADR 不能预先写入尚未产生的 merge SHA |
| 本仓直接打 v1.0.0 并继续当上游 | 少一次提取 | 身份仍混杂；rename 和 consumer 升级会在冻结面上施工 |
| 不写 ADR，只靠口头「先别改 framework」 | 零文档成本 | 下一轮 Agent 看不到边界；P0 与非 P0 无法对照 |

## 决定

### 1. 这是 prototype Freeze，不是 v1.0.0

#31 squash merge 之后，Project-qiaoen 作为 G-lite framework 开发母体的工作结束。本仓不再承担 G-lite framework 开发上游。

真正的长期稳定版本在下一阶段产生：

```text
qiaoen12/g-lite
v1.0.0
```

`g-lite v1.0.0` 发布后至少冻结 15 天；期间除 P0 外只记录真实使用问题，15 天后统一评估 v1.1。该冻结属于下一阶段，不在本仓实现。

### 2. Freeze SHA 的唯一定义

```text
988ba573c8bc8b841539223e547e82f70719f52c
    = #31 squash merge 之后
      Project-qiaoen origin/main 的最终 commit SHA

2026-09-09T10:55:57Z
    = 该最终 Freeze commit / merge 的真实 UTC 时间
```

它不是 candidate HEAD、PR head SHA、approve commit（`docs(meta): 批准任务契约 #31`）、merge 前的 main，也不是 Harness 仓的任何 commit。

下一阶段迁移必须：

```text
Project-qiaoen @ exact Freeze SHA
        ↓
allowlist 提取 framework
        ↓
qiaoen12/g-lite
        ↓
v1.0.0
```

**不要为了把 SHA 写进本 ADR 再追加一次本仓提交。** 追加提交会让「写进文件的 SHA」不再等于 origin/main 的最终 commit。SHA 在 merge 后从 `origin/main` 读取，记录在 Issue / 迁移任务里。

### 3. 三个仓库的角色

| 仓库 | Freeze 后的角色 |
| --- | --- |
| `qiaoen12/Project-qiaoen` | 停止作为 G-lite framework 开发上游；未来将成为 `qiaoen12/g-lite-personal`。本任务不改名。 |
| `qiaoen12/g-lite` | 下一 canonical framework repo。尚未在本任务创建。 |
| `qiaoen12/g-lite-harness` | 外部测试仓，继续承担 candidate 控制、fixture、E2E、Draft PR、review、STOP。本任务不泛化 Harness。 |

### 4. 冻结的是 canonical runtime，不是整棵 `.agents/`

Freeze 后，在 Project-qiaoen 内对下列对象只接受 P0：

- `0-meta/lib/`、`0-meta/bin/new`、`0-meta/schema/`、`0-meta/templates/` 中构成协议的部分；
- `0-meta/policy.yaml` / `0-meta/derived.lock` 的治理段（不含纯业务域新增）；
- `2-infra/git-guard/`；
- `.github/workflows/` 中与 main-guard / tripwire 相关的工作流；
- `.agents/skills/z-lib.sh`；
- `.agents/skills/*/scripts/**` 中被 canonical `new/z` source、exec 或直接依赖的 shell/Python executable；
- 其它虽然位于 `.agents/`，但实际承载 canonical protocol / gate / merge / review / sync 行为的 executable。

不整棵冻结：

- `.agents/skills/*/SKILL.md` 等纯 thin adapter / 调用卡；
- 与 canonical runtime 无关、只负责某个 IDE/Agent 入口描述的 adapter；
- `0-meta/docs/`、`4-know/` 说明文档（除本 ADR 自己的毕业修订）；
- `0-meta/tasks/**` 运行时契约文件。

不为了目录整洁搬迁现有 executable。冻结按「是否承载 canonical runtime 行为」判断，不按目录名机械判断。

### 5. P0 才允许再动本仓 runtime

P0 至少包括：

- runtime 无法正常工作 / main / canonical runtime 不可用；
- 数据丢失、错误 merge、错误 branch/ref delete；
- 合法 business task 被框架完全堵死；
- credential leak；
- 权限/保护边界失效（Contract / claim / review / merge / Git Guard 等核心链路明显错误）；
- 当前 main 无法作为可靠迁移 source。

不是 P0、Freeze 后只记录不修：

- Harness 不够通用；
- repo 名还没改；
- future multi-repo 支持还可以增强；
- 自动升级还没有；
- prompt 可以更短、CLI 可以少一步、输出格式不好看；
- adapter 可以更丰富；
- 未来 PowerShell、GitLab、merge queue、强 actor 身份认证。

即使是 P0，也不得让正在修改的 Project-qiaoen runtime 给自己 claim / review / merge。控制链只能是：

```text
stable main approve
        ↓
g-lite-harness
        ↓
vanilla candidate worktree
        ↓
修改
        ↓
fixture / E2E
        ↓
Draft PR
        ↓
independent review
        ↓
STOP
        ↓
human squash merge
```

独立 Review 指 reviewer 必须从 Contract、diff、validator 与实测证据形成独立结论，不等价于只把 `review_actor` 换成另一个字符串。actor 仍只是 provenance。稳定 main 主工作区的 `new task approve` 仍按 #25 允许。Harness 不是生产依赖，也不是运行时 SSOT。

### 6. metrics 与 30-task 口径

- `new metrics doctor`（或等价健康检查）未通过时，不得把 0 次事件当成「问题没发生」，也不得用于冻结 / 毕业 / 解冻判断。
- 后续使用量统计的 source 基线与 Freeze SHA / UTC 相同。Pre-Freeze Soak、Pilot-0、历史归档不计入。
- 只统计 `task_class=business` 任务产生的事件，以及这些事件里命中的 framework reason_code。经 Harness 的 framework 任务结构性为 0，不得写入任何毕业 / 解冻公式。
- `loaded_bytes` 只看 business claim 的 start card 口径。
- 30 个 distinct 已完成 business Issue 是真实使用量和证据强度指标，不是必须凑满才能解冻、也不是必须凑满才能提取到 `qiaoen12/g-lite` 的硬门槛。同一 Issue 内重复运行、重试、重复 emit 不增加任务数。

### 7. 解冻与下一轮候选

Project-qiaoen 在本次 Freeze 后不再作为 G-lite framework 开发上游。本仓内对 canonical runtime 的再次修改只接受 P0，且必须外部 Harness + human-merge。

形成下一轮 **g-lite** framework 候选（在 `qiaoen12/g-lite`，不是回到本仓继续当上游）需要：

1. 同一个 framework reason_code 在至少 2 个不同的 business Issue 上出现；或
2. 发生一次 P0。

同一 business Issue 内把同一个 reason_code 触发两次或十次，只算该任务内的重复故障。没有可靠 metrics 的问题只能由一次 P0 触发。framework 任务自己的 0 事件、adapter-only 改动，都不能触发 canonical runtime 解冻。30-task 完成只加强证据，不自动解冻。

### 8. 软件可替换

Git/GitHub durable facts + tracked `new/z` protocol 是长期核心。Orca、Cursor、Codex、Grok、Claude、Harness 都是可替换工具 / adapter，任何一个都不能成为运行时 SSOT 或唯一授权源。

thin adapter 必须保持可替换，因此不能把 `.agents/` 整树当成与 `0-meta/lib` 同级的冻结面；被 canonical CLI 实际 source/exec 的 executable 按 runtime 处理。

## 顾虑清单

Freeze 后这些项默认只记录、不实现，除非被判定为 P0。是否在 `qiaoen12/g-lite` 实施，由 v1.0.0 之后的评估决定。

| 事项 | 来源 | 毕业判据 | 最小实现 |
| --- | --- | --- | --- |
| Issue 正文篡改防御 | #27 / Contract 进 main | 门禁只信 origin/main 契约 blob；Issue 漂移只警告不放行 | 保持 `contract_stale` / Issue-diff warning；不把 Issue 当 SSOT |
| Status 探测窗口 | #20 / Project 视图 | 远端 Status 读失败 fail-closed；Status 不是授权源 | 不把 GitHub Project Status 当领取/合并条件 |
| 失败证据保全 | #38 finalize | 失败路径留下可复核的 reason_code 与世界状态，不回滚已发生的远端事实 | 维持「恢复=重跑」；不引入通用事务状态机 |
| 跨机器 merge queue | #25 后置 | 两台机器同时 merge 同一任务时有明确互斥 | 继续用现有 claim/merge lock；不在本仓做分布式队列 |
| 多条 Review / PR body 自动块 | #29 | 唯一 Review / 唯一 PR 标记可被 zmerge 读取 | 保持现有 marker；不合成第二套正文 |
| 第二系统用户 / 独立凭据代理 | 安全边界 | 生产凭据与 Agent 运行身份分离 | 不在本仓引入代理；P0 仍禁止凭据入仓 |
| GitLab / Codeberg 迁移 | 可移植 | 耐久事实不绑死 GitHub 专有字段 | 下一阶段评估；本仓不迁 |
| required checks | GitHub 保护 | server-side 拒绝未审查 / 未通过的 merge | 私有仓免费版能力不足时不假装已经等价 |
| 任意 Contract command | 早期契约草案 | A 项只能引用登记 validator，不携带 shell | 保持 registry；未知 validator 拒绝 |
| 子 shell reason-code 丢失 | metrics / z 路径 | fail 事件带稳定 reason_code | 已修调用点保持；剩余点只记录 |
| `ls-remote` 失败 vs 分支不存在 | #56 finalize | 三态：存在 / 确认不存在 / 读取失败；失败 fail-closed | 保持现有区分；不把网络失败当成不存在 |
| Harness 可移植 / 泛化 | #25 控制缺口 | 外部控制面可在其它机器复述 candidate 控制 | 本仓不改 Harness；缺口记在 Harness 仓 |
| PowerShell 原生 runtime | #25 后置 | 语言无关协议规格 + reason_code 注册表先存在 | 规格未写之前不实现第二语言 runtime |
| 更强 actor 身份认证 | #29 | actor 不再只是自报字符串 | 当前 `--actor` / `NEW_TASK_ACTOR` / `user.email` 仅为 provenance |
| 私有仓 tripwire ≠ 保护 | Git Guard | tripwire 只检测；真正 reject 必须是 server-side | 不把检测当保护；P0 仍禁止绕过 Guard |
| stale claim 恢复 | #20 | winner = host + 绝对路径 + branch；移动/改名锁死可人工解 | 人工处理 `refs/claims/<n>`；不自动抢锁 |
| 语言无关协议规格与 reason_code 注册表 | #25 后置 | contract/claim/review/PR 字段与 reason_code 有 tracked 规格 | 下一阶段；`new check` 字面量登记可作最小步 |
| Harness E2E 稳定入口 | #41 之后 | E2E 不 source 内部函数 | 改 Harness 测试入口，不改 SUT 迁就测试 |
| Review 独立性 | #29 / #54 | 结论来自 Contract + diff + validator + 实测，不只换 actor | 同 actor 默认拒绝；`Self-review=yes` 仍禁止自动 squash |
| 自动 Review 只陈述可证明事实 | #54 | 未知必须写成未验证，不得写成已审查 | validator 成功不覆盖 reviewer 的不通过 |

上表 20 行。未列入但不属于 P0 的增强，同样只记录。

## 后果

- 本仓 `origin/main` 在 #31 merge 之后成为可引用的 prototype baseline；提取时必须 pin 到 Freeze SHA，而不是跟 main 浮动。
- 非 P0 的 framework 想法改记到下一阶段，不再开 Project-qiaoen framework candidate。
- 个人业务任务仍可在本仓走 canonical runtime；那是使用，不是开发 framework。
- 正式 v1.0.0、rename、Harness 泛化都还没发生。任何人把本仓当前 main 称为 `g-lite v1.0.0` 都是错的。
- 本 ADR 合入后 `new adr --index` 会把本决策挂到 `repo` / `meta` 的受控块。不要手改 `0-meta/DECISIONS.md`。

## 什么情况下要重新考虑

- 发现当前 main **不能**作为可靠迁移 source（数据丢失、保护边界失效、核心链路明显错误）——这是 P0，走外部 Harness 修，而不是「解冻继续当上游」。
- `qiaoen12/g-lite` 已经从本 Freeze SHA 提取并发布 v1.0.0：本 ADR 对「下一上游」的陈述变成历史，本仓只还承担 personal 仓角色。
- 人工明确撤回「本仓停止当 framework 上游」这一条。没有这条撤回，不得因为 30-task 没凑满、Soak 没做、或「还想改一处 prompt」而把本仓重新打开为 framework 开发母体。
