---
name: zreview
description: zreview — 审查当前 HEAD 并写唯一 Review；只调用 canonical CLI。
disable-model-invocation: true
user-invocable: true
---

# zreview

## 何时用

人明确选择 `zreview`，当前任务需要审查当前 HEAD。语义审查按仓库共同的 `verification.md` 执行。

## 调用

按仓库最小充分审查规则准备输入，然后运行：

```bash
new z review [--actor <id>] [--allow-self] <review-input>
```

## 返回用户

原样返回 canonical CLI 写入的 Verdict、reviewed HEAD、Contract 对照、Squash-Title、验证证据与下一步。
