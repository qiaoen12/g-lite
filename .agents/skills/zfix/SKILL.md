---
name: zfix
description: zfix — Review 未通过后的修复入口；只调用 canonical CLI。
disable-model-invocation: true
user-invocable: true
---

# zfix

## 何时用

人明确选择 `zfix`，且当前任务有未通过的唯一 Review。它只修 Review 指出的阻断项；新提交后由人重新选择 `zreview`。

## 调用

```bash
new z fix
```

## 返回用户

返回 canonical CLI 的门禁结果、当前 Issue/Contract/HEAD、可执行下一步和验证证据；失败不修改工作树。

## 完成态

修复交接与开发交接使用同一 completion gate：最终修复必须是 committed + clean HEAD（untracked=0、unstaged=0、staged=0）。`git add`、index.lock 或 `git commit` 失败即「未完成 / BLOCKED」，不能用 working tree 或 commit-tier PASS 代替完成；无改动须明确报告 `no-change` 且 clean。

## 不做

不复制 claim、scope、Review 或 commit 算法；不 push、建 PR、改 Review/Project、合并、关闭 Issue、删除工作树或本地分支。
