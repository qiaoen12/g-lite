# Git 工作流

> 一句话：**整个工作区是一个私有仓库，一条主线，任务开短分支，AI 各占一个只看得见自己那块的 worktree。**

## 一、三个机制，职责不能混

这是理解整套流程的前提。它们经常被当成一回事，但解决的是三个不同问题。

| 机制 | 回答什么问题 | 产物 |
| --- | --- | --- |
| **branch** | 这些改动属于哪个版本 / 哪个任务 | 一条提交线 |
| **worktree** | 多个分支能不能同时摊在磁盘上 | 多个物理目录 |
| **sparse-checkout** | 这个目录里实际出现哪些文件 | 一个最小视图 |

只用 branch，多个 AI 就得在同一个目录里抢着 `git switch`。加上 worktree，各干各的。再加 sparse-checkout，每个 AI 只看得见跟自己有关的那 20 个文件，而不是 25 万个。

```
完整事实源            任务视图
workspace      ──┬──  reddit worktree    0-meta + .agents + 1-code/reddit
（main）          ├──  discord worktree   0-meta + .agents + 1-code/discord
                 └──  vps3 worktree      0-meta + .agents + 2-infra/vps3
```

每个 worktree 都只是同一个 monorepo 的一个切面，不是副本。git 的对象库是共用的。

## 二、仓库长什么样

```
GitHub        <origin>（由 git remote 推导）
                └── main

本机          <workspace-root>/            ← 主工作区，完整
              ../worktrees/  ← 任务视图，短期
```

worktree 根是仓库根的**兄弟目录**，不是子目录。放子目录里会被 `topology` 审计判成「顶层多出一个未声明的域」，还会被同步和备份重复收录。

## 三、什么进 git，什么不进

「工作区是一个 git repo」不等于「工作区所有文件都进 git」。

| 域 | 跟踪 |
| --- | --- |
| `0-meta/` `1-code/` `2-infra/` `4-know/` | 整域 |
| `3-data/` | 只有 `DATASET.md` `RETENTION.md` `README.md` `pipeline/` `schema/` |
| `5-record/` | 只有 `AGENTS.md` `RETENTION.md` |
| `_inbox/` `_vendor/` | 只有治理文档 |
| `_raw` `_out` `_cache` `_archive` `_files` `_vendor` | 任意深度，全部不进 |

`3-data` 从「整域不进 git」改成了细粒度。原来的理由是「pipeline 脚本可以放 1-code」，但那样 pipeline 和它处理的数据分居两域，改一个必须记得改另一个，而没有任何机制在检查。数据集里真正不能进 git 的只有数据本体。

### 为什么审计要查 `git ls-files` 而不是 `.gitignore`

`.gitignore` 只能阻止**未来**的 `add`。一个文件一旦进过索引，后来补的忽略规则对它完全无效。所以 `new check` 的判据是索引里实际有什么，不是规则文件里写了什么。

这跟 `sync_safety` 是同一个思路：检查「实际发生了什么」，不是检查「我们打算怎样」。

## 四、分支

**只有一条长期分支：`main`。**

曾经考虑过按目录切长期分支：

```
main
├── 1-code branch
└── 2-infra branch
```

这是个概念错误。`1-code` 分支并不只包含 `1-code`——它仍然代表**整个工作区**在某个时间点的完整快照。长期并存三条，就是三条完整时间线：main 的 policy 已经改了，`1-code` 分支还停在旧 policy，`2-infra` 又是第三个状态。冲突会持续累积，而规则版本漂移正是这套体系要消灭的东西。

**分支跟工作单元走，不跟目录身份走。**

```
code/reddit-incremental      code/reddit-parser
infra/vps3-backup            meta/policy-v2.4
data/reddit-schema-v3        research/xr-market-2026
```

前缀就是 scope domain：`code` `infra` `data` `know` `research` `meta` `vendor` `record` `inbox` `repo`。这份清单不手写，由 `policy.yaml` 的 `git.commit.scope_src` 派生，落在 `derived.lock` 的 `git.branch.prefixes`。

### 按主题线切，是同一个错误换了个名字

比按目录更有诱惑力的一个变体，是按**长期工作主题**切：

```
meta/rules           总目录的规则和规范都在这里改
infra/backup         备份规则和执行都在这里做
infra/vps            几台服务器的连接、调试都在这里
```

理由通常是「这样这条线的工作能溯源，而不是散落在各处」。这个需求是真的，但分支解不了它。

先看它为什么会爆。这三条分支各自带着一份完整的 `0-meta/`。`derived.lock` 是 `policy.yaml` 的哈希指纹，而 plan 陈旧检查是 **commit 档硬失败**：`infra/backup` 上改了 `backup` 段、跑了 `new plan --apply`；`meta/rules` 上改了 `git.commit` 段、也跑了 `new plan --apply`。两份 lock 各自自洽，合并时必冲突，而冲突对象是一个**生成物**——手工解出来的 lock 跟任何一份 policy 都对不上，检查直接红。`AGENTS.md` 的受控块同理，而且它的 scope 表是从目录树实时派生的，两条分支上各自新建的目录会派生出两张不同的表。

