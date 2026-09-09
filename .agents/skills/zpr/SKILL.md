---
name: zpr
description: zpr — human-merge 任务的 PR 交付入口；只调用 canonical CLI。
disable-model-invocation: true
user-invocable: true
---

# zpr

## 何时用

人明确选择 `zpr`，当前 HEAD 有覆盖它的通过 Review、合法 Squash-Title，且任务带 `human-merge`。它只送 PR，保持 `In review`。

## 调用

```bash
new z pr
```

## 返回用户

返回 canonical CLI 的 PR URL/number、title、head/base、Status 与下一步；main 过期或 Review stale 时返回可执行修复命令。

## 不做

不复制 PR、main、Review 或标题算法；不合并、关闭 Issue、改 Project 为 Done、删除工作树或本地分支。
