# 4-know — 知识与研究

## 核心思路

**不靠文件夹分类，靠 frontmatter 属性。**

一篇资料可以同时属于「方法论」「某领域」「某项目」「待读」——文件夹强迫你选一个，属性不用。这就是 Notion 数据库的能力，用本地 markdown 就能拿到，同时保持可 grep、可 git、可被 agent 读。

视图靠 Obsidian Bases / Dataview 生成，不靠目录树。

## 七个子目录（按"是什么"分，不按"讲什么"分）

| 目录 | 放什么 | `type` |
| --- | --- | --- |
| `note/` | 自己的想法、总结、经验 | `note` |
| `source/` | 外部资料的摘录，**必须有 `source` 字段** | `source` |
| `decision/` | 技术选型、方案决策（ADR） | `decision` |
| `runbook/` | 操作手册、SOP | `runbook` |
| `research/<topic>/` | 成体系的调研 | `note` |
| `writing/` | 对外长文草稿 | `note` |
| `report/` | 成篇的自用技术报告与复盘，单文件 HTML | — |
| `_files/` | PDF、图片等附件，不进 git | — |

`report/` 放的是已经成篇、不再修改的报告，文件名即检索句柄，所以命名固定成
`YYYY-MM-DD-<主题>.html`（日期前缀让文件名排序等于时间排序，与
`0-meta/audit/restore-drill/` 同一套）。它们进 git：单份不到 100 KB，写一次就不改，
不产生 diff 噪音，换来的是版本历史、异地副本和 agent 可读。要检索「我写过什么」
看 `note/` 里的报告索引，不要去 grep HTML。

## 每个 .md 必须有 frontmatter

```yaml
---
id: cf-waf-rules          # 稳定标识符，建立后永不修改。跨文档引用靠它，不靠路径
type: note                # note | source | decision | runbook
status: active            # draft | active | archived
topic: [infra, cloudflare]  # 多值，这是替代文件夹的关键
source: https://…         # type=source 时必填
confidence: medium        # high | medium | low
created: 2026-08-26
review: 2027-02-26        # 复审日期，过期由审计报出
---
```

`id` 稳定意味着：文件重命名、换目录、内容重写，引用都不断。

`review` 是防止知识库腐烂的机制——技术类笔记建议 6 个月，方法论类 2 年。审计的 `retention` 一项会报出过期的；`status: archived` 的文档不再参与复审。

## 决策记录额外两个字段

`type: decision` 必须再声明 `scope` 与 `primary_scope`：

```yaml
scope:                    # 这条决策作用于哪几块。词表 = 提交语言的 scope
  - infra.backup
  - meta.policy
primary_scope: infra.backup   # 主归属，须是 scope 的一项；多个地位平等时填 null
```

`topic` 与 `scope` 不重叠：`topic` 回答「讲的是什么主题」，自由造词；`scope` 回答「改的是哪块」，必须落在已有词表里，因为它要被索引消费。

**多值是必须的，不是方便。**现有决策里多数跨域，写成单值就得挑一个错的主人。空列表显式写 `[]`；行内写法 `scope: [a, b]` 不认，会被当场拒绝，不会静默算成 0 项。

级别不是字段，由 `primary_scope` 推：裸 domain 体系级，单元目录是单元级，分组内成员是成员级。**「体系级」说的是声明粒度，不是影响面**——裸 `repo` / `meta` 确实约束整个工作区，裸 `data` / `vendor` / `inbox` / `record` 只约束自己那个域。从目录树派生的 scope 按实际路径深度定级，不能只数点号，因为合法目录名本身可以含点；同一 scope 同时映射到点号目录和分组成员时会被拒绝。四个语义别名（`meta.policy` `meta.agents` `meta.new` `meta.hooks`）绑定文件而非目录层级，级别按点号段数定。

改完 `scope` 要在完整工作树跑 `new adr --index`，它重算 [`0-meta/DECISIONS.md`](../0-meta/DECISIONS.md) 并刷新各目录 `AGENTS.md` / `README.md` 末尾的受控块。sparse worktree 会被拒绝；marker 不完整时也会在改写前停止。审计的 `decision_links` 会重新渲染并逐字节比对，过期或手改都会报出来。完整说明见 [`0-meta/docs/03-知识库.md`](../0-meta/docs/03-知识库.md)。

## 研究怎么做

```
research/<topic>/
├── QUESTION.md      研究问题 + 纳入/排除标准（必须事先写）
├── screening.csv    检索式、数据库、命中数、纳入决策
└── notes/           每篇一个文件
```

`screening.csv` 解决的是「我对这个领域的了解是否完整」。它把「我读过一些资料」变成「检索了 X 个库、命中 N 篇、按事先声明的标准纳入 M 篇」——前者无法复核，后者可以。

## 什么时候用 Notion

只有一个场景：**需要和非技术的人共享或协作填写**。那属于对外接口，用完把结论沉淀回这里。

事实源永远在本地，理由是：agent 要 grep、决策记录要 git 历史、导出有损会锁死你。

## 策略

| 敏感度 | Git | 冷备 | 热同步 | 保留 |
| --- | --- | --- | --- | --- |
| 内部 | 必须（文本部分） | 是 | 是 | 永久，按 `review` 复审 |

`_files/` 里的附件不进 git（体积大），但进冷备。
