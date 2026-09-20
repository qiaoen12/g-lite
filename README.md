# g-lite

GitHub-native AI 协作协议。

GitHub 管事实和门；Agent 干活；G-lite 只规定协作。

本仓库是 canonical 协议源，不是任务 runtime、不是 workspace framework、不是 backup engine，也不是第二份 GitHub 状态机。`tools/repo-reconciler/` 是可删除的无状态治理工具，不参与任务生命周期。

```text
qiaoen12/g-lite
= canonical protocol
= Issue Contract + Actors + templates + Required Check `pr-gate`

qiaoen12/ops-control
= 真实业务 Pilot（ACTIVE）

qiaoen12/g-lite-harness
= 历史 E2E 证据（RETIRED / ARCHIVED；不再是生产依赖）

qiaoen12/g-lite-p1-lab
= 历史 PR / Issue 夹具（ARCHIVED）
```

## 核心闭环

```text
Human
  ↓
Issue Contract
  ↓
fresh independent approved
  ↓
ordinary Git branch / worktree
  ↓
Developer Agent
  ↓
PR + consumer Required Check
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
| Developer | `qiaoen12` | 读当前 Contract、验证授权 freshness、改范围内代码、开 PR | 不给自己的 PR 做 Required Review，不 merge |
| Reviewer | `g-lite-reviewer[bot]` | 重新读当前 Contract、验证 freshness、HEAD/diff、Checks，然后 `APPROVE` 或 `REQUEST_CHANGES` | 不修改项目文件、不 `git push`、不 merge、不修改 Ruleset 或 workflow |

Developer Actor ≠ Reviewer Actor。

写或实质修改当前 Contract 的 Actor，不得批准同一份 Contract version。

聊天里的「开始做」不是授权。授权只看 GitHub 当前事实。

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

- Issue `approved`：当前这份 Contract 可以开始做。
- PR Review `APPROVE`：当前这一个 PR HEAD 的代码可以合并。

GitHub `Dismiss stale reviews` 只处理 PR Review，不会因为 Issue 正文被编辑就自动摘掉 `approved`。

因此 Developer 开工前与 Reviewer 正式 Review 前都必须按当前 GitHub 事实实时计算 Contract authorization freshness：

```text
approved 不存在
→ INVALID

lastEditedAt == null
→ FRESH

lastEditedAt <= approvedAt
→ FRESH

lastEditedAt > approvedAt
→ STALE AUTHORIZATION
```

并且：

```text
写或实质修改当前 Contract version 的 Actor
≠
approved Actor
```

INVALID / STALE / Actor 不独立时都不得继续该角色的下一步动作。人必须重新确认当前 Contract，再由独立 Actor 重新 `approved`。

不要把 freshness 写成仓库状态文件、hash DB、approval cache 或其他第二份状态。

## 开发

不需要安装 G-lite CLI。用普通 `git` / `gh` 或现成 Agent 工作台。

1. 读取当前 GitHub Issue 正文，不要用聊天摘要代替。
2. 确认 Issue 为 OPEN。
3. 读取当前 `approved` 及最新 label event、Contract 最近 body edit；确认 authorization FRESH 且批准 Actor 独立。
4. Developer 从最新 `origin/main` 创建普通 branch / worktree。
5. 只改 Contract 允许的范围。
6. push 并开 PR；PR 用 `Fixes #N` 关联 Issue。
7. 等待 consumer repo 自己的 Required Check。失败则修本 PR 引入的问题，不绕过门。
8. 独立 Reviewer 重新读取 Contract、fresh approval、当前 HEAD/diff、Checks。
9. GitHub squash merge。

Codex / Cursor / Claude Code / Grok 等只是可替换工作台。

## G-lite-compatible adoption contract

新仓库采用 G-lite，不靠安装 runtime，而靠最小 protocol baseline + GitHub 平台设置。

可以从本仓 GitHub Template 创建，也可以由 Agent 将最小协议结构补到已有仓库。是否兼容，以仓库实际 durable facts / gates 为准，而不是以“是否从模板创建”为准。

一个 consumer repo 同时满足下面条件，才称为 G-lite-compatible：

