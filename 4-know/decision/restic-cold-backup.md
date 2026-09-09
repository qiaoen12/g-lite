---
id: restic-cold-backup
type: decision
status: active
topic: [infra, backup]
scope:
  - infra.backup
  - meta.policy
primary_scope: infra.backup
confidence: low
created: 2026-08-31
review: 2027-02-28
---

# 冷备用 restic，两个不相关的异地目的地

> 事后补写于 2026-08-31。**`status: active` 但 `confidence: low`**，两个字段回答的是不同的事：
> 前者回答「现在算不算数」——policy 里两个目的地、保留期、口令双字段都是现行配置，这个决定一直在执行；
> 后者回答「对当初的理由有多大把握」，见「取证空缺」第 1 条：「为什么是 restic」在整个仓库里
> 找不到任何比较记录，它是从 v1 继承下来的。本文能立住的是围绕它的那一圈约束，不是工具选型本身。

## 背景与约束

需要一层能防误删、防硬件损坏、防账号风控的副本。

两个最容易被误当成副本的东西，都已经明确排除，理由都留了记录：

- **rsync 镜像不算副本。**它会传播删除——本地误删，下次同步远端也没了。只能防硬件损坏，
  防不了误操作。所以热镜像 `counts_as_backup_copy: false`，它的定位是给 VPS 上的 agent
  投喂上下文的只读副本。
- **git 远端不算副本。**它只覆盖已 commit 且已 push 的内容，未提交的改动和未跟踪的文件
  一概不管。实际 RPO = 现在时间 − 最后一次 push 的时间，而 `copy_count.thresholds`
  自己把这个时长容忍到 7 天——等于书面承诺 7 天 RPO。
  更早的版本正是以「git 远端即第二副本」为理由把 `1-code` 设成 `backup: not_required`，
  v2.1 把它改回 `required`，并顺手取消了「另有副本所以不用备份」这个中间状态——
  一个域此后要么值得备份，要么可再生。

职责因此划开：**git 管版本历史与协作，restic 管灾难恢复。不要让前者兼任后者。**

## 考虑过的选项

| 方案 | 优 | 劣 |
| --- | --- | --- |
| rsync 镜像 | 简单，可直接浏览 | 传播删除，防不了误操作；不计入副本数 |
| 只靠 git 远端 | 零额外成本 | 只覆盖已 push 的部分，RPO 等于距上次 push 的时长 |
| **restic 冷备**（选定） | 增量去重、自带加密、快照可枚举、路径集合可被审计反查 | 无记录说明为何选它而非同类工具，见取证空缺 |
| 备份加密卷本体（`.sparsebundle`） | 一个文件搞定 `5-record` | band 文件是加密的，内容一变整块变，restic 去重失效 |

## 决定

**冷备工具用 restic**（继承 v1，未在本仓库内比较）。围绕它的约束是本仓库内定的：

**两个目的地，必须不相关。**

| 目的地 | 频率 | 理由 |
| --- | --- | --- |
| `cold-gdrive`（rclone → Google Drive） | 每日 | 主目的地 |
| `cold-b2`（Backblaze B2，当前仍是占位符） | 每周 | 单一云账号是相关性风险。工作区内有多个账号注册自动化项目，此类活动与 Google 账号被风控正相关——两个风险不独立 |

**新建仓库，不复用 v1 的 `local-mac-project-cold`。**`backup_closure` 的判据是「最近一次快照的
路径集合」与应备份集合做差集，两代快照混在一个 repo 里会让这个差集恒不为空，除非每次查询都
记得加 tag 过滤——而「每次都记得」正是整套 policy 在消灭的东西。

**口令拆成两个字段，因为它承担两件约束相反的事。**

| 字段 | 回答 | 约束 |
| --- | --- | --- |
| `password_source` | 无人值守的机器怎么取 | 必须本机可取，否则 launchd 跑不起来 |
| `password_recovery` | 灾难时人怎么取 | 必须含至少一个本机之外的来源，否则 Mac 挂了就是死循环 |

本机 Keychain 只装这一个 restic 仓库口令，不装 Bitwarden 主密码——爆炸半径是这份冷备，
不是整个口令库。`pass://` 不算离机：密文和解密私钥都在同一台机器上。

**保留期** `keep_last: 14` / `keep_weekly: 8` / `keep_monthly: 12`，
`restic forget --group-by host,tags` 分组。

**验收是异机恢复演练，90 天一次。**`drill-local.sh` 用本地替身仓库跑完整管道，
证明的是「策略翻译成 restic 参数这一段是对的」，回答不了口令那一半——而口令恰恰是死循环
发生的地方。所以它的记录里必须写 `counts_as_quarterly_drill: false`，
否则它会顶掉真正的演练，制造「最近演练过」的安全感，那比没有演练更糟。

## 后果

- **主机名成了强依赖。**保留期按 `host,tags` 分组，主机名一变就凭空多出一个分组，
  旧分组不再有新快照进来，`keep-last` 被永久冻结，占着空间不再清理。本机三个主机名来源
  互不相同，所以 `2f71f1a` 把「取不到就兜底」改成了直接失败。
