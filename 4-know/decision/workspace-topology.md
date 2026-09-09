---
id: workspace-topology
type: decision
status: active
topic: [meta, topology]
scope:
  - repo
  - meta.policy
primary_scope: repo
confidence: medium
created: 2026-08-31
review: 2027-08-31
---

# 顶层固定八个域，保留名在任意深度覆盖继承

> 这份记录是 2026-08-31 事后补写的，不是决策当时写的。决策落在 `ad7dfa9`
> （`chore: init Projects2 workspace (policy v2.2)`），那条提交正文 49 字节，
> 只有一行 `Co-authored-by`，没有任何理由。下面的理由是从 `policy.yaml` 的注释、
> `README.md` 与 `0-meta/docs/` 反推的，出处逐条列在最后。

## 背景与约束

需要决定工作区按什么轴切分顶层目录，以及策略挂在哪一层。

v1 是带数字前缀的深层嵌套。散落在 `policy.yaml` 的 `catches` 字段和 `docs/` 里的实证路径
足以还原它的形状：`40-asset/secrets/`、`60-app/`、`60-script/`、`60-dev/`、
`70-infra/70-vps/credentials/secrets/vps-backup.env`。前缀数字是主题分组，同一个数字下再套
一层同样带数字的子域，然后才是内容。

两个后果留了记录：

- **治理止步第 2 层。**`policy.yaml` 头部把「`reserved_dirs` 在任意深度生效」列为 v2 相对 v1
  的第 4 项关键差异，也就是说 v1 的策略只挂到第 2 层，第 3 层往下没人管。
- **深处正好是爆炸半径最大的地方。**`70-vps/credentials/ssh-keys/` 下 8 把无口令私钥、
  `vps-backup.env`、`40-asset/secrets/Chrome 密码.csv`——而 v1 把 `credentials/` 与 `secrets/`
  加进了排除名单，这三处永远不会被报出。

要注意的是「顶层集合固定 + 审计验证个数」这个想法本身**是从 v1 继承的**
（`audit.checks[topology].inherited_from: v1`）。v2 换掉的不是「要不要固定顶层」，
而是**按什么轴切**和**策略挂在哪一层**。

## 考虑过的选项

| 方案 | 优 | 劣 |
| --- | --- | --- |
| 按主题／领域分类，数字前缀深嵌套（v1 的形态） | 目录名自解释，凭直觉能找到 | 一个东西只能进一个位置；策略跟着路径走，第 3 层以下无人治理，而私钥恰恰在第 3 层以下 |
| **顶层固定八域 + 保留名任意深度生效**（选定） | 每个域一行策略，子目录默认继承；保留名让策略下沉到全部层级 | 顶层集合是硬编码的，加一个域要同时改 `policy.yaml` 和审计第 1 项 |
| 扁平目录 + 全靠 frontmatter 属性 | 不用为「放哪」做选择 | 备份、同步、git 跟踪、AI 边界四类判断都需要路径级判据，扁平之后只能逐文件读 frontmatter |

## 决定

顶层八个域，每个域一条策略行：`sensitivity` / `vcs` / `backup` / `sync` / `retention` / `naming`。
子目录默认继承所属域，除非命中保留名——保留名在任意深度携带自己的策略并覆盖继承。
审计第 1 项把「顶层只有 8 个」做成硬失败。

切分轴不是主题，是三个可判定的问题：**丢了能不能重新生成、能不能给别人看、谁在管它。**
这三问就是 `README.md` 那棵决策树。

主题这条轴没有消失，它挪进了 frontmatter。`4-know/AGENTS.md` 把理由写得很直接：一篇资料
可以同时属于「方法论」「某领域」「某项目」「待读」，文件夹强迫你选一个，属性不用。所以
**域间靠路径，域内靠属性**。

## 后果

- 顶层不可随手扩展。加第九个域要改 `policy.yaml` 的 `domains` 段，还要改审计第 1 项的期望值。
- 落点判定要人先答三个问题。答不上来只能进 `_inbox`，而 `_inbox` 30 天过期就是审计失败——
  这个压力是刻意的，但它确实是压力。
- 域即路径，于是「一个逻辑变更跨多个域」成了常态。改造 collector 会同时动代码、部署、数据契约
  和决策记录，`README.md` 承认了这点，提交语言也因此允许 scope 用 `,` 分隔。
- `5-record` 留在工作区里，它的实际保护等级就等于 layer 2 adapter 的覆盖面。
  `06-权限边界.md` 写明对 Codex 与 WorkBuddy 而言 layer 2 是空的——这是当前最大的敞口，
  而它是这个拓扑选择的直接后果。

## 什么情况下要重新考虑

- 有一类东西在三个问题上都答不清，反复落进 `_inbox` 又反复被搬走。
- `5-record` 迁进独立加密卷之后（`06-权限边界.md` 的 layer 3）。一个默认不挂载的卷还算不算
  「工作区的一个域」，届时要重新回答。
- 保留名从六个涨到十个以上。那说明策略下沉的粒度选错了，该改成按属性判定而不是按名字判定。

## 取证空缺

以下三条在仓库里找不到依据，需要你补或确认：

1. **为什么恰好是这八个，当初有没有别的候选切法。**上面那张选项表里，只有「v1 深嵌套」这一行
   有实证；另两行是按现有约束反推的，不代表当时真的比较过。
2. **v1 / v2.0 / v2.1 的完整形态。**`schema_version: workspace-policy/v2.2` 说明至少有三代，
   但那段历史不在本仓库。目前只能从 `catches` 字段里逆推出五六个 v1 目录名
   （`40-asset` `60-app` `60-script` `60-dev` `70-infra/70-vps`），拼不出完整拓扑。
3. **`policy.yaml` 头部引用了两个不存在的文件**：「人类可读解释见同目录 DESIGN.md，迁移映射见
   MIGRATION.md」。`0-meta/` 下两个都没有。DESIGN.md 本该承担的正是这份 ADR 的职责——
   要么补出来，要么把那两行删掉，别留悬空引用。
4. **保留名到底是几个，两处文档不一致。**`policy.yaml` 的 `reserved_dirs` 和
   `git.never_reserved` 都是六个（含 `_files`），提交语言那份词表也是六个，
   而 `README.md` 的速查表标题写「五个保留名」、表里只列五个。
   `_files` 是漏了还是刻意不算，需要你定，然后把不对的那处改掉。

## 依据出处

| 说法 | 出处 |
| --- | --- |
| 域即一条策略，子目录继承，保留名覆盖 | `0-meta/policy.yaml` 第一、二段（`domains` / `reserved_dirs`） |
| 治理从第 2 层下沉到全部层级是 v2 的关键差异 | `0-meta/policy.yaml` 头部注释第 4 条 |
| v1 的目录名与第 3 层以下的私钥 | `0-meta/policy.yaml` `audit.checks[plaintext_secrets].catches` |
| v1 的深嵌套形态与明文口令 | `0-meta/docs/05-备份与恢复.md`「上一代的口令明文躺在…」 |
| 固定顶层集合这个检查继承自 v1 | `0-meta/policy.yaml` `audit.checks[topology].inherited_from` |
| 三个问题的决策树 | `README.md`「东西该放哪里」 |
| 主题分类交给 frontmatter | `4-know/AGENTS.md`「不靠文件夹分类，靠 frontmatter 属性」 |
| 顶层只有 8 个是硬失败 | `0-meta/AGENTS.md` 审计第 1 项 |
| 5-record 的 layer 2 敞口 | `0-meta/docs/06-权限边界.md` |
