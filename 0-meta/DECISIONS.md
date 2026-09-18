# 架构决策索引

由 `new adr --index` 生成，**不要手改**。事实源是 `4-know/decision/` 各文件的 frontmatter。

`new check` 会重新渲染一遍并与本文件逐字节比较，改了声明没重算、或手改过本文件，都会报出来。

级别不是单独的字段，由 `primary_scope` 的形状推：裸 domain 体系级，单元目录是单元级，
分组内成员是成员级。**级别回答「声明得多粗」，不回答「影响面多大」**——影响面要读正文。
词表、真实路径与级别都由提交语言的 scope 工具统一解析。

## 体系级

声明粒度是整个域。裸 `repo` / `meta` 约束整个工作区，其余域只约束自己那一块。

| 决策 | 主归属 | 状态 | 记于 |
| --- | --- | --- | --- |
| [Project-qiaoen 停止作为 G-lite framework 上游](../4-know/decision/framework-freeze.md) | `repo` | archived | 2026-09-09 |
| [整个工作区一个私有仓库，项目不各自建 repo](../4-know/decision/monorepo.md) | `repo` | active | 2026-08-31 |
| [备份与同步清单由 policy.yaml 推导，落成进 git 的 lock 文件](../4-know/decision/policy-single-source.md) | `meta` | active | 2026-08-31 |
| [顶层固定八个域，保留名在任意深度覆盖继承](../4-know/decision/workspace-topology.md) | `repo` | active | 2026-08-31 |

## 单元级

作用于一个项目、一个基础设施单元或一个数据集。

| 决策 | 主归属 | 状态 | 记于 |
| --- | --- | --- | --- |
| [冷备用 restic，两个不相关的异地目的地](../4-know/decision/restic-cold-backup.md) | `infra.backup` | active | 2026-08-31 |

## 按 scope 反查

「我在改 X，它背后有哪些决策」——各目录 `AGENTS.md` / `README.md` 里的受控块是同一份数据的就近副本。

| scope | 决策 |
| --- | --- |
| `code` | [整个工作区一个私有仓库，项目不各自建 repo](../4-know/decision/monorepo.md) |
| `data` | [备份与同步清单由 policy.yaml 推导，落成进 git 的 lock 文件](../4-know/decision/policy-single-source.md) |
| `infra.backup` | [备份与同步清单由 policy.yaml 推导，落成进 git 的 lock 文件](../4-know/decision/policy-single-source.md)、[冷备用 restic，两个不相关的异地目的地](../4-know/decision/restic-cold-backup.md) |
| `meta` | [Project-qiaoen 停止作为 G-lite framework 上游](../4-know/decision/framework-freeze.md)、[备份与同步清单由 policy.yaml 推导，落成进 git 的 lock 文件](../4-know/decision/policy-single-source.md) |
| `meta.policy` | [冷备用 restic，两个不相关的异地目的地](../4-know/decision/restic-cold-backup.md)、[顶层固定八个域，保留名在任意深度覆盖继承](../4-know/decision/workspace-topology.md) |
| `repo` | [Project-qiaoen 停止作为 G-lite framework 上游](../4-know/decision/framework-freeze.md)、[整个工作区一个私有仓库，项目不各自建 repo](../4-know/decision/monorepo.md)、[顶层固定八个域，保留名在任意深度覆盖继承](../4-know/decision/workspace-topology.md) |

## 时间线

按记录日期排。这一节回答「当时在解决什么问题」，级别分组回答「现在这套东西为什么长这样」。

- **2026-08-31** `体系级` [整个工作区一个私有仓库，项目不各自建 repo](../4-know/decision/monorepo.md) — `repo`，active
- **2026-08-31** `体系级` [备份与同步清单由 policy.yaml 推导，落成进 git 的 lock 文件](../4-know/decision/policy-single-source.md) — `meta`，active
- **2026-08-31** `单元级` [冷备用 restic，两个不相关的异地目的地](../4-know/decision/restic-cold-backup.md) — `infra.backup`，active
- **2026-08-31** `体系级` [顶层固定八个域，保留名在任意深度覆盖继承](../4-know/decision/workspace-topology.md) — `repo`，active
- **2026-09-09** `体系级` [Project-qiaoen 停止作为 G-lite framework 上游](../4-know/decision/framework-freeze.md) — `repo`，archived
