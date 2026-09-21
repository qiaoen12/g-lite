# g-lite

GitHub-native AI 协作协议。

GitHub 管事实和门；Agent 干活；G-lite 只规定协作。

本仓库是 canonical 协议源，不是任务 runtime、不是 workspace framework、不是 backup engine，也不是第二份 GitHub 状态机。`tools/repo-reconciler/` 是可删除的无状态治理工具，不参与任务生命周期。

```text
qiaoen12/g-lite
= canonical protocol
= Issue Contract + Actors + templates + Required Check `pr-gate`

qiaoen12/g-ops-control
= 真实业务 Pilot（ACTIVE）

qiaoen12/g-lite-harness
= 历史 E2E 证据（RETIRED / ARCHIVED；不再是生产依赖）

qiaoen12/g-lite-p1-lab
= 历史 PR / Issue 夹具（ARCHIVED）
```

## 核心闭环

```text
Human Authority
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
Human Authority: Squash merge
```

删掉本仓库里任何一个非协议模块之后，这条闭环必须仍然完整。

## Actor

| 角色 | GitHub Actor | 做什么 | 不做什么 |
| --- | --- | --- | --- |
| Developer | 机器身份；当前 canonical `g-lite-developer[bot]` / App ID `5017695` | 创建/修改 Contract、验证 freshness、开发、push、开/更新 PR | 不批准自己写/改的 Contract，不给自己的 PR 做 Required Review，不 merge，不自行修改约束自身的 Ruleset / governance |
| Reviewer | 独立机器身份；当前 canonical `g-lite-reviewer[bot]` / App ID `5010632` | 独立添加 `approved`，重新核对 Contract、freshness、HEAD/diff、Checks，`APPROVE / REQUEST_CHANGES` | 不开发、不 push、不修改 repository governance、不 merge |
| Human Authority | 一个或多个对目标仓库具有适当 GitHub 权限的人类账号 | 控制 Genesis / governance；门禁满足后最终 Squash merge | 不绕过 GitHub 门禁 |

角色限制绑定到当前治理角色，不绑定到某个固定人类账号、工作台或所有工具入口。以上 App 名称/ID 只是 current canonical binding；consumer 可替换具体账号/App，必须保持机器身份及角色独立性。

Human Authority 可通过 GitHub UI、CLI、API 或受其明确指令控制的工具机械执行最终 Squash merge。Developer 不 merge；Reviewer 不 merge。不新增 Merge Bot / Merge Executor。

Developer Actor ≠ Reviewer Actor。

写或实质修改当前 Contract 的 Actor，不得批准同一份 Contract version。

聊天里的「开始做」不是授权。授权只看 GitHub 当前事实。

## Issue Contract

Human Authority 或 Developer 在 GitHub Issue 正文写契约。模板最小结构：

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

## Genesis / ACTIVE

Genesis 由 Human Authority 控制：创建仓库、安装/授权 Developer App 与 Reviewer App、建立初始协议基线及 CI、配置 Ruleset / governance / security，并验证进入 ACTIVE 的条件。Agent/工具可以执行 Genesis，但执行身份与授权必须属于 Human Authority，不因此将 Developer 提升为管理员。

ACTIVE 日常任务由 Developer + Reviewer 推进；Human Authority 只在治理边界或最终 merge 再介入。Developer / Reviewer 不得自行修改约束自身的 Ruleset / governance；治理变更由 Human Authority 控制。

## Local Bootstrap 与认证

**Local Bootstrap ≠ Repository Task**。安装/轮换 GitHub App private key、建立本地 `~/.config/g-lite/` 凭据目录、本地 token helper / shell identity bootstrap、只读 identity preflight、新机器本地身份配置，无需 GitHub Issue Contract。这不授权改变任何 repository durable facts；改变仓库状态必须进入对应 repository lifecycle。

Developer / Reviewer 使用 short-lived Installation Access Token。private key 仅由外部本机安全凭据机制管理；private key、JWT、Installation Access Token、PAT 不得写入 repo、Issue、PR、日志证据或 canonical state，token 不得持久化到状态文件。canonical 不提供凭据管理 runtime。