1. Issue Contract 至少包含 Goal / Acceptance / Out of scope / Authorization。
2. GitHub Issue 上存在独立、当前有效的 `approved` 授权事实。
3. Developer Actor 与 `g-lite-reviewer[bot]` 分离，且 Reviewer App prerequisite 可被验证或明确报告 `UNVERIFIED`。
4. main 要求通过 PR 合入。
5. Required approvals >= 1。
6. stale review dismissal 开启。
7. Required Check 存在，并检查该 consumer 自己真实需要的测试/构建/安全条件。
8. merge method 收敛为 squash。
9. 常规开发路径没有 bypass。
10. GitHub 平台支持时开启 Secret scanning / Push protection。
11. 不依赖 G-lite 自有 CLI、Router、Controller、Worker 或第二份 GitHub 状态；Reviewer App 只是 GitHub 上的独立协议 Actor。

canonical G-lite 的 Required Check 名为 `pr-gate`；consumer repo 可以使用自己的稳定 check 名，不需要复制 G-lite 的具体 CI 实现。

v2.6 的 `tools/repo-reconciler/` 提供无状态 `audit`、`plan`、`bootstrap`、`activate`、`apply`、`upgrade`；它只处理稳定、机械、重复的 GitHub 治理事实，bootstrap 只建立最小协议基线，不生成 consumer CI、不接管 consumer 业务文件。

执行顺序是：

```text
bootstrap → ci-catalog / Agent → real CI SUCCESS → activate --required-check NAME → audit
```

`NAME` 必须由 Agent 从 GitHub 真实 Check context 提供，不能从 workflow 文件名推断。consumer README、业务文件和 CI 始终由 consumer 与 Agent 自己拥有。

## GitHub 门

canonical `qiaoen12/g-lite/main` 由 GitHub Ruleset 保护：

- Require pull request
- Required approvals = 1
- Dismiss stale reviews = ON
- last-push approval = OFF
- Allowed merge = squash only
- Required Check = `pr-gate`（GitHub Actions；job 名不可改）
- force push / branch deletion blocked
- bypass actors = none

安全边界交给 GitHub Secret scanning / Push protection，以及每个 consumer repo 自己的 stack-specific CI。

## 明确不负责

canonical G-lite 不提供、不维护：

- 自有 CLI（已删除的 `new` / `z*`，以及任何 replacement CLI）
- workspace 八域 / scaffolding
- backup / restic / restore drill
- 本地 task / review / merge / approval 状态
- Router / Controller / Worker / Reviewer App runtime（Reviewer App 是外部 GitHub Actor）
- stack-specific CI framework（研究见 [#34](https://github.com/qiaoen12/g-lite/issues/34)）
- 编辑器 adapter 与本地 pre-commit 引擎
- `.gitignore` / 仓库 hygiene（consumer repo 自己负责）
- `.g-lite-version` 或任何 version state file（身份由 GitHub repo + tag/release 表达）

这些能力若有价值，放在 consumer repo、独立工具或 GitHub 平台。

## 版本与冻结

`v1.0.0` 发布时的产品形态是 framework/runtime，并声明了至少 15 天 Freeze。

随后人类通过 [#27](https://github.com/qiaoen12/g-lite/issues/27) 明确改变产品方向，提前进入 GitHub-native contraction。这个决策应被理解为对旧 runtime Freeze 的显式 supersede / override，而不是假装旧 Freeze 按原计划完整执行。

R6 将 runtime/framework → protocol 作为 breaking architecture change，目标版本为 `v2.0.0`。

`v2.0.0` 发布后重新开始至少 15 天 Freeze：

- P0 / security blocker 可以立即修复；
- 非 P0 friction / ergonomics 只记录，不立即扩 canonical core；
- Router / Controller / Reviewer App / Worker / CLI / stack-specific CI framework 不得借普通修复重新进入 core。

tag / Release 是 GitHub 上的人类发布动作，不由 G-lite runtime 自动生成。

## Provenance

最初从 `qiaoen12/Project-qiaoen` @ `988ba573c8bc8b841539223e547e82f70719f52c`（Freeze UTC `2026-09-09T10:55:57Z`）按 allowlist 抽出。

R0–R5 把 runtime 收缩为 GitHub-native 协议；R5.5 再删掉 workspace / scaffolding / backup / 本地治理；R6 只负责授权语义、adoption contract、最终 Pilot 与版本收口。

历史实现留在 Git history / tag / archived repositories，不留在当前产品树。
