<!-- new-task-checkpoint -->
claim_actor=ACTOR_ID
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
