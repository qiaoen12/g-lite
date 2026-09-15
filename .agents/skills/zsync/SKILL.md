---
name: zsync
description: zsync — 安全同步任务分支到最新 main；只调用 canonical CLI。
disable-model-invocation: true
user-invocable: true
---

# zsync

## 何时用

人明确选择 `zsync`，且需要把任务分支同步到最新 `origin/main`。它只同步，不写 Review、不合并。Guard staging stale 不等于 candidate 落后；前者由已授权的 `zmerge` scoped refresh 处理，后者才走本 Skill。

## 调用

```bash
new z sync
```

canonical CLI 负责 `git rebase origin/main`、冲突恢复和远端 `--force-with-lease` 安全门禁；Skill 不复制这些算法。

## 返回用户

返回同步前后 main/HEAD。noop 且 HEAD/Contract/provenance 未变则原 PASS 仍适用；rebase 改变 HEAD SHA 后必须新 Review。

## 不做

不隐式启动、不解决冲突、不使用裸 force、不改 Project、合并或关闭 Issue；不自动执行 `zreview` 或 `zmerge`，不删除工作树或本地分支。不得把 Guard route、network、authentication 或 non-fast-forward 故障泛化成 zsync。