再看它连溯源都换不来。**squash merge 之后分支被删，碎历史就没了**，main 上留下的还是那一条 squash 提交；不删的话，那条线的提交永远不在 main 上，溯源反而更差。长期分支唯一确定带来的东西是合并成本。

还有一个更隐蔽的错位。想「回到那条分支继续」的时候，真正想接上的是**对话上下文**，而分支里没有对话，只有文件。分支活着不代表上下文活着。要延续上下文靠 `4-know` 的文档和 ADR，不靠分支。

行业结论也是这个。保留多条长期分支的模型是 git-flow，作者 2020 年自己在原文顶部加了一段反思：做持续交付就不要用它。它至今仍然成立的场景只有一个——**同时维护多个已发布版本**，比如一个库要同时给 v1.x 和 v2.x 打安全补丁。注意那里的长期分支对应的是长期存在的**产物版本**，不是长期存在的**工作主题**。本工作区没有多版本要维护。

唯一正当的「按主题长期分支」是 vendor branch，用来跟踪外部上游代码。这个需求本工作区确实有，但它由 `new vendor <git-url>` 加 `VENDOR.md` 承担，不用分支。

### 为什么前缀不再是 `feat` / `fix`

v2.3 的八个前缀是 `feat fix infra data know meta research chore`，其中 `1-code` 映射到 `feat`。这是个和旧 `commit_convention` 一模一样的错误——**拿一个动作词去回答一个位置问题**。

后果是 `feat` `fix` `chore` 三个词同时出现在两套词表里，含义不同：

```
feat/reddit-v3        「这是 1-code 的任务」    位置
feat(code.reddit)     「这次是新增能力」        动作
```

现在两个问题各归各的：**分支回答「属于哪块」，提交 type 回答「什么性质」。**「哪块」的词表只该有一份，所以分支前缀和 scope domain 是同一份。

### 一个任务可以跨域

改造 Reddit collector 通常同时动代码、部署、数据契约和决策记录：

```bash
new worktree reddit-v3 \
  --path 1-code/reddit \
  --path 2-infra/reddit \
  --path 3-data/reddit \
  --path 4-know/decision
```

这本来就是一个逻辑变更，不要因为它们在不同顶层目录就拆成三个分支。**这是 monorepo 最主要的收益**，per-repo 模式下这个变更必须拆成三个 PR，还没法原子回滚。

### 分支能活多久

不设统一时限。**上限由它有没有碰共享单点决定。**

| 分支碰了什么 | 寿命上限 |
| --- | --- |
| 只在 `1-code` / `3-data` / `4-know` 里改 | 一两周没问题 |
| 碰 `0-meta/`（`policy.yaml` `derived.lock` `AGENTS.md` `bin/new`） | 当天合回 `main` |

理由不是纪律，是 `derived.lock` 的性质：它是全域共享的**生成物**，两条分支各自 `--apply` 过之后冲突不可手工解。同理，**同一时刻碰 `0-meta/` 的分支只能有一条。**

这条上限是 policy 的结构推出来的，不是额外加的规矩。`0-meta` 之外的域没有这个单点，所以那里的分支可以慢慢做。

### 想溯源，不要用分支

「这条线的工作能不能溯源」是真需求，但它有三层现成答案，都不需要建任何长期分支。

**路径查询**，完整、连续、永不漂移：

```bash
git log -- 2-infra/backup
git log --oneline -- 0-meta/policy.yaml
git log --oneline -- 3-data/reddit 4-know/decision   # 跨域一起看
```

**scope 就是索引。**提交语言的 scope 是机器验证过的——scope-path 一致性检查保证它不是猜的，所以按 scope 抓一条线比按分支名可靠：

```bash
git log --oneline --grep 'infra.backup'
```

**ADR 记「为什么」。**前两层给的是「改过什么」，而一条线上最值钱的是「为什么这么改」：冷备口令为什么从 1Password 换到自托管 Vaultwarden、源路径为什么改成备份根。这些提交描述装不下，分支更存不了，`new adr <slug>` 正好。**觉得缺溯源的时候，缺的通常是这一层，不是分支。**

反查也用同一套 scope 词表，不用另学：ADR 的 `scope` 字段与提交 scope 共用词表，所以「`infra.backup` 这条线有哪些决策」在 [`0-meta/DECISIONS.md`](../DECISIONS.md) 的反查表里是一行，在 `2-infra/backup/README.md` 的受控块里也是一行。生成方式见 [`03-知识库.md`](03-知识库.md)。

## 五、提交语言

```
<type>(<scope>): <描述>
```

三部分含义固定，**type 和 scope 必须正交**：

```
type         这次做了什么性质的动作
scope        实际改的是哪一块
description  具体做了什么
```

