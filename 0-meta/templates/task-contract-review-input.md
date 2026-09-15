# canonical `new z review` 输入

只提交以下逐行结构化内容；工具会补齐 Issue、Contract、当前 HEAD、真实 diff、actor 与 Markdown Review。空行和以 `#` 开头的注释行允许，其他行非法时按输入行号拒绝。

```text
verdict: 通过
title: feat(meta): 一个已校验的标题
notes: 本轮审查结论与主要证据
R1: 满足 | 已检查实现与调用点
A1: 通过 | 定向测试通过
```

每个 Contract R/A 必须恰好出现一次。R 只能是 `满足` / `不满足`；A 只能是 `通过` / `不通过` / `不适用`。`|` 右侧是证据，不能为空，也不能只有状态词。A 中登记的 `validator:<id>` 由仓库白名单实现执行，结果覆盖人工 A 状态；失败会把 A 置为不通过并阻止 Verdict=通过。

`review_actor` 仍按 `--actor` → `NEW_TASK_ACTOR` → 当前 worktree 的 `git config user.email` 解析，但这只是领取/展示身份，不是独立性证明。`review_actor != claim_actor`、改 `--actor`、新 UUID、PID、机器名、模型名或终端名都不能单独制造独立 Reviewer。

只有宿主或受控 launcher/hook 捕获的 execution/session `source_ref` 为 `verified`，且 reviewer lineage 不属于形成当前 candidate 的任何 dev/fix execution 或其 continuation/fork，才能写 `Self-review=no`。无法证明时写 `Self-review=unknown`，不得自动宣称独立 PASS。`--allow-self` 只用于同一 actor 的显式人工 self-review，且 Issue 必须已有 `human-merge`，结果写 `Self-review=yes`；它不是 unknown provenance 的 fallback。
