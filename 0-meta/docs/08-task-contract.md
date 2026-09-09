# Task Contract 生命周期

人在 Issue 正文里写契约。`new task approve <n>` 把它解析后写入 `origin/main:0-meta/tasks/<n>/contract.md`（原文）与 `contract.json`（规范化结果）。领取、wip 提交、Review、交付、合并五处门禁只从这份文件读。Ledger / digest / drift / trusted-ruleset / bootstrap / 扩范围命令已由契约进 main(#27)取代。

```
Issue 正文 → new task approve → origin/main 契约文件 → Checkpoint / Review / PR / squash
```

Ready 的含义是：契约文件已经在 origin/main。没有这份文件就不能领取。

## 三层事实

1. **流程底线**在 `0-meta/schema/task-contract.v1.yaml` 与 `0-meta/lib/new/contract.sh`。单个任务不能靠改自己的 Issue 放宽。`0-meta/tasks/` 永不进入允许范围。
2. **任务基准**是目标、R、A、A→R、允许改动范围。它们只存在于 origin/main 上的契约文件。
3. **阶段事实**是进度、验证、Review、PR。必须绑定当前 Contract（blob SHA）与适用 HEAD。

发现下游与契约不一致时，不自动改文件。先判断实现未完成、证据不足、Review 误判，还是定义确需修订。

## 结构化 Review 与 validator

canonical `new z review` 接受 `0-meta/templates/task-contract-review-input.md` 所定义的逐行输入：`verdict`、`title`、`notes`，以及每个 Contract R/A 各一行的 `状态 | 证据`。空行和注释行以外的非法行按准确行号拒绝；不从 notes、证据或其它散文反向猜测 R/A。未知、重复、缺失 R/A，空证据和纯状态词都拒绝。

工具从 `origin/main` 的 Contract 补齐 Issue、Contract blob、当前 `HEAD` 和真实 diff 路径，再渲染唯一 Review。Review 的 `review_actor=<id>`、`claim_actor=<id>`、`Self-review=yes|no` 是 marker 块内的精确 machine fields；Review 不重新声明 Contract 之外的 R/A。

Contract A 只能通过 `validator:<id>` 引用固定 registry，不携带 shell 命令。当前 registry 至少包含 `new-check-commit`、`contract-test`、`bash-syntax`。canonical Review 在当前 task worktree 中执行登记项，记录 validator id、exit code 和截断输出；结果追加到对应 A 的证据，validator 失败可将 A 置为不通过并阻止 Verdict=通过，validator 成功不覆盖 reviewer 的语义状态。未知 validator 在 approve 或消费 Contract 前拒绝。

actor 是 provenance，不是认证。缺省链固定为显式 `--actor` → `NEW_TASK_ACTOR` → 当前 worktree 生效的 `git config user.email`；全空或非法即 fail-closed。claim 写 `claim_actor`，Review 写 `review_actor`；二者不同才是独立 Review。相同 actor 只有显式 `--allow-self` 才允许，且 Issue 必须已有 `human-merge` 标签并写 `Self-review=yes`。zmerge 读取唯一 Review 的这个 machine field，看到 `Self-review=yes` 就以稳定 `z.self_review_forbidden` 拒绝自动 squash。

## 批准与版本

人在主工作区、main 分支上运行：

```bash
new task approve <n>
```

读取 Issue 正文 → v1 解析（失败则打印缺失项，不写任何东西）→ 写入两个文件 → 单个提交 → push origin main。Backlog → Ready；在途任务只换契约、不动 Status。Status 写失败只警告：文件已在 main 就算批准成功。内容未变时再跑一次是 no-op。

契约版本就是 `git rev-parse origin/main:0-meta/tasks/<n>/contract.json` 的 blob SHA。Checkpoint、Review、PR 只有一个 `Contract` 字段，值是这个 SHA。与当前 origin/main 上的 blob 不同即 stale，交付与合并拒绝。

扩范围：改 Issue → `new task approve <n>` → 工作树 `git sparse-checkout add`。没有单独的扩范围命令。

## 阶段门禁

五处门禁使用前 `git fetch origin main`。fetch 失败 hard stop，不用本地陈旧副本。

- 领取：`origin/main` 上必须有契约文件，否则拒绝，错误末行是 `new task approve <n>`。scope、R/A 取自文件；Issue 正文不一致只警告。
- wip / Review / 交付 / 合并：同一读源。真实 `origin/main...HEAD` diff 必须落在获准范围内。Review 或 PR 的 Contract 与当前 blob 不同则 stale。

## 路径安全

staged / diff 路径用 NUL 分隔逐条读。新增、复制、修改、重命名两端、删除、type change 全部进入判定。含空格路径是单一值。允许改动范围只认列表项；说明句里的反引号词不算路径。允许范围写了 `0-meta/` 时，触及 `0-meta/tasks/**` 仍被拒绝。

## Framework freeze

本仓是 canonical G-lite framework source。候选 runtime 不得管理自己；framework 任务走外部 Harness + human-merge。操作说明见 [`10-framework-freeze.md`](10-framework-freeze.md)，决策见 [`4-know/decision/framework-freeze.md`](../../4-know/decision/framework-freeze.md)。
