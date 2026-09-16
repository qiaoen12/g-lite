# z 系列工作流

触发、事实源、审查格式与安全边界。Skill 只做 adapter；canonical CLI 是唯一协议实现，算法见 07/08 与按需 `09-agent-card.md`。

## 触发与链路

只有人实际输入 `new task claim` / `new task grok` / `new task codex` / `new task review` / `new z …`，或在人机 Skill 搜索中明确选择 `zdev` `zfix` `zreview` `zsync` `zmerge` `zpr`，才授权对应动作。普通自然语言不触发。Grok `/zdev` 与 Codex `$zdev` 只是 adapter。

```text
new task claim
→ new z dev
→ completion 未成立：continue development
→ 无适用 Review：new z review <review-input>
→ FAIL / REQUEST_CHANGES：new z fix
→ fix 新 candidate：new z review <review-input>
→ main 过期：人显式 new z sync
→ 适用独立 PASS：human-merge 时 new z pr → 人工 merge；否则 new z merge
```

`new task claim` 不启动 Agent；`new task grok|codex` 是兼容 adapter。`zdev` 先输出开工摘要。`dev`/`fix`/`review` 共用 fact loader，不领取、不改 Project。不关闭 Issue，不删工作树或本地分支。

## 事实源与评论

- Contract 只读 `origin/main:0-meta/tasks/<n>/contract.json`；blob SHA 必须进入 Checkpoint / Review。
- 有界 loader：Contract、binding、HEAD、有界 diff、当前 Checkpoint/Review tip、findings、PR、provenance、next command。完整历史按 comment id 追溯。
- 当前 tip 由 `<!-- new-task-checkpoint -->` / `<!-- new-task-review -->` 唯一标识。新写入归档上一轮为 `*-history`，tip 留 `prev_fact_id`。重复 tip、分叉、损坏引用 fail-closed，不按 `created_at` 猜最新。
- 适用 PASS 绑定精确 HEAD SHA + 当前 origin/main Contract blob + 合法 provenance/独立性 + current fact 无冲突。`zsync=noop` 且条件未变则保留 PASS；rebase/HEAD SHA 变化或 Contract-only change 使 Review stale。ancestry 只诊断，不继承 PASS。
- `review_actor != claim_actor` 不能证明独立。actor 不是 execution identity。独立性相对全部 candidate dev/fix execution 及其 lineage，不含 claim-only / review / delivery-only；recognized legacy dev/fix 缺 provenance 仍 fail-closed。verified `source_ref` 且无交集才写 `Self-review=no`。无法证明写 `unknown`/`unknown-unverified`，fail-closed。`Self-review=yes` 不得自动 squash。

## 最小审查输入

zreview 开始前按 [`verification.md`](../../.agents/skills/zreview/verification.md) 读取并执行最小充分审查，再把以下字段交给 `new z review`：

```markdown
<!-- task-contract:v1 -->
### 最小充分审查
- 审查代码与调用点：
- 复用证据：
- 新增验证：
- 覆盖范围：
- 未执行的大范围验证：
- 剩余风险：
### Contract 对照
| Contract | R/A 状态与证据 |
```

## 最新 main 与交付

zreview、zpr 和真正 merge 前都由共享 `z_require_current_main` 读取最新 main；若 `git merge-base --is-ancestor origin/main HEAD` 不成立，提示「main 已前进，请显式执行 `zsync`」，不隐式 rebase 或 zsync。zsync 只做安全同步；PASS 仍按上一节判定。

适用独立 Review 才能得到唯一合法 `Squash-Title`。有 `human-merge` 标签时 `zmerge` 拒绝，由 `new z pr` 送出 PR；保持 `In review`，不由 adapter 自行合并。

## zmerge 合并前检查

共享实现负责绑定、Contract、scope、Review、PR head/base、required checks、`z_require_current_main`、互斥锁和 finalize。所有 GitHub required checks 成功后才可 squash。squash body 固定包含：`背景`、`改动`、`验证`、`备注`，并含 `Fixes #Issue号`、`PR #号`。锁 busy、Review stale、main ahead 或范围失败都必须停止并给出下一条 canonical 命令。

`zmerge` 不能删工作树或本地分支，不能调用 `gh pr merge --delete-branch` / `--admin`、`gh issue close`，不能手写 Project `Done`。标题正文以 canonical CLI 与 [`docs/08-task-contract.md`](../docs/08-task-contract.md) 为准。