`infra` / `data` / `know` / `research` / `meta` 描述的是「改哪里」，所以它们是 scope 的 domain，**不是 type**。

完整的 domain 表、type 矩阵和词义在根 [`AGENTS.md`](../../AGENTS.md) 的受控块里（由 `new plan --apply` 从 `policy.yaml` 生成，两处不重复维护）。这一节只讲那张表回答不了的部分。

### scope 必填，且是实时派生的

形状 `<domain>[.<unit>[.<member>]]`。unit 不是白名单，是每次提交现场从目录树扫出来的——`new code foo` 建完项目，`code.foo` 立刻可用，不需要改任何配置。

派生时跳过保留名，否则 `1-code/example-app/_out` 会派生出 `code.example-app._out` 这种既不该提交也没有意义的 scope。第三段 `member` 只在 `1-code` 的分组项目里派生，且只下一层——普通目录递归会让 scope 数量随深度爆炸，多出来的全是噪声。

`record` `inbox` `repo` 不派生 unit。`repo` 的语义是「不属于任何域」，不是「仓库根目录下的文件」——`.claude/settings.json` 带斜杠但仍然是仓库级配置。

### 选 type 看实际被修改的对象

不看主题词。这是最容易错的一处：

| 你在改 | 写 | 不要写 |
| --- | --- | --- |
| 翻译程序的代码 | `feat(code.my-livetranslate)` | `translate(code.my-livetranslate)` |
| 数据集里的日语评论 | `translate(data.reddit)` | `clean(data.reddit)` |
| 代码的组织结构 | `refactor(code.reddit)` | `clean(code.reddit)` |
| 数据里的重复记录 | `clean(data.reddit)` | `refactor(data.reddit)` |

`refactor` 只作用于代码，`clean` 只作用于数据；`translate` 只在真的翻译数据内容时用。能用领域专属 type 就不要用 `chore`——`chore` 是最低优先级兜底，不是「不知道怎么分类」的默认答案。

### scope 与改动路径必须对得上

commit-msg 跑的时候索引已经就绪，所以「先看实际改了什么」这句话的**前半截是机器验证的**：每个声明的 scope，至少要有一个暂存文件落在它对应的目录下。写 `fix(infra.backup)` 但一个文件都没动 `2-infra/backup/`，直接拒。

**这条是单向的，而且刻意不做反向。**它只问「声明的 scope 有没有对应改动」，不问「所有改动是否都被 scope 覆盖」。反向检查会逼着「顺手改了根 `.gitignore`」的提交挂上 `repo`，那就把「默认单 scope」自己推翻了。

所以它的边界是明确的：**能抓「scope 是猜的」，抓不到「夹带了无关文件」。**后者由下一节的粒度原则和你自己负责。type 那半截机器验证不了——它分不清 `feat` 和 `fix`。

`--amend` 且没有新增改动时暂存区是空的，这时跳过这条检查，否则改一句错别字都会被判成 scope 无证据。

### 多 scope 是例外，不是常态

支持 `fix(infra.backup,code.my-livetranslate): 统一超时配置读取逻辑`，但**默认单 scope**。只有当一个不可分割的意图确实同时作用于多个 scope、而且它们共用同一个 type 时才用。

「branch 可以跨域」不等于「squash 之后必须是一条多 scope 提交」。跨域分支该拆几条，仍然按「是否是独立意图」判断，拆法见下一节。

### 什么程度才值得一条提交

不按行数、不按文件数。只有一条判据：

> **一个 commit = 一个可以独立理解、验证、回滚的单一意图。**

四个要求：有清晰目标、能单独解释、能验证、能独立回滚，且不夹带无关修改。

多个文件共同完成一个目标，是一条。同一个文件里装着两个互不相关的意图，要拆成两条。

### main 与工作分支不是一个标准

这一点是机器判定的，钩子会读当前分支名：

| 位置 | 判定 |
| --- | --- |
| `main` | 完整校验，且整条描述等于空泛词会被拒 |
| 短分支（前缀合法） | 放行 `wip:`，其余仍查格式与 type × scope |
| 分支名不合规 | 按 `main` 的严格度校验，并提示分支名不对 |

空泛词的判据是**整条描述相等**，不是子串匹配。`revise(research.xr): 更新 Quest 用户画像结论` 合法，`chore(repo): 更新` 不合法。

子串封禁看起来更严，实际是有害的：`policy.yaml` 的命名段记着 v1 的教训——全局命名规则让「报销/差旅/2025-02-北京」永久违规，5 项违规挂了 60 天、修复 0 项。**覆盖面过大的规则会失去可信度，然后被整条绕过。**

### 既往不咎

`policy.yaml` 的 `git.commit.enforce_after` 是一个提交哈希，左开：那条提交本身不查，它之后产生的第一条起必须合规。

