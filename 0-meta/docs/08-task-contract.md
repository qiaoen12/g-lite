# Task Contract（GitHub-native）

人在 GitHub Issue 正文里写契约。`approved` 标签是授权。GitHub 是 PR、Checks、Review、merge eligibility 与 merge result 的 SSOT。

```
Issue 正文（Contract）+ approved
        → 普通 branch / worktree
        → PR
        → pr-gate
        → 独立 Reviewer GitHub APPROVE / REQUEST_CHANGES
        → GitHub squash merge
```

不要再把 Contract 写成 `0-meta/tasks/<n>/contract.json`。不要本地 claim、checkpoint、review applicability 或 merge 状态机。已删除的 `new task` / `new z` 不是当前执行路径。

## 授权

- Developer Actor ≠ Reviewer Actor。当前分别是 `qiaoen12` 与 `qiaoen-reviewer`。
- 写或实质修改 Contract 的 Actor 不能给同一份 Contract 加 `approved`。
- Contract 实质修改后，旧 `approved` 失效。必须由未写该版本的独立 Actor 重新授权。
- 聊天里的「开始干活」不替代 GitHub 上的 `approved`。

## 默认工作流

1. 读取当前 GitHub Issue Contract，不要用聊天摘要代替当前正文。
2. 确认 Issue 为 OPEN，且 `approved` 真实存在。
3. Developer 从最新 `origin/main` 创建普通 Git branch / worktree。
4. 只改 Contract 允许的范围。
5. push 并开 PR；PR body 用 `Fixes #N` 关联 Issue。
6. 等待 Required Check `pr-gate`。失败则修本 PR 引入的问题，不改名、不删除、不绕过该 check。
7. 独立 Reviewer 读取：当前 Contract、`approved`、当前 HEAD、当前 diff、Checks。
8. 在 GitHub 上 `APPROVE` 或 `REQUEST_CHANGES`。
9. GitHub squash merge。Developer 不 merge、不给自己的 PR 做 Required Review。

## 范围

允许改动范围写在 Issue Contract 里。Agent 不得自行扩大 scope，也不得把公共可见目录（例如 `0-meta/`）当成默认可写。

GitHub Ruleset 负责 main 保护：Required Check `pr-gate`、Required Review、squash-only。G-lite 不再保存第二份 merge eligibility。

## 历史

Issue 进 `origin/main` 的 `contract.json`、本地 claim lock、Checkpoint 评论、canonical `new z review` / `zmerge` 属于 R4 之前的 runtime。决策与 freeze 材料可以保留历史背景，但不得再指导当前执行。
