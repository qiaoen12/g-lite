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

工具从 `origin/main` 的 Contract 补齐 Issue、Contract blob、当前 `HEAD` 和真实 diff 路径，再渲染当前 Review tip。Review 的 `review_actor=<id>`、`claim_actor=<id>`、`Self-review=yes|no|unknown` 是 marker 块内的精确 machine fields；Review 不重新声明 Contract 之外的 R/A。

Contract A 只能通过 `validator:<id>` 引用固定 registry，不携带 shell 命令。当前 registry 至少包含 `new-check-commit`、`contract-test`、`bash-syntax`。canonical Review 在当前 task worktree 中执行登记项，记录 validator id、exit code 和截断输出；结果追加到对应 A 的证据，validator 失败可将 A 置为不通过并阻止 Verdict=通过，validator 成功不覆盖 reviewer 的语义状态。未知 validator 在 approve 或消费 Contract 前拒绝。

actor 只是领取/展示身份，不是 execution provenance，也不是认证。缺省链仍是 `--actor` → `NEW_TASK_ACTOR` → 当前 worktree 的 `git config user.email`；全空或非法 fail-closed。换 `--actor`、新 UUID、PID、机器名、模型名或终端名都不能单独证明独立 Reviewer。独立性必须相对形成当前 candidate 的全部 dev/fix execution 及其 continuation/fork lineage。只有宿主或受控 launcher/hook 捕获的 `source_ref` 为 `verified`，且与这些开发来源无交集，才能写 `Self-review=no`。无法证明时写 `unknown` / `unknown-unverified`，不得自动宣称独立 PASS。`--allow-self` + `human-merge` 只是显式人工 self-review（`Self-review=yes`），不是未知身份的 fallback。zmerge 看到 `Self-review=yes` 或缺少可证明的 `no` 都拒绝自动 squash。

## 阶段事实与 tip / history

`new z dev` / `new z fix` / `new z review` 共用一个有界 loader，恢复 Contract、binding、当前 HEAD、有界 diff、当前 Checkpoint tip、当前 Review tip、未关闭 findings、PR、provenance 摘要和 next canonical command。正常恢复不灌入全部历史正文；完整历史按 comment id 按需追溯。

Checkpoint / Review 的当前 tip 仍由 `<!-- new-task-checkpoint -->` / `<!-- new-task-review -->` 唯一标识。新写入先把上一轮正文归档为 `*-history` 评论，并在 tip 上留下 `prev_fact_id` 与 Historical facts 引用。重复 tip、分叉、损坏引用 fail-closed，不按 `created_at` 猜最新。不引入新账户数据库。

v1.0.0 的 Contract / binding / Checkpoint / Review，以及 #13 completion 与 delivery shape，保持只读兼容。缺 #16 provenance 字段记为 `unknown-unverified`，不改写旧正文，不补造旧身份。

## Review applicability 与下一步

当前适用 PASS 至少要求：`reviewed HEAD ==` 当前 candidate HEAD，`reviewed Contract blob ==` 当前 `origin/main` Contract blob，Review 结构与 provenance 合法，current fact 无冲突。`zsync=noop` 且这些条件未变则保留 PASS。rebase 或其它操作改变 HEAD SHA、或 Contract-only change，都要求新 Review。ancestry 只诊断 HEAD 为何变化，祖先 PASS 不能覆盖后代 candidate。

next canonical command 由当前事实派生：completion 未成立 → `continue development`；completion 已成立且无适用 Review → `new z review <review-input>`；适用 Review 为不通过 → `new z fix`；fix 形成新 HEAD → 再 review；适用独立 PASS → 按现有 `human-merge` / `new z pr` / `new z merge` 政策。

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