它现在划在初始提交上，也就是**豁免区间是空的**。新规范之前那批 `meta(docs)`、`infra(backup)`、`fix(backup)` 当时还没推到远端，已经按提交语言重写掉了。初始提交自己留在区间外，因为它已经在远端，改它要 force push。

划线这个机制仍然保留：一个天天误报的检查等于没有检查，理由和 `worktree-clean` 的合入判定一样。

**重写主线历史时，这个值要在同一个 commit 里跟着挪。**它指向的对象一旦不存在，回扫不会报错，而是打印一句「找不到，跳过」然后返回 0——整项检查静默消失，比一开始就没有这项检查更糟。

### 门禁在哪一层

两种钩子类型，查两件不同的事：

| 钩子 | 查什么 |
| --- | --- |
| `pre-commit` | 提交的**内容**：密钥、路径、git 卫生、plan 是否陈旧 |
| `commit-msg` | 提交的**名字**：格式、type、scope、type × domain、scope-path 一致性、main 的空泛描述 |

必须分成两个，因为 `pre-commit` 跑的时候提交信息还不存在。`.pre-commit-config.yaml` 的 `default_install_hook_types` 两种都要声明——只写 `pre-commit`（默认值）的话，commit-msg 那层会「配置写了但从未生效」，这正是 v2.3 之前的状态：`policy.yaml` 里躺着一条 `commit_convention` 正则，没有任何东西在执行它。

`new setup` 装完会逐个确认钩子文件真的落地，而不是只看 `pre-commit install` 的退出码——它对「配置里没声明的钩子类型」同样返回 0。

`git commit --no-verify` 能绕过全部。本地补不了，所以 `new check` 的 daily 档由 `commit_convention` 回扫 `enforce_after` 之后的主线提交，事后发现。回扫和钩子是**同一个脚本、同一套例外判断**（自动生成的 merge / revert / fixup 消息）——两边各写一份的话判断迟早分叉，表现就是审计天天报一件钩子已经决定放行的事，而那是门禁被整项关掉的标准前奏。

## 六、完整流程

Orca 已经建好的任务工作树，不要再跑 `new worktree`。在那棵树里：

```bash
new task            # 只预检；不领取、不改 GitHub、不启动 Agent
new task approve <n>
                    # 人在主工作区、main 上把 Issue 正文写成 origin/main
                    # 上的契约文件。Backlog → Ready；在途任务只换契约、不动 Status
new task claim [--actor <id>]
                    # claim remote 上原子创建 refs/claims/<n> 后才算领取；
                    # 再写 Status / Checkpoint，不启动 Agent。下一步：new z dev
new task grok       # 同一 claim 核心，成功后当前终端启动 grok 并自动执行 /zdev
new task codex      # 同一 claim 核心，成功后启动 codex 并自动 $zdev
new z dev|fix|sync|review|pr|merge
                    # canonical z；Skill 只是 adapter
new task review     # In progress：push → 创建或复用 base=main 的非 Draft PR
                    # → Checkpoint → In progress → In review
                    # In review：仅当存在唯一属于当前任务的未关闭 PR 时，
                    # 更新原 PR 并保持 In review；否则硬停止，不新建 PR
                    # PR 标题必须通过现有 commit-msg 校验；有通过 Review 时用
                    # Squash-Title，否则不得直接使用不合规 Issue 标题
                    # 不合并 PR、不关闭 Issue、不向 main push、不改 Done
```

开工之后的开发、审查与合并入口是 canonical `new z dev|fix|sync|review|pr|merge`。`.agents/skills/` 里的 `zdev` `zfix` `zreview` `zsync` `zmerge` `zpr` 只做 thin adapter（Codex `$zdev`，Grok `/zdev`，均关闭隐式调用）。`new task grok` / `new task codex` 在领取成功后自动执行 `zdev`；`new z dev` / `zdev` 先输出开工摘要再开发，人也可再次显式选择。默认链路：`zdev` → `zreview` → 通过则 `zmerge`（推导 In progress 或 In review 时都调 `new task review`：前者创建或复用 PR，后者只更新唯一已有 PR，并以 Squash-Title squash merge）。required checks 读取失败必须停止，不得当成「没有 checks」。有 `human-merge` 标签时 `zreview` 不进入 `zmerge`，由人明确选 `zpr` 送 PR。`zmerge` 在同一 git common dir 上互斥，持锁后复读再 merge；已 MERGED 的匹配 PR 或「确认无 PR 且 HEAD 已在 origin/main」只 finalize，不二次 merge。PR 列表读取失败必须停止，不得当成无 PR 去 finalize。finalize 删远端任务分支（删除前证明 tip 已是 `origin/main` 的祖先，并用 `--force-with-lease`；lease stale 不得改成无 lease 重试），并在条件满足时把本地主工作区 `ff-only` 到 origin/main，否则只报告「本地 main 未同步」。merge 后收尾失败输出「远端已合并;finalize 未完成:<步骤>」。`refs/claims/<n>` 与任务同寿，finalize 不删除；它是任务身份和 `derive_task_state` 的耐久锚点。协议见 [`templates/z-workflow.md`](../templates/z-workflow.md)。Task Contract（approve 进 main、blob SHA、五处门禁只读 origin/main）见 [`08-task-contract.md`](08-task-contract.md)。

