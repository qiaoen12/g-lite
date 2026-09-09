---
id: policy-single-source
type: decision
status: active
topic: [meta, policy]
scope:
  - meta
  - infra.backup
  - data
primary_scope: meta
confidence: medium
created: 2026-08-31
review: 2027-02-28
---

# 备份与同步清单由 policy.yaml 推导，落成进 git 的 lock 文件

> 事后补写于 2026-08-31。这一条是四条基础决策里证据最硬的——v1 的四次翻车都留了实证，
> 散在提交正文、`05-备份与恢复.md` 和 `policy.yaml` 的 `catches` 字段里。

## 背景与约束

v1 的备份路径和同步 include 都是手写清单。四次翻车，每次的失效方式都不一样：

1. **restic 路径是手写的 23 行清单，三个目录零副本，而审计报告显示「漂移 0 项」。**
   原因是审计只检查配置文件的内容，不检查仓库里实际有什么。假绿比没有检查更糟。
2. **备份了 15 个空目录，漏掉 3 万个真实文件。**
3. **同步规则里手写了一行 `+ /…/credentials/***`，把整个机队的私钥推到了其中一台机器上。**
4. **手写的排除名单让监控在爆炸半径最大的地方失明。**v1 把 `credentials/` 与 `secrets/`
   加进排除名单，于是 `70-vps/credentials/ssh-keys/` 下 8 把无口令私钥、`vps-backup.env`、
   `40-asset/secrets/Chrome 密码.csv` 三处永远不会被报出。

四次的方向各不相同：漏收、错收、多推、不看。共同点只有一个——**清单是人写的。**

关键不是清单太长所以容易错。`derive-paths.sh` 落地后首次运行就反查出手写的
`sync.forbid_domains` 漏掉了一个 `sync: forbidden` 的域——那份清单**只有三个元素、
写下来不到一个月**。`0-meta/AGENTS.md` 的结论：手写清单会漂移，跟清单长短无关。

## 考虑过的选项

| 方案 | 优 | 劣 |
| --- | --- | --- |
| 手写清单 + 审计比对配置内容（v1 的形态） | 直观，改一行立即生效 | 四次实证全部翻车；审计查的是配置而不是事实，能给出「漂移 0 项」的假绿 |
| 事实源 + 每次现算，只打印不落盘 | 永远不会过期 | 终端输出看完就没，事后无法复核，进不了 review，也追不了责 |
| **事实源 + 推导 + 进 git 的 lock 文件**（选定） | 清单不可能与策略不一致；`git diff` lock 本身就是变更预览，永久可查 | 单一事实源同时是单一爆炸点；推导规则本身成为需要被理解的东西；lock 会过期 |

## 决定

`0-meta/policy.yaml` 是唯一机器可读策略事实源。备份清单、同步清单、可删除判定、审计口径
全部从它推导，`0-meta/audit/scripts/derive-paths.sh` 生成，结果落 `0-meta/derived.lock` 并进 git。

四条配套机制，缺一条这个决定就不成立：

| 机制 | 作用 |
| --- | --- |
| `new plan` 先打印 diff 再 `--apply` | 单一事实源必须「先看差异，再应用」 |
| 危险变更单独高亮且**拒绝直接写入** | 域退出备份、域进入同步、`hard_fail` 降级、`ai_access` deny 放宽、`git.mode` 变更等九类 |
| `plan_staleness` 进 commit 档硬失败 | 保证 policy 与 lock 永远在同一个 commit，不会出现「改了但没算」 |
| lock 只记规则集合，不记展开后的路径 | 规则集小而稳定，适合 diff；25 万条路径是运行产物，落 `_out/` |

同一个思想已经应用了三次：`backup.include`、`sync.include`、`3-data/INDEX.md`。
第三次是刻意的——手写清单会漂移这件事前两处已各证明一次，没有理由在第三个地方再证一遍。

## 后果

- **单一事实源同时是单一爆炸点。**一次错误的字段修改会同时改变备份范围、同步范围、
  删除判定和审计口径。`new plan` 的全部存在理由就是这个，不是为了好看。
- **推导保证一致，不保证正确。**这是最容易被这套机制的自信掩盖的一条。
  首次本地演练抓到：`backup.derive` 写的是 `all_paths − 各项排除`，而实现把它读成了
  「枚举 `backup.include` 的各个域」，于是 `.git` 和根层文件整批漏掉——83 个文件对 297 个。
  策略和清单当时完全一致，lock 也不过期，`new plan` 没有任何理由报警。
  救回来的是**演练**，不是推导。所以这条决策必须和「跑一次真实管道」配对，
  单独存在时它只是把手写清单的错误换了个位置。
