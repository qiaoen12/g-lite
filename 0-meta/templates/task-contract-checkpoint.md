<!-- new-task-checkpoint -->
claim_actor=ACTOR_ID
fact_id=TIP_COMMENT_ID
prev_fact_id=PREV_FACT_ID
provenance_version=1
source_type=unknown
role=dev
verification_state=unknown-unverified
## Checkpoint

| 项 | 值 |
| --- | --- |
| Issue | owner/repo#N |
| Contract | `blob-sha` |
| Agent | `grok` |
| claim_actor | `ACTOR_ID` |
| 分支 | domain/slug |
| 工作树 | `/path` |
| HEAD | `full-sha` |
| 工作区状态 | 干净 |
| 交接状态 | `review-ready` / `no-change` / `未完成 / BLOCKED` |
| HEAD 持久化 | `committed + clean HEAD` |
| 工作树分类 | `untracked=N / unstaged=N / staged=N` |
| 允许范围 | path path |
| Project | Tasks #1 Status=In progress |
| PR | 无 |
| 下一步 | … |

### R 进度

| ID | 状态 | 证据 |
| --- | --- | --- |
| R1 | pending | 尚未验证 |

状态仅限 `pending` / `addressed` / `blocked`。不要复制 R 原文。

### A 执行

| ID | 状态 | 证据 |
| --- | --- | --- |
| A1 | pending | 尚未验证 |

状态仅限 `pending` / `passed` / `failed` / `not-applicable`。
`not-applicable` 必须有 Contract 适用条件 + 非空理由和证据。

### 验证证据

```
尚未验证
```

Developer/Fixer 只有在最终实现进入明确 HEAD 且三类 dirty 数量均为 0 时才能填写 `review-ready`；无改动必须明确填写 `no-change`。`git add`、index.lock 或 `git commit` 失败时填写 `未完成 / BLOCKED`，不能用 working tree 或 `new check --tier commit` 的 PASS 代替完成态。

`fact_id` / `prev_fact_id` / provenance 是 #16 字段。缺省按 `unknown-unverified` 读；不要手写 UUID 或 actor 充当 `source_ref`。当前 tip 唯一；上一轮归档为 `<!-- new-task-checkpoint-history -->`，完整历史按 comment id 追溯。

### Historical facts

| fact_id | comment_id | kind | role | HEAD | Contract |
| --- | --- | --- | --- | --- | --- |
| PREV_FACT_ID | PREV_FACT_ID | checkpoint | dev | `full-sha` | `blob-sha` |