通用领取不启动 Agent。`new task grok` / `new task codex` 才启动已登记产品；其它名字直接拒绝。预检失败、推导状态不能领取、claim push 被拒，都不会启动 Agent。领取以 `claim` remote 上创建 `refs/claims/<n>` 为准：空树 orphan commit 记录 `host` / `worktree` / `branch`（winner 身份）和 `at`（诊断），再 `git push --porcelain --force-with-lease=refs/claims/<n>: claim <lock>:refs/claims/<n>`。porcelain `*` 才是本次 winner，`=` / `!` 都是「已被领取」。`claim` 等于 origin 的 fetch URL，不受 origin push URL 影响；缺失或指错时预检自动修正。其后普通任务分支 push 走 origin 的 push URL。被拒则不写 Status、不写 Checkpoint。

成功后任一步失败都不删锁、不把 Status 退回 Ready；只有锁内 winner 能 resume。ownership 不符只拒绝接管，不回退、不删锁。领取时若分支名不以 `-<n>` 结尾，先改成 `<当前名>-<n>`；有 orca 时同步 displayName，没有 orca 时 git 改名仍然成立。该后缀不再当锁。`refs/claims/<n>` 与任务同寿，finalize 不删除。

`new guard install` 之后，任务 worktree 由 bind / 预检把 origin push URL 接到本机 staging，并把 `receivepack` 指到 guard wrapper；这两项以及 `claim` remote 都写入该 linked worktree 的 `config.worktree`，不写 shared `.git/config`。fetch 与 claim 仍直达 GitHub。wrapper 从发起 push 的 worktree 读取显式 Binding，在 `git-receive-pack` 之前把 GitHub refs 镜像进 `refs/guard/github/`（失败 fail-closed）；pre-receive 只从这份 snapshot main 读契约和策略，拒绝 main、非法 message、越界及 hard-deny 路径，连最终被 revert 的任务历史也检查；staging 收下后 post-receive 用一次 `--atomic` 加每条 `--force-with-lease=<old>` 转发；wrapper 把转发失败变成客户端非 0。主工作区不接线。shared transport 若已有 v1.0 legacy、混合值或用户自定义值，bind/approve 不覆盖，先用 `new guard recover --preview` 核对；默认 `new guard recover` 只解除可证明的 legacy 值，第二次是 no-op。

放行判定（zsync、zdev/zfix/zreview、`new task review` 的创建/复用 PR）只用 `derive_task_state`：origin/main 无契约 → Backlog；有契约、无 `refs/claims/<n>` 且无历史 `-<n>` 事实 → Ready；有 claim → 按锁内 winner branch 精确匹配 PR（无开放非 Draft PR → In progress；有开放非 Draft PR → In review；该分支 PR 已合并 → Done）。claim 不可读或 winner branch 缺失则 hard stop，不得退化成 Ready。Status 是视图，放行判定只用推导状态；与 Project Status 不一致只警告，不阻断、不写回。`new task review` 已由耐久事实决定可交付后，末段 Status 漂移不得 return 1、不得写回。互斥由所有机器共同的 `claim` remote 上 `refs/claims/<n>` 原子创建保证。

`zsync` 在 rebase 前检查远端任务分支 SHA 是否为同步前本地 HEAD 的祖先。不是则 hard stop。随后仍用同步前 SHA 做 `--force-with-lease`，不得裸 `--force`。只接受推导为 In progress / In review 的任务。

Issue 绑定只读 worktree-local `new task bind`，读不到就拒绝，不从目录名或分支名猜。

`new task grok` / `new task codex` 在分支预检时，若 Orca displayName 已是合法的 `<domain>/<slug>`，而当前 git 分支恰好等于把其中 `/` 换成 `-` 的结果（例如 displayName `meta/z-agent-workflow`、git `meta-z-agent-workflow`），则在工作树受 Orca 管理且安全、无进行中的 git 操作、目标本地分支不存在、当前分支没有 upstream、源与目标远端分支都不存在时，把本地分支改回 displayName，然后重新读取 git 分支并重跑现有分支与基线校验。已经是规范名则不改。其它不匹配不猜测、不改名。扁平化恢复不改 Orca displayName、Issue 绑定或 worktree 路径；领取加 `-<n>` 后缀时除外，那一步会把 displayName 改成与 git 分支同名。只预检的 `new task` 和 `new task review` 都不改名。

