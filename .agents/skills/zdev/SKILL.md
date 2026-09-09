---
name: zdev
description: zdev — 已领取任务的开发入口；只调用 canonical CLI。
disable-model-invocation: true
user-invocable: true
---

# zdev

## 何时用

人明确选择 `zdev`，或 `new task grok` / `new task codex` 完成统一 claim 后把它作为固定首条指令。`zdev` 不领取任务、不改 Project 状态；`new task approve` 只由人在稳定 main 上执行。

## 调用

```bash
new z dev
```

canonical CLI 读取 binding + origin/main Contract，执行状态与范围门禁，并输出开工摘要/start card。

## 返回用户

原样返回 canonical CLI 的 Issue、Contract、branch、derived state、scope、HEAD、下一步和验证结果；失败也返回 reason code 与下一条命令。

## 不做

不读取或复制 claim、scope、Review、validator、merge 算法；不 push、建 PR、改 Project、合并、关闭 Issue、删除工作树或本地分支。