- **`5-record` 迁进加密卷之后，备份任务必须在挂载状态下跑**，否则备份的是一个空挂载点。
  好处是 `backup_closure` 会因此失败并起到提醒作用，但这是一条要人记住的运维约束。
- **`cold-b2` 至今是 `REPLACE-ME` 占位符**，所以「两个不相关目的地」这个决定目前只落实了一半，
  那个目的地当前零副本。
- **闭环校验只查到域一级。**`backup_closure` 比对的是域是否出现在快照里，
  域内单个文件被 exclude 误伤查不出来。
- **口令有三个存放点要各自维护**：Keychain（调度）、Bitwarden（人）、纸质（离机 attestation）。
  第 12 项审计只验证「机器取值当场有没有输出」和「人恢复声明里含不含离机来源」——
  它查的是声明，不验证 Bitwarden 里那条目真的存在。
- **口令库自己不能进这条链。**Bitwarden Lite 在 vps1，它的 `vault.db` 不走 Projects2 这条
  restic 口令，否则就成环了。这一层需要独立设计并独立维护。

## 什么情况下要重新考虑

- **异机演练做不下去。**演练要回答「完全没有本机的前提下能否拿到口令并还原一个文件」，
  如果这件事在实操中反复失败，问题不在演练流程，在工具或口令结构。
- **`cold-b2` 落地时发现 restic 对 B2 的支持成本超预期。**那是重新审视工具选型的自然时机，
  也是补上本文第一条空缺的最好机会。
- **备份体积或耗时增长到每日档跑不完。**去重效率是选 restic 的隐含前提，前提变了要重新算。
- **`5-record` 迁进加密卷之后**，如果「先挂载再备份」这条约束在实践中经常被忘记，
  说明该换成备份卷本体 + 换一个对大二进制块友好的工具，而不是继续靠人记得挂载。

## 取证空缺

1. **「为什么是 restic」没有任何记录。**它是 v1 就在用的（v1 有
   `projects-cold-restic-paths.txt` 和 `local-mac-project-cold` 仓库），本仓库从头到尾没有
   一处比较过 borg、kopia、duplicacy、Arq 或 Time Machine。选项表里 restic 那一行的「劣」
   写的就是这件事。**这是 `confidence: low` 的原因**，也是这四条 ADR 里唯一一条核心论证完全缺失的。
2. **「本机 Mac + FileVault」算作副本 ① 的依据。**`05-备份与恢复.md` 把它列为三份副本之一，
   但本机既是原件也是唯一的实时副本，把它计入副本数需要一个说明。
3. **纸质 attestation 还没填。**`381883d` 记着「纸质 attestation 未填」，
   `0-meta/audit/offline-copy.attestation` 至今未生成，所以三层口令实际只有两层。
4. **异机演练零次，而且超期检查本身还没实现。**`restore-drill/` 下只有
   `2026-08-27-local-pipeline.md`，它自己开头就写明不满足
   `must_be_on_different_machine`、不能用来重置 90 天计时。更要紧的是那份记录末尾承认
   「恢复演练超期检查本身还没实现（`retention` 项只查了 `_inbox`）」——
   也就是说 90 天这个计时器现在没有任何东西在看。
   按 `05-备份与恢复.md` 自己的话，未经演练的备份等价于没有备份。
5. **还有三条路径从未验证过**，同样出自那份演练记录的「还没验的」：
   真实目的地（rclone → Google Drive）的连通性与限速、口令从口令库取值这条路径、
   以及上面提到的域内单文件误伤。

## 依据出处

| 说法 | 出处 |
| --- | --- |
| rsync 传播删除、不计入副本 | `0-meta/docs/05-备份与恢复.md`；`0-meta/policy.yaml` `sync.counts_as_backup_copy` |
| git 远端不是备份、RPO 与 7 天承诺 | `0-meta/policy.yaml` `domains.1-code` 的 v2.1 修正注释 |
| 两个目的地与相关性风险 | `0-meta/policy.yaml` `backup.destinations[].rationale` |
| 不复用 v1 仓库的理由 | 同上，`cold-gdrive` 的 rationale |
| 口令两字段与爆炸半径 | `0-meta/policy.yaml` `backup.password_*`；提交 `381883d` |
| 主机名必须稳定 | 提交 `2f71f1a` |
| 本地演练不算季度演练 | `0-meta/docs/05-备份与恢复.md`「本地管道演练不算数」 |
| 演练已验项与未验项、超期检查未实现 | `0-meta/audit/restore-drill/2026-08-27-local-pipeline.md` |
| 加密卷本体会破坏去重 | `0-meta/docs/06-权限边界.md`「备份怎么办」 |
| 口令库自己不成环 | `0-meta/docs/05-备份与恢复.md`「口令库自己怎么备份」 |
| 第 12 项查声明不查事实 | 提交 `381883d` 末段自述 |