这些命令的授权对象是精确名称本身。只有人在当前已 bind 的任务工作树里实际输入 `new task claim`、`new task grok`、`new task codex`、`new task review` 或 `new z …`，或在 Skill 搜索里明确选择 `zdev` `zfix` `zreview` `zsync` `zmerge` `zpr`，才触发对应动作。人可以用自然语言要求 Agent「输入并执行 `zreview`」或「输入并执行 `new z review`」；真正被授权的仍是那个精确名称。普通自然语言（「开发一下」「帮我审查」「可以交付」「可以合并」「同步一下 main」）不得让任何 Agent 猜测、自动启动或调用 `new task` / z 系列。`new task grok` / `new task codex` 成功领取后自动执行 `zdev`，属于该命令自身的固定后续动作。

`new task review` 只在推导状态为 In progress 或 In review 的受管理 Orca 工作树中运行。工作区必须干净，当前分支相对 `main` 必须有待交付提交。In progress：已有符合条件的 PR 则复用，否则创建。In review：仅当存在唯一、可证明属于当前任务的未关闭 PR 时，重新 push 已审查 HEAD 并更新原 PR；没有匹配 PR 或多个候选 PR 时硬停止，不新建第二个 PR。Project Status 是视图：push 前不探写、不因字段不完整或写入失败停止；PR 建成后 best-effort 写一次 In review，回读不是 In review 只警告，不写回、不失败。复用时只替换 `<!-- new-task-pr -->` 到 `<!-- /new-task-pr -->` 的自动交付区块，区块外的人工说明保留。为修正标题只改 PR 的 title，不覆盖区块外的人工说明。PR 标题必须通过现有 `check-commit-msg.sh --title`：有当前 HEAD 的通过 Review 时用 Squash-Title；没有适用 Review 时，已有 PR 标题或 Issue 标题也必须合法，否则停止。In review 重交付必须已有当前 HEAD 的通过 Review。读取 PR 正文失败或标记不成对则不覆盖。读取 Checkpoint 评论失败、空输出、非数组响应或多条 Checkpoint 时不得另开新楼。不得把任意 In review 当作 `new task review` 的入口。`zmerge` / `zpr` 在 In progress 或 In review 时都调用 `new task review`。Checkpoint 记录交付前 Status 与目标，不把尚未改写的状态写成已经 In review。布尔字段不能用 jq 的 `//` 读取，否则 `isDraft=false` 会被当成空。

`new task review` 不会合并 PR、不会关闭 Issue、不会向 `main` push、不会把状态改为 Done。默认由 `zmerge` 在门禁通过后 squash merge；最终提交标题必须是已校验的 Squash-Title。PR 正文含 `Fixes #号`；合并后由 GitHub 关闭 Issue，Project 的关闭→Done 工作流再改状态。本流程不删除工作树或本地分支。

若 candidate 已含最新 main、当前 HEAD 的 Review 仍有效，但 Guard staging 的 main mirror 单向落后，`zmerge` 只在已有 merge authorization 仍通过且 transaction/lease facts 无歧义时，刷新 staging 的 main、有限重试一次并重新读取全部 merge gates。pending/failed/unknown transaction、lease 歧义、unrelated ref 或非 fast-forward 都 fail-closed；candidate 真落后明确执行 `new z sync`，HEAD 改变必须重新 `zreview`。这条内部 refresh 不 replay forwarding transaction。

下面是用 `new worktree` 自己开视图的流程（非 Orca 的并行工作）。

```bash
# 1. 开工
new worktree reddit-v3 --path 1-code/reddit
cursor ../worktrees/reddit-v3

# 2. 干活。分支上可以碎，因为它会被压扁——`wip:` 在短分支上放行
git commit -m "wip: parser"
git commit -m "wip: dedup"
git commit -m "test(code.reddit): 补 fixtures"

# 3. 收工前自查
new check

# 4. 回主工作区，压成一个提交
cd <workspace-root>
git merge --squash code/reddit-v3
git commit -m "feat(code.reddit): 发布 collector v3"

# 5. 清理
new worktree-clean reddit-v3
git push
```

main 上最后只留一行 `feat(code.reddit): 发布 collector v3`，而不是十几个 `wip`。主线整洁靠的是**短分支 + squash merge**，不是三级合并层级。

第 2 步的「可以碎」有前提：**它成立的唯一理由是第 4 步会压扁。**直接在 main 上干活时这个前提不存在，那里每一条都要是完整的语义单元。上一版这里写的是「过程中随便提交，反正会被压扁」，而实际用法里大量提交是直接落在 main 上的——前提不成立，那句话就成了裸奔许可。

### 跨域分支怎么拆提交

`merge --squash` 把整个分支的改动一次摊进暂存区，然后一条 `git commit`。如果这个分支跨了 `code` / `infra` / `data` 三个域，照这么走只能产出一条多 scope 提交——而多 scope 是例外，不是常态。

分支跨域是对的（这是 monorepo 的主要收益），但**分支跨域不等于提交必须跨域**。squash 之后按意图分批提交：

```bash
git merge --squash code/reddit-v3
git reset                                   # 退出暂存区，改动留在工作区

git add 1-code/reddit
git commit -m "feat(code.reddit): 增量采集"

git add 2-infra/reddit
git commit -m "fix(infra.reddit): 采集器超时上调"

git add 3-data/reddit
git commit -m "collect(data.reddit): 更新契约与首批数据"
```

