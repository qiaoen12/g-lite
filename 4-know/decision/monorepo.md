---
id: monorepo
type: decision
status: active
topic: [meta, git]
scope:
  - repo
  - code
primary_scope: repo
confidence: medium
created: 2026-08-31
review: 2027-08-31
---

# 整个工作区一个私有仓库，项目不各自建 repo

> 事后补写于 2026-08-31。决策本身落在 `ad7dfa9`（`policy v2.2`），提交正文空白。
> 但这一条的理由在 `0-meta/docs/02-代码项目.md` 和 `policy.yaml` 的注释里写得很完整，
> 下面基本是把它们收拢到一处，不是我推的。

## 背景与约束

v2.1 的设计是**每个项目一个独立 git 仓库**：`policy.yaml` 里 `1-code` 域的字段原本是
`vcs: required` + `vcs_remote: required` + `child_is_repo: true`。

放弃它的理由不是 monorepo 更好，而是原设计**把治理面切碎了**。`policy.yaml` 号称唯一事实源，
却看不见任何一个子仓库的内部状态——有没有 push、有没有把 `.env` 提交进去、分支停在哪。
几十个项目就是几十个 policy 管不到的盲区。

**「项目各自管自己的仓库」这件事有实测数据，不全是推演。**`copy_count` 是 v2 新增的检查，
它第一次真的去看 VCS 状态，`catches` 字段记下了当时在 v1 那棵树上的结果：
`60-app` 与 `60-script` 下 15 个项目根本没有 git，`60-dev` 下 5 个没有，
`developer-roadmap-bilingual` 无 remote 且 121 个改动未提交。同一条注释点出根因：
**v1 只测量文件系统，从不测量 VCS 状态——而 VCS 状态才是「有几份副本」的最强信号。**

这批数据严格说是 v1 的账，不是 v2.1 运行结果的账（v2.1 有没有实际跑过见取证空缺）。
但它回答的正是同一个问题：把建仓库这件事交给每个项目自己，纸面上是 20 份独立历史，
实际交付的是 20 个零版本控制的目录。

场景是一人维护 + 大量 AI agent 并行，几十次 `git init`、几十次配 remote、几十处 push 状态
要单独查，成本压不住。

## 考虑过的选项

| 方案 | 优 | 劣 |
| --- | --- | --- |
| 一个项目一个仓库（v2.1 的形态） | 项目边界清晰，可以单独开源、单独配 CI、单独给权限 | 实测下来 20 个项目根本没有 git；policy 看不见任何子仓库内部；副本数检查要做几十次独立测量 |
| **整个工作区一个私有 monorepo，一条 `main`**（选定） | 一个 remote、一次副本数测量；跟踪范围由 policy 统一声明；跨域改动天然是一个 commit | 跟踪范围和备份范围必须靠机制区分；误提交敏感目录的清理成本极高；fork 类项目装不进来 |
| 按域分仓（几个中等仓库） | 折中 | 无记录，见取证空缺 |

## 决定

`git.mode: monorepo`，`root: .`，`default_branch: main`，`1-code` 域 `child_is_repo: false`。
`AGENTS.md` 把「禁止在 `1-code/` 项目里 `git init`」列为硬约束——嵌套 `.git` 会被根仓库记成
gitlink，clone 出来是空目录。

`per_project` 这个取值刻意保留在 `policy.yaml` 里，为的是让 `new code` 读模式再决定行为，
而不是把 monorepo 逻辑硬编码进脚本。

关键的配套区分：**「Projects2 是一个 git repo」不等于「所有文件都进 git」。**
跟踪范围由 `tracked_domains` / `partial_domains` / `never_domains` 声明，
和备份范围是两个独立判断——备份问「丢了能不能回来」，git 问「值不值得留改动历史」。

独立仓库不再是默认，而是**晋升**：见 `git.standalone`。

## 后果

- **误提交的清理成本极高。**把 `5-record` 或 `_raw` 提交进去之后，文件已经进历史，要
  `git filter-repo` 重写再强推。所以 `git_hygiene` 被放进 commit 档（`README.md` 说明这是
  刻意的），判据是 `git ls-files` 的实际输出而不是 `.gitignore` 的内容——`.gitignore` 只能阻止
  未来的 `add`，不会让已经 tracked 的文件消失。
