# g-lite

GitHub-native AI 协作协议。

GitHub 管事实和门；Agent 干活；G-lite 只规定协作。

本仓库是 canonical 协议源，不是 CLI、不是 workspace framework、不是 backup engine，也不是第二份 GitHub 状态机。

```text
qiaoen12/g-lite
= canonical protocol
= Issue Contract + Actors + templates + Required Check `pr-gate`

qiaoen12/ops-control
= R5 业务 Pilot（ACTIVE）

qiaoen12/g-lite-harness
= 历史 E2E 证据（RETIRED；不再是生产依赖）

qiaoen12/g-lite-p1-lab
= 历史 PR / Issue 夹具（ARCHIVE）
```

## 核心闭环

```text
Human
  ↓
Issue Contract
  ↓
independent approved
  ↓
ordinary Git branch / worktree
  ↓
Developer Agent
  ↓
PR + Required Check `pr-gate`
  ↓
independent Reviewer
  ↓
GitHub APPROVE / REQUEST_CHANGES
  ↓
squash merge
```

删掉本仓库里任何一个非协议模块之后，这条闭环必须仍然完整。

## Actor

| 角色 | GitHub Actor | 做什么 | 不做什么 |
| --- | --- | --- | --- |
| Developer | `qiaoen12` | 读 Contract、改范围内的代码、开 PR | 不给自己的 PR 做 Required Review，不 merge |
| Reviewer | `qiaoen-reviewer` | 读 Contract、授权 freshness、HEAD/diff、Checks，然后 `APPROVE` 或 `REQUEST_CHANGES` | 不 `git push`，不改 git config |

Developer Actor ≠ Reviewer Actor。

写或实质修改当前 Contract 的 Actor，不得批准同一份 Contract version。

聊天里的「开始做」不是授权。授权只看 GitHub Issue 上的 `approved`。

## Issue Contract

人在 GitHub Issue 正文写契约。模板最小结构：

```text
Contract
├ Goal
├ Acceptance
├ Out of scope
└ Authorization
```

两种批准必须分开：

- Issue `approved`：这件事、按这个范围，可以开始做。
- PR Review `APPROVE`：当前这一个 PR HEAD 的代码，可以合并。

GitHub `Dismiss stale reviews` 只处理 PR Review，不会因为 Issue 正文被编辑就自动摘掉 `approved`。Reviewer 必须在正式 Review 前按 [`AGENTS.md`](AGENTS.md) 计算 Contract 授权 freshness。不要把 freshness 写成仓库里的状态文件。

## 开发

不需要安装 G-lite CLI。用普通 `git` / `gh`。

1. 读当前 GitHub Issue 正文，不要用聊天摘要代替。
2. 确认 Issue 为 OPEN，且 `approved` 真实存在。
3. Developer 从最新 `origin/main` 创建普通 branch / worktree。
4. 只改 Contract 允许的范围。
5. push 并开 PR；PR 用 `Fixes #N` 关联 Issue。
6. 等待 Required Check `pr-gate`。失败则修本 PR 引入的问题；不改名、不删除、不绕过该 check。
7. 独立 Reviewer 按 `AGENTS.md` 做 freshness 检查和 GitHub Review。
8. GitHub squash merge。

Codex / Cursor / Claude Code / Grok 只是可替换工作台。

## GitHub 门

`main` 由 GitHub Ruleset 保护：

- Require pull request
- Required approvals = 1
- Dismiss stale reviews = ON
- last-push approval = OFF
- Allowed merge = squash only
- Required Check = `pr-gate`（GitHub Actions；job 名不可改）
- force push / branch deletion blocked
- bypass actors = none

安全边界交给 GitHub Secret scanning / Push protection，以及每个 consumer repo 自己的 stack CI。

## 明确不负责

canonical G-lite 不提供、不维护：

- 自有 CLI（已删除的 `new` / `z*`，以及任何 replacement CLI）
- workspace 八域 / scaffolding
- backup / restic / restore drill
- 本地 task / review / merge / approval 状态
- Router / Controller / Worker / Reviewer App
- stack-specific CI framework（研究见 [#34](https://github.com/qiaoen12/g-lite/issues/34)）
- 编辑器 adapter 与本地 pre-commit 引擎

这些能力若有价值，放在 consumer repo、独立工具或 GitHub 平台。

## Provenance

最初从 `qiaoen12/Project-qiaoen` @ `988ba573c8bc8b841539223e547e82f70719f52c`（Freeze UTC `2026-09-09T10:55:57Z`）按 allowlist 抽出。R0–R5 把 runtime 收缩为 GitHub-native 协议；R5.5 再删掉 workspace / scaffolding / backup / 本地治理。历史实现留在 Git history / tag，不留在当前产品树。

本仓库不自己 tag / release。R6 才做版本收口。
