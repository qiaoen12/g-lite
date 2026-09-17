---
name: zfix
description: zfix — Review 未通过后的修复入口；只调用 canonical CLI。
disable-model-invocation: true
user-invocable: true
---

# zfix

## 何时用

人明确选择 `zfix`，且当前适用 Review 为不通过。它只修当前 findings；新 candidate HEAD 之后下一步是 `new z review`。

## 调用

```bash
new z fix
```

## 返回用户

返回共享 stage facts：当前 tip、当前 finding、历史引用和下一步；失败不修改工作树。不灌入全部历史正文。

## 完成态

修复交接与开发交接使用同一 completion gate：最终修复必须是 committed + clean HEAD（untracked=0、unstaged=0、staged=0）。`git add`、index.lock 或 `git commit` 失败即「未完成 / BLOCKED」，不能用 working tree 或 commit-tier PASS 代替完成；无改动须明确报告 `no-change` 且 clean。

## 不做

不复制 claim、scope、Review 或 commit 算法；不 push、建 PR、改 Review/Project、合并、关闭 Issue、删除工作树或本地分支。