- **fork 装不进来。**放进 monorepo 就没法 `git fetch upstream`，也没法向上游提 PR。
  `02-代码项目.md` 把 fork 列为「少数必须保持独立仓库的情况」。
- **standalone 要维护两处一致。**登记进 `git.standalone.repos` 的路径必须同时出现在根
  `.gitignore` 里，否则内层 `.git` 被记成 gitlink 然后一直报错。这条靠 `git_hygiene` 闭环校验。
- **`git add .` 只加当前目录。**跨域改动要么分别 add，要么回根目录一次性提交。
- 单一仓库让「一条线的工作能不能溯源」这个需求失去了分支这个（错误的）答案，
  必须靠路径历史 + 提交 scope + ADR 三层来接。见 `0-meta/docs/07-git-工作流.md` 第五、六节。

## 什么情况下要重新考虑

`policy.yaml` 的 `git.standalone.promote_when` 已经把触发条件写成了清单，就是这一节：

- 准备开源
- 需要外部协作者
- 需要独立 Issues / Release
- 独立 CI/CD 复杂到会干扰主线
- 需要不同的访问权限
- 其他系统需要直接 clone 该项目
- 生命周期已明显脱离 Projects2

命中任一条时**拆单个项目出去**，不是推翻 monorepo：
`git filter-repo --path 1-code/foo --path-rename 1-code/foo/:`。

真正要推翻整个决定的信号只有一个：根仓库大到 clone 和 `ls-files` 慢得让 commit 档超预算。
commit 档的预算是 3 秒，它一旦守不住，hook 就会被关掉，而被关掉的门禁比没有门禁更糟。

## 取证空缺

1. **「按域分仓」这个中间方案有没有被考虑过**，没有任何记录。选项表里这一行是我补的，
   标着无记录。
2. **v2.1 到底有没有实际运行过，以及那 20 个无 git 的项目后来怎么处理的。**
   `catches` 里的数据是 v1 那棵树的，v2.1（每项目一仓库）是否真的落地过、
   落地后有没有出现新的盲区，没有记录。那 20 个目录是被迁进 monorepo、被归档，
   还是仍然散在 v1 的树里，同样没有记录——v1 那棵树现在的状态不在本仓库。
3. **晋升路径从未被走过。**`git.standalone.repos` 现在是 `[]`，意味着
   `promote_when` / `history_extraction` 那套流程一次都没验证过，
   包括「登记进 policy 同时要进根 `.gitignore`」这条闭环校验有没有真的拦得住。
4. **长期分支只有 `main` 这条决策没有独立记录。**`policy.yaml` 的
   `branching.long_lived` 注释里写了「曾考虑过 `main` / `1-code` / `2-infra` 三条长期分支，
   按目录切分——这是个概念错误」，理由完整但躺在配置注释里。它和本条是两个决策，
   建议单独开一条 ADR，本文不代它。

## 依据出处

| 说法 | 出处 |
| --- | --- |
| v2.1 原形态与放弃理由 | `0-meta/policy.yaml` `domains.1-code` 的 v2.2 修正注释 |
| v1 实测：20 个项目无 git、121 个改动未提交 | `0-meta/policy.yaml` `audit.checks[copy_count].catches` |
| 治理面被切碎、顺带消掉的成本 | `0-meta/docs/02-代码项目.md`「为什么不是一人一个仓库」 |
| `per_project` 保留取值的用意 | `0-meta/policy.yaml` `git.mode` 注释 |
| 跟踪范围 ≠ 备份范围 | `0-meta/policy.yaml` 第九段头部注释；`README.md` |
| 禁止嵌套 `git init` | `AGENTS.md` 硬约束表 |
| `git_hygiene` 进 commit 档的理由 | `README.md`「审计十四项」下方说明 |
| fork 必须独立 | `0-meta/docs/02-代码项目.md`「clone 别人的仓库」 |
| 晋升条件与历史提取命令 | `0-meta/policy.yaml` `git.standalone` |
| 三层溯源代替分支 | `0-meta/docs/07-git-工作流.md` 第五、六节 |
