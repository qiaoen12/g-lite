# G-lite agent-card

## 开工

- 只读根目录 `README.md` 与本文件；不要泛读历史 Git 或已删除目录。
- 任务身份、Contract 与允许范围只信当前 GitHub Issue 正文。
- 仓库身份从当前 Git origin 推导，不依赖固定本机路径。
- GitHub 是 Issue authorization、PR、Checks、Review、Ruleset、merge eligibility 与 merge result 的 SSOT。
- Developer 开工前必须确认 Issue OPEN，并实时验证当前 `approved` 对当前 Contract version 仍然 FRESH。
- 如果无法可靠读取 freshness 所需 GitHub 事实，STOP；不要把“标签还在”当成授权有效。

## Developer authorization freshness

开工前读取：

- Issue author
- Issue `lastEditedAt`
- Issue editor / edit history（需要时）
- latest `approved` label event
- approved Actor
- approved timestamp（`approvedAt`）

判断：

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

还必须满足：

```text
写或实质修改当前 Contract version 的 Actor
≠
approved Actor
```

INVALID / STALE / Actor 不独立时：

- 不得开始或继续基于当前授权的新开发动作；
- 让人重新确认当前 Contract；
- 由未写/改当前版本的独立 Actor 重新添加 `approved`；
- 不创建本地 authorization cache、Contract hash state 或其他第二份状态。

## 硬边界

- 不写明文凭据；不把密钥、PAT、host inventory 写入仓库、日志或 Issue。
- 不安装、不恢复、不重建 G-lite CLI；治理收敛只允许调用 `tools/repo-reconciler/` 的一次性无状态工具。
- 不创建 `task_state`、`review_state`、`merge_state`、`ready_to_merge`、approval cache、Contract hash runtime。
- Developer Actor ≠ Reviewer Actor。当前 canonical Developer = `g-lite-developer[bot]` / App ID `5017695`，Reviewer = `g-lite-reviewer[bot]` / App ID `5010632`；均为机器身份。consumer 可替换具体 App / 账号绑定，保持角色独立。
- 写或实质修改 Contract 的 Actor 不得批准同一 Contract version。
- Developer 可创建/修改 Contract、开发、push、开/更新 PR；不给自己的 PR 做 Required Review，不 merge。
- Reviewer 可独立 approved、Review、APPROVE / REQUEST_CHANGES；不开发、不 push、不修改 repository governance、不 merge。
- Developer / Reviewer 不得自行修改约束自身的 Ruleset / governance。
- Human Authority 是一个或多个具有目标仓库适当 GitHub 权限的人类账号，不绑定固定 username；门禁满足后可通过 GitHub UI、CLI、API 或受其明确指令控制的工具执行最终 Squash merge。不新增 Merge Bot / Merge Executor。
- 不把 consumer-specific CI 实现塞回 canonical G-lite。

## 生命周期与本机身份

Genesis 由 Human Authority 控制：创建仓库，安装/授权 Developer App 与 Reviewer App，建立初始协议基线、CI、Ruleset / governance / security，验证 ACTIVE。可由工具执行，但执行身份与授权必须属于 Human Authority。ACTIVE 日常工作由 Developer + Reviewer 处理，Human Authority 只在治理边界或最终 merge 再介入。

Local Bootstrap ≠ Repository Task：安装/轮换 GitHub App private key、建立 `~/.config/g-lite/` 凭据目录、本地 token helper / shell identity bootstrap、只读 identity preflight、新机器本地身份配置无需 Issue Contract；不因此授权修改任何 repository durable facts。

Developer / Reviewer 使用 short-lived Installation Access Token；private key、JWT、Installation Access Token、PAT 不得写入 repo、Issue、PR、日志证据或 canonical state。私钥仅由外部本机安全机制管理，token 不持久化到状态文件。不创建 identity registry 或 credential runtime。

核验 API Actor（Installation Token 可用 GraphQL viewer）、commit 作者和 transport identity。Developer clone / fetch / push 必须使用 App HTTPS credential；每次操作前确认有效 remote 为 HTTPS、无影响 GitHub HTTPS 的 insteadOf rewrite。优先进程级 Git config / credential isolation，检查 local 配置，不删除用户 global Git / SSH 配置；防止 HTTPS 静默改写成 SSH。

## 交付