GitHub API Actor、commit 作者和 Git transport identity 必须分别核验。Installation Token 若不能调用 REST `/user`，可用同一 token 的 GraphQL `viewer.login` 核验 Actor，不回退人类凭据。Developer clone / fetch / push 使用 App HTTPS credential：用户级/global Git `insteadOf` 可能将 HTTPS 静默改写为 SSH。每次 transport 前确认有效 remote 是 HTTPS、无影响它的 rewrite；优先任务进程级隔离（例如 `GIT_CONFIG_GLOBAL=/dev/null`、`GIT_CONFIG_NOSYSTEM=1`、`GIT_ALLOW_PROTOCOL=https`，同时检查 repo-local 配置与 credential helper）。不要要求删除用户全局 Git / SSH 配置。

GitHub 是 Issue authorization、PR、Checks、Review、Ruleset、merge eligibility、merge result 的 SSOT；不建立 identity registry、approval DB 或第二份 GitHub 状态。

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
9. Human Authority 在 GitHub 当前门禁满足后执行最终 Squash merge。

Codex / Cursor / Claude Code / Grok 等只是可替换工作台。

## G-lite-compatible adoption contract

新仓库采用 G-lite，不靠安装 runtime，而靠最小 protocol baseline + GitHub 平台设置。

可以从本仓 GitHub Template 创建，也可以由 Agent 将最小协议结构补到已有仓库。是否兼容，以仓库实际 durable facts / gates 为准，而不是以“是否从模板创建”为准。

一个 consumer repo 同时满足下面条件，才称为 G-lite-compatible：

1. Issue Contract 至少包含 Goal / Acceptance / Out of scope / Authorization。
2. GitHub Issue 上存在独立、当前有效的 `approved` 授权事实。
3. Developer 与 Reviewer 为独立机器 Actor，且两个 App prerequisite 可被验证或明确报告 `UNVERIFIED`。
4. main 要求通过 PR 合入。
5. Required approvals >= 1。
6. stale review dismissal 开启。
7. Required Check 存在，并检查该 consumer 自己真实需要的测试/构建/安全条件。
8. merge method 收敛为 squash。
9. 常规开发路径没有 bypass。
10. GitHub 平台支持时开启 Secret scanning / Push protection。
11. 不依赖 G-lite 自有 CLI、Router、Controller、Worker 或第二份 GitHub 状态；Developer / Reviewer App 只是 GitHub 上的协议 Actor。

canonical G-lite 的 Required Check 名为 `pr-gate`；consumer repo 可以使用自己的稳定 check 名，不需要复制 G-lite 的具体 CI 实现。

`tools/repo-reconciler/` 提供无状态 `audit`、`plan`、`bootstrap`、`activate`、`apply`、`upgrade`；它只处理稳定、机械、重复的 GitHub 治理事实，bootstrap 只建立最小协议基线，不生成 consumer CI、不接管 consumer 业务文件。

文件审计仅检查 `required protocol markers present`，属于 deterministic mechanical baseline，不证明 semantic correctness。manifest 使用 `protocol.markers` 描述这些字面 marker；成熟仓的实际语义判断和上下文相关补丁仍由 Agent 负责，不增加 LLM、parser 或 semantic engine。

Bootstrap 坚持 same target or fail，不会在写入失败后删除 `branch` 重试。只有实时确认 GitHub `repository.isEmpty = true`，并确认目标 branch 等于当前默认分支，才允许省略 `branch` 创建首个 commit；每个缺失文件写入前重新判断，不缓存空仓状态。非空仓、非默认目标或无法证明为空时都保留显式目标，失败保留原写入错误分类。

Ruleset 审计检查 include 与 exclude：明确目标 ref、`~ALL`、`~DEFAULT_BRANCH` 按目标及实际默认分支判断；不能可靠排除影响的其他 exclude pattern 保守判为不满足目标。工具不实现通用 GitHub pattern engine，G-lite 生成的目标始终为明确 branch ref 且 exclude 为空。

执行顺序是：

```text
bootstrap → ci-catalog / Agent → real CI SUCCESS → activate --required-check NAME → audit
```

`NAME` 必须由 Agent 从 GitHub 真实 Check context 提供，不能从 workflow 文件名推断；`activate` 不检查 default-branch HEAD，也不推断 CI 拓扑。consumer README、业务文件和 CI 始终由 consumer 与 Agent 自己拥有。