判据仍然是「是否是独立意图」。如果这三处改动确实是一个不可分割的意图（比如同一个配置项在三处的读取方式必须同时改），那就不要拆，用多 scope 一条：

```bash
git commit -m "fix(code.reddit,infra.reddit): 统一超时配置读取逻辑"
```

## 七、`new worktree` 做了什么

```bash
new worktree <name> --path <p> [--path <p>…] [--branch <b>] [--from <base>]
new worktree --list
```

1. 按第一个 `--path` 的域推断分支前缀（`1-code/` → `code`，`4-know/research/` → `research`…），也可以 `--branch` 显式指定。映射读自 `derived.lock` 的 `git.commit.scope_src`，与 commit-msg 钩子和 daily 回扫共用同一张表
2. 校验每个 `--path` 以及公共可见目录（`0-meta` `.agents`）在基点里**真实存在**
3. 在 `../worktrees/<name>` 建 worktree，`--no-checkout`
4. `sparse-checkout init --cone`
5. `sparse-checkout set 0-meta .agents <你给的路径…>`
6. `checkout`

第 2 步是刻意加的。`sparse-checkout` 对不存在的路径**静默通过**，打错一个字得到的是一个空工作区，而错误要等 AI 干了半天才暴露。

### 为什么无条件带上 `0-meta` 和 `.agents`

AI 至少要能读到 `AGENTS.md`、`policy.yaml`、schema、审计工具，以及 z 系列 Skills。切掉这些省下的那点体积，换来的是一个在没有规则、也调不了 `zdev` 的空间里工作的 agent。

这两项是**公共可见**，不是默认可写。可写范围只来自 Issue「允许改动范围」。`new task` 不得把它们判成稀疏越界，也不得因为它们固定可见就扩大业务写入范围。

仓库根层的文件（`AGENTS.md` `README.md` `.gitignore` `.aiignore` `.cursorignore`）由 cone 模式自动带上，不用单独指定。

> `.cursorignore` 只有被 git 跟踪才会出现在 worktree 里。没跟踪的话，那个 worktree 里 Cursor 的访问边界是失效的——`new worktree` 会就这一点告警。

## 八、`new worktree-clean` 的三道闸

```bash
new worktree-clean <name> [--force]
```

| 检查 | 不过就拒绝 |
| --- | --- |
| 1. 未提交改动（含未跟踪文件） | 有 → 拒绝 |
| 2. 是否已合入 `main` | 否 → 拒绝 |
| 3. 是否另有副本（已合入 或 已推送） | 都没有 → 拒绝 |

没有无条件的 `rm -rf`。

第 2 步同时处理两种合入方式，这一点值得说明：普通 merge 之后分支是 main 的祖先，`--merged` 能认出来；但 squash merge 之后提交完全不同，祖先判定会漏。而 squash 正是这里的默认策略。所以判据是「祖先 **或** 两棵树内容一致」。

只查 `--merged` 的话，每次清理都会误报「未合入」，然后被 `--force` 绕过——**一个总是误报的守卫，等于没有守卫。**

## 九、worktree 的备份缺口

worktree 根在 `<workspace-root>` 之外，默认不在 restic 的备份范围里。

这意味着 AI 在 worktree 里**未提交**的工作是零副本。这恰好推翻了上一版刚立的原则：「git 远端不是备份，所以 `1-code` 也进冷备」——把工作搬到 worktree，又回到了只有 git 保护的状态，而且更糟，因为任务分支通常连 push 都没有。

处理方式有两层：

1. `policy.yaml` 的 `backup.external_paths` 已显式收录 `../worktrees`，restic 配置照它生成
2. `new check` 的 `worktree_hygiene` 扫所有 worktree 的 dirty 状态并告警

在 restic 配置真正落地之前，`worktree_hygiene` 是唯一的防线。**worktree 是短期的，但「短期」不等于「不需要保护」。**

## 十、独立仓库：晋升，不是默认

`1-code/foo` 默认待在 monorepo 里。下面任一条成立时再拆：

准备开源 · 需要外部协作者 · 需要独立 Issues / Release · 独立 CI/CD 复杂到干扰主线 · 需要不同权限 · 其他系统要直接 clone · 生命周期已脱离本工作区

```bash
# 带历史拆出去
git filter-repo --path 1-code/foo --path-rename 1-code/foo/:

# 然后两件事都要做
# 1. 登记到 policy.yaml 的 git.standalone.repos
# 2. 在根 .gitignore 排除 /1-code/foo/
```

漏了第 2 件，内层 `.git` 会被根仓库记成 gitlink：外层 clone 出来是个空目录，而且 clone 的人不会收到任何警告。`new check` 把这两件事绑成一个闭环——登记了但没排除，或者有嵌套 `.git` 但没登记，都是硬失败。