- **推导规则本身要人读得懂。**「lock diff 就是变更预览」成立的前提是人能看懂那个 diff。
  规则一复杂，这个前提就悄悄失效。
- **哪些东西该进 lock 需要逐个判断。**提交语言的 scope 白名单刻意不进 lock：它来自目录树，
  写进去之后 `new code foo` 建个新项目就会让 lock 过期，而 `policy_sha256` 没变，
  `plan_staleness` 抓不到；顺带还得先跑一次 `new plan --apply` 才能提交那个新项目。
  每加一个派生项都要重做这个判断。
- **改 policy 是四件事一起做：**改 `policy.yaml` → 改对应 `docs/` → `new plan --apply`
  → 放进同一个 commit。落下任一件，事实源就分叉。
- **确定性依赖必须显式钉住。**`381883d` 曾记录 `derive-paths.sh` 没有固定排序 locale，
  `derived.lock` 会因运行环境不同出现大段非语义变更。本轮把 `LC_COLLATE=C` 固定在
  `derive-paths.sh`、`new` 与 scope 工具入口；不这样做，噪声会淹掉真变更，
  而 lock diff 的全部价值在于让人一眼看出改了什么。

## 什么情况下要重新考虑

- **lock diff 因为噪声不再可读。**这时要修的是确定性（钉 locale、稳定生成顺序），
  不是退回手写清单。四次翻车摆在那里。
- **推导规则复杂到需要一份单独文档才解释得清。**那说明策略模型自己该简化，
  而不是给它配一份说明书。
- **出现一类清单既推不出、也没法从目录树实时派生。**届时要重新回答「这份清单归谁维护」，
  而不是默认手写。

## 取证空缺

1. **`policy.yaml` 头部有两处过期声明**：「人类可读解释见同目录 DESIGN.md，迁移映射见
   MIGRATION.md」——两个文件在 `0-meta/` 下都不存在；「以审计 11 项全绿为验收」——
   现在是 14 项。这两行现在是错的，要么补文件要么改掉。
2. **v1 的手写清单原文没有留档。**`projects-cold-restic-paths.txt` 只在 `policy.yaml` 的
   注释里被提到「在此废弃」，文件本体不在本仓库。四次翻车目前只有转述，没有原始证据——
   第 4 次（排除名单）的证据相对最硬，`catches` 字段列出了具体路径和文件数。
3. **确定性缺口曾经存在，但缺少跨 locale 的自动回归测试。**
   现在三个生成/查询入口都固定了 `LC_COLLATE=C`；仍需用不同调用环境跑同一输入并逐字节比较，
   才能把这条从实现约定升级成持续验证。

## 依据出处

| 说法 | 出处 |
| --- | --- |
| 23 行手写清单 / 三个目录零副本 / 漂移 0 项 | 提交 `edf9dfb` 正文 |
| 备份 15 个空目录、漏掉 3 万个文件 | `0-meta/docs/05-备份与恢复.md` |
| 手写 `credentials/***` 推私钥 | `0-meta/docs/05-备份与恢复.md`「热镜像怎么定位」 |
| 排除名单让三处明文凭据永不报出 | `0-meta/policy.yaml` `audit.checks[plaintext_secrets].catches` |
| 推导实现读错 derive 规则，83 对 297 | `0-meta/audit/restore-drill/2026-08-27-local-pipeline.md` |
| 三元素清单一个月内就漂移 | `0-meta/AGENTS.md` 审计第 5 项说明 |
| 落 lock 而不是打印终端的取舍 | `0-meta/policy.yaml` `plan.contents` 上方注释 |
| 危险变更清单、workflow、staleness 判据 | `0-meta/policy.yaml` 第十一段 `plan` |
| scope 白名单刻意不进 lock | `0-meta/audit/scripts/derive-paths.sh`「提交语言」段注释 |
| locale 曾导致 lock 顺序变动；本轮固定 `LC_COLLATE=C` | 提交 `381883d` 正文末段；三个脚本入口 |
| lock diff 即 plan、永久可查可进 PR | `0-meta/docs/05-备份与恢复.md`「改策略之前先看差异」 |