`--developer-app-verified` 与 `--reviewer-app-verified` 是外部 identity / installation preflight：Agent 仅可在外部对目标 consumer 的实际角色绑定完成真实核验（App ID、Actor、installation 可访问目标仓库，以及 Developer ≠ Reviewer）后分别传入。canonical 当前绑定见 Actor 表；consumer 可替换绑定，无需使用 canonical 账号。

`bootstrap`、`activate`、`apply` 的远端治理写入还必须带 invocation-only 的 `--human-authority-verified`。它表示调用者已在外部确认本次写入由 Human Authority 明确授权，并使用适当身份。三个断言都只对当前 invocation 有效；统一 write preflight 在任何 `bootstrap_file`、`ensure_label`、`ensure_ruleset` 或其他远端治理写入前执行，任一缺失即 `UNVERIFIED` / exit 3，并在写入前停止。`audit`、`plan`、`upgrade`、`self-test` 为只读路径，不要求 Human Authority assertion。

三项断言均不持久化；工具不读取 private key、不生成 JWT/token、不保存 credential、不建立 allowlist 或 identity registry，也不形成第二份 GitHub 状态。断言不会把 Developer / Reviewer 提升为治理写入者；Genesis / governance 写入仍由 Human Authority 控制。

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

Current governance baseline = v3.1

[#43](https://github.com/qiaoen12/g-lite/issues/43) 是 Human Authority 明确授权的架构修正，显式 supersede v2.6 Freeze 对普通非 P0 变更的暂停。

v3.1 evidence（Issue #43 记录的真实 E2E）：

- Fixture: [g-lite-developer-e2e](https://github.com/qiaoen12/g-lite-developer-e2e)，[Contract #3](https://github.com/qiaoen12/g-lite-developer-e2e/issues/3)，[PR #4](https://github.com/qiaoen12/g-lite-developer-e2e/pull/4)。
- Developer App HTTPS push；Reviewer 独立 Contract approval 与 HEAD `7fa2d99e23bf7d8b090cf7b0a69beb703196c6fa` 的 APPROVE。
- 该 fixture 的 Human Authority merge Actor 为 `qiaoen12`（部署 evidence，不是通用角色绑定），Squash SHA `16308fd3aad2ec8e57109bf02d455e339042d770`；Issue #3 CLOSED / COMPLETED；Developer / Reviewer 均未 merge。
- [Issue #1](https://github.com/qiaoen12/g-lite-developer-e2e/issues/1) / [PR #2](https://github.com/qiaoen12/g-lite-developer-e2e/pull/2) 因 global Git rewrite 将 HTTPS 转为人类 SSH identity 而 BLOCKED 并关闭；第二轮进程级隔离后 PASS。

v3.1 Freeze 从 Issue #43 对应 PR 的 squash merge commit 开始；merge 前以 [Issue #43](https://github.com/qiaoen12/g-lite/issues/43) 及其关联 PR 为 durable referent，不预写未知 merge SHA。

`v1.0.0` 发布时的产品形态是 framework/runtime，并声明了至少 15 天 Freeze。

随后人类通过 [#27](https://github.com/qiaoen12/g-lite/issues/27) 明确改变产品方向，提前进入 GitHub-native contraction。这个决策应被理解为对旧 runtime Freeze 的显式 supersede / override，而不是假装旧 Freeze 按原计划完整执行。

R6 将 runtime/framework → protocol 作为 breaking architecture change，最初目标版本为 `v2.0.0`；该版本说明现在仅作为历史架构基线保留。

当前 Freeze baseline 以上方 v3.1 为准。

v3.1 Freeze 生效后：

- P0 / security blocker 可以立即修复；
- 非 P0 friction / ergonomics 只记录，不立即扩 canonical core；
- Router / Controller / Reviewer App / Worker / CLI / stack-specific CI framework 不得借普通修复重新进入 core。

tag / Release 是 GitHub 上的人类发布动作，不由 G-lite runtime 自动生成。

## Provenance

最初从 `qiaoen12/Project-qiaoen` @ `988ba573c8bc8b841539223e547e82f70719f52c`（Freeze UTC `2026-09-09T10:55:57Z`）按 allowlist 抽出。

R0–R5 把 runtime 收缩为 GitHub-native 协议；R5.5 再删掉 workspace / scaffolding / backup / 本地治理；R6 只负责授权语义、adoption contract、最终 Pilot 与版本收口。

历史实现留在 Git history / tag / archived repositories，不留在当前产品树。
