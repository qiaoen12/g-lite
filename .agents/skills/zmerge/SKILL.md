---
name: zmerge
description: zmerge — 通过 Review 且无 human-merge 时的 squash 入口；只调用 canonical CLI。
disable-model-invocation: true
user-invocable: true
---

# zmerge

## 何时用

仅在 `zreview` 明确进入合并，或人明确选择 `zmerge` 且 Review、Contract、HEAD、PR 和 required checks 均已通过时使用。带 `human-merge` 时停止并交给人。

## 调用

```bash
new z merge
```

## 返回用户

返回 canonical CLI 的门禁、PR、squash/finalize 事实和下一步；锁 busy、main ahead 或 Review stale 时返回可执行的 `new z merge`、`new z sync` 或 `new z review`。若仅 Guard staging main mirror stale，且已有 Review/Contract/HEAD 授权、transaction/lease 无歧义，canonical CLI 只做一次 scoped refresh、重试一次并复读全部 gates。

## 不做

不自行 `gh pr merge`，不复制锁、Review、required-check、finalize 或 merge 算法；不绕过 human-merge，不删除工作树或本地分支，不关闭 Issue。不得 replay pending/failed/unknown transaction、含 lease 歧义或 unrelated write 的 staging；candidate 落后指向 `new z sync`，HEAD 改变要求新的 Review。
