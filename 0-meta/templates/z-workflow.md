# z 系列工作流

共同的触发、事实源、审查格式和安全边界。具体 Skill 只做 adapter；canonical CLI 是唯一协议实现，算法详见 07/08 与按需的 `09-agent-card.md`。

## 触发与链路

只有人实际输入 `new task claim` / `new task grok` / `new task codex` / `new task review` / `new z …`，或在人机 Skill 搜索中明确选择 `zdev` `zfix` `zreview` `zsync` `zmerge` `zpr`，才授权对应动作。普通自然语言不触发。Grok `/zdev` 与 Codex `$zdev` 只是 adapter trigger。

```text
new task claim
→ new z dev
→ new z review <review-input>
→ main 过期：人显式 new z sync → 重新 new z review
→ 不通过：new z fix → new z review
→ 通过：human-merge 时 new z pr → 人工 merge；否则 new z merge
```

`new task claim` 不启动 Agent；`new task grok|codex` 是兼容 adapter。`zdev` 先输出开工摘要，不领取、不改 Project。全流程不自动关闭 Issue，不删除工作树或本地分支。

## 事实源与评论

- 绑定 Issue 后，Contract 只读 `origin/main:0-meta/tasks/<n>/contract.json`；blob SHA 必须进入 Checkpoint / Review。
- `<!-- new-task-checkpoint -->` 只有一条；claim、zdev、zfix、zsync、交付和 merge 只更新它。
- `<!-- new-task-review -->` 只有一条；只对其中的 reviewed HEAD 有效。新 commit 或 zsync 改 HEAD 后必须重新 Review。
- Review 必须包含 `review_actor`、`claim_actor`、`Self-review=yes|no`；`Self-review=yes` 不得进入自动 squash。

## 最小审查输入

zreview 开始前按 [`verification.md`](../../.agents/skills/zreview/verification.md) 读取并执行最小充分审查，再把以下字段交给 `new z review`，不要复制完整模板算法：

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

zreview、zpr 和真正 merge 前都由共享 `z_require_current_main` 读取最新 main；若 `git merge-base --is-ancestor origin/main HEAD` 不成立，提示「main 已前进，请显式执行 `zsync`」，不隐式 rebase 或 zsync。zsync 只负责安全同步，成功后必须重新 Review。

通过 Review 才能得到唯一合法 `Squash-Title`。有 `human-merge` 标签时 `zmerge` 拒绝，由 `new z pr` 送出 PR；保持 `In review`，不由 adapter 自行合并。

## zmerge 合并前检查

共享实现负责绑定、Contract、scope、Review、PR head/base、required checks、`z_require_current_main`、互斥锁和 finalize；Skill 不复制这些算法。所有 GitHub required checks 成功后才可 squash。squash body 固定包含：`背景`、`改动`、`验证`、`备注`，并含 `Fixes #Issue号`、`PR #号`。锁 busy、Review stale、main ahead 或范围失败都必须停止并给出下一条 canonical 命令。

`zmerge` 不能删除工作树或本地分支，不能调用 `gh pr merge --delete-branch` / `--admin`、`gh issue close`，不能手写 Project `Done`。标题和正文规则以 canonical CLI 与 [`docs/08-task-contract.md`](../docs/08-task-contract.md) 为准。