## 十一、七件不要做的事

1. 不要给每个 `1-code` 项目建 GitHub repo
2. 不要建除 `main` 以外的长期分支——按目录切（`1-code` / `2-infra`）和按主题线切（`meta/rules` / `infra/backup`）是同一个错误
3. 不要搞 `project → 1-code → main` 三级合并
4. 不要让 worktree checkout 整个工作区
5. 不要把 branch 当目录分类工具
6. 不要在 monorepo 模式下让项目产生嵌套 `.git`
7. 不要为了 monorepo 把 `5-record`、`_raw`、大二进制、缓存塞进 git

## 十二、以后可能需要的

**另一台机器只想要其中一个项目。**用 partial clone 加 sparse-checkout：

```bash
git clone --filter=blob:none --sparse <url>
cd <workspace-root> && git sparse-checkout set 0-meta .agents 1-code/foo
```

`--filter=blob:none` 只拉需要的文件内容，历史元数据仍然完整。现在不用配，等真有这个需求再说。

## 十三、度量

每个受管理入口结束时追加一行 JSON 到本机 `${XDG_STATE_HOME:-~/.local/state}/<origin-id>/metrics.jsonl`（`<origin-id>` 由 origin 推导，例如 `github.com-owner-repo`）。
只追加、不改写、不进 git、不在任何任务的允许范围内；写失败只打一行警告，入口的退出码和行为不变；
度量代码不联网，Issue 标签取自入口本来就要读的那份 Issue JSON。

入口名是 `<命令>.<动作>`：`new-task.precheck` / `new-task.claim` / `new-task.review`，
以及 `.agents/skills/<skill>/scripts/<action>.sh` 派生的 `zdev.wip-commit`、`zsync.sync-main`、
`zreview.publish-review`、`zpr.open-pr`、`zmerge.squash-merge` 等。`zfix` 复用 zdev 的脚本，
所以它的事件记为 `zdev.*`。

一行的字段：`ts`（UTC）、`issue`、`entry`、`result`（ok|fail）、`reason_code`、`detail`、
`duration_ms`、`agent`（由 `new task grok|codex` 通过 `NEW_TASK_AGENT` 传给会话内的 z 脚本）、
`head`、`labels`、`task_class`、`loaded_bytes`。

`reason_code` 只在 fail 时非空：稳定标识符，形如 `<action>.<snake_case>`（例 `claim.remote_ref_exists`）。
同一类故障全库一个 code，不写自然语言，不含空格和中文。ok 时为空。未赋码的失败落成
`<action>.unclassified`（action 是 entry 点号后的段）。`detail` 是去掉颜色和「✗」后的自由文本。

事件先按入口分类：`new-task.approve` 与 `new-task.bind` 是尚未绑定任务的
`control-plane` 事件；其余 `new-task.*` 与 canonical `z*` 是 `task-runtime` 事件。
其它入口不参与受管理事件健康判定。control-plane 事件允许 `issue`、`task_class` 为空，
也不进入 `framework:business` 统计；task-runtime 事件仍要求这些字段完整。

`task_class` 对 task-runtime 事件是 `framework` 或 `business`，按契约允许改动范围推导：
任一路径等于或位于 `0-meta/`、`.agents/` 之下，或是它们的祖先（如 `.`），就是 framework；
否则 business。不按 Issue 标签。scope 解析不到则留空。

`loaded_bytes` 只在 `new-task.claim` 有值：开工 prompt 的字节数，加上 prompt 明确要求 Agent 阅读的
每个文件在工作树里的实际字节数。文件清单与 prompt 文本共用 `task.sh` 里的 `TASK_PROMPT_READS`，
改一处两边同变。这是「agent 开工前被要求读多少」的直接度量，也是提示词瘦身的验收口径。

```bash
new metrics             # 入口 × 结果、耗时 p50/p90、开工加载中位数、framework:business、reason_code 计数
new metrics --since 7d  # 只看最近 7 天
```

用法：顾虑清单里的事项，只有同一 `reason_code` 的失败在度量里出现 ≥ 2 次，或造成一次 P0，才进入下一轮。
framework 与 business 任务比按允许改动范围算，不按标签。

## 检查清单

- [ ] 根仓库有 remote，且 main 已推送
- [ ] `git ls-files` 里没有 `5-record` 档案本体、没有保留名目录、没有明文凭据
- [ ] `1-code` 下没有未登记的嵌套 `.git`
- [ ] 每个 standalone 都同时登记在 policy 和根 `.gitignore` 里
- [ ] worktree 都是干净的，或者已经确认能接受零副本
- [ ] 已合并的分支和 worktree 都清理掉了
- [ ] `pre-commit` 和 `commit-msg` 两个钩子都在 `$(git rev-parse --git-common-dir)/hooks/` 里
- [ ] `enforce_after` 之后的主线提交全部符合提交语言（`new check` 的 `commit_convention`）
