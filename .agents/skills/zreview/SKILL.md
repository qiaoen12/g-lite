---
name: zreview
description: zreview — 审查当前 HEAD 并写唯一 Review；只调用 canonical CLI。
disable-model-invocation: true
user-invocable: true
---

# zreview

## 何时用

人明确选择 `zreview`，当前任务需要审查当前 HEAD。`new z review` 无输入时只加载当前阶段事实。语义审查按 `verification.md` 执行。

## 调用

按仓库最小充分审查规则准备输入，然后运行：

```bash
new z review [--actor <id>] [--allow-self] [review-input]
```

写 Review 前 canonical runtime 会只读核验 committed + clean HEAD，并报告固定 HEAD 及 untracked/unstaged/staged 分类；任一 dirty、持久化异常或基线/提交证据缺失都 fail-closed。Reviewer 不得自动 add、commit、stash 或删除 untracked。

## 返回用户

返回当前事实、Verdict、reviewed HEAD 与下一步。`Self-review=no` 只能在 provenance 证明相对全部 dev/fix execution 独立后写入；改 actor / UUID 不能冒充独立。