1. 读取当前 GitHub Issue Contract，不要用聊天摘要代替当前正文。
2. 确认 Issue OPEN。
3. 按本文件的 Developer authorization freshness 读取 GitHub 当前事实；只有 FRESH 且 Actor 独立才开工。
4. Developer 从最新 `origin/main` 创建普通 Git branch / worktree。
5. 只改 Contract 允许范围。
6. 运行 consumer repo 自己要求的 test / lint / build / security checks。
7. push 并开 PR；PR body 自己写 Why / What / Test / Unverified-Risks / `Fixes #N`。
8. 等 Required Check。
9. 停下。PR Review 交给独立 Reviewer；最终 Squash merge 交给 Human Authority，并服从 GitHub 门禁。

Codex / Cursor / Claude Code / Grok 等只是可替换工作台。

## Reviewer protocol

Issue 上的 `approved` 与 PR Review 的 `APPROVE` 是两种批准：

- `approved`：当前这份 Contract 可以开始做。
- `APPROVE`：当前这一个 PR HEAD 的代码可以合并。

GitHub `Dismiss stale reviews` 不会在 Issue 正文被编辑后自动摘掉 `approved`。正式 Review 前必须重新实时读取 GitHub 事实并计算 authorization freshness。不要沿用 Developer 之前的判断，也不要把结果写成仓库里的状态文件。

### 读取

- 当前 Issue body
- Issue author
- Issue `lastEditedAt`
- Issue editor / edit history（需要时）
- latest `approved` label event
- approved Actor
- approved timestamp（`approvedAt`）
- PR 当前 HEAD
- 当前 diff
- 当前 Required Checks

### 判断

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

并确认写或实质修改当前 Contract version 的 Actor 不是 approved Actor。

INVALID / STALE / Actor 不独立时：不得 APPROVE PR。必须让人重新确认当前 Contract，然后由未写该版本的独立 Actor 重新 `approved`。

### 最终报告至少包含

```text
Reviewed HEAD:
Contract last edited:
Approved at:
Approved by:
Fresh authorization:
Required Checks:
Verdict:
```

## G-lite-compatible consumer

不要用“安装了某个工具”判断 consumer 是否采用 G-lite。检查实际 GitHub 事实：

- Contract 结构存在；
- fresh independent `approved`；
- Developer App 与 Reviewer App 为独立机器 Actor；两个 App 的目标仓库访问需外部 preflight，consumer 绑定可替换；
- main 必须走 PR；
- Required approvals >= 1；
- stale review dismissal 开启；
- 有稳定 Required Check；
- squash merge；
- 无常规 bypass；
- 平台支持时 Secret scanning / Push protection 开启；
- 没有 G-lite replacement CLI 或第二份 GitHub 状态。

consumer 的 Required Check 应检查自己的真实技术栈风险，不要求复用 canonical `pr-gate` 实现。

## Thin Governance Reconciler

`tools/repo-reconciler/` 是可删除的无状态 companion tool：

- `audit` / `plan` 只读检查 GitHub live facts。
- `bootstrap` 只建立缺失的最小 consumer 协议文件、`approved` label，并报告 Developer / Reviewer App prerequisites；不接管项目文件或 CI。
- `activate --required-check NAME` 只接受 Agent 提供的真实成功 Check name，建立或校准 G-lite-owned Ruleset。
- `apply` 幂等执行安全基线与 Ruleset 修复；`upgrade` 只读输出可审查差异。
- 工具只检查 required protocol markers，作为 deterministic mechanical baseline；成熟仓的实际语义判断与补丁由 Agent 负责，工具不整文件覆盖。
- 工具不保存 GitHub durable facts，不管理凭据，不创建 consumer CI。
- `--developer-app-verified` / `--reviewer-app-verified` 分别断言外部真实 preflight，只对当前 invocation 有效；工具不读取 private key、不生成 JWT/token、不保存 credential。
- bootstrap / activate / apply 治理写入由 Human Authority 控制，不向 Developer / Reviewer 授予治理权限。

## 禁止重建

不要恢复或新写：

- `new task` / `new z` / `new check` / `new worktree` 或任何 replacement CLI
- workspace 八域引擎
- backup / restic 引擎
- Router / Controller / Worker / Reviewer App
- PR generator / poll-and-merge
- local task / review / merge / approval state
- Contract hash/cache runtime
- stack-specific CI framework
