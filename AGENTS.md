# G-lite agent-card

## 开工

- 只读根目录 `README.md` 与本文件；不要泛读历史 Git 或已删除目录。
- 任务身份、Contract 与允许范围只信当前 GitHub Issue 正文。
- 仓库身份从当前 Git origin 推导，不依赖固定本机路径。
- GitHub 是 Issue authorization、PR、Checks、Review、merge eligibility 与 merge result 的 SSOT。
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
- 不恢复 task/runtime CLI。允许调用 `tools/repo-reconciler/reconcile.sh` 做一次性仓库治理校准；它不是任务入口，也不得保存任务状态。
- 不创建 `task_state`、`review_state`、`merge_state`、`ready_to_merge`、approval cache、Contract hash runtime。
- Developer Actor ≠ Reviewer Actor。当前 canonical Developer = `qiaoen12`，Reviewer = `qiaoen-reviewer`。
- 写或实质修改 Contract 的 Actor 不得批准同一 Contract version。
- Developer 不给自己的 PR 做 Required Review，不 merge。
- 不把 consumer-specific CI 实现塞回 canonical G-lite。

## 交付

1. 读取当前 GitHub Issue Contract，不要用聊天摘要代替当前正文。
2. 确认 Issue OPEN。
3. 按本文件的 Developer authorization freshness 读取 GitHub 当前事实；只有 FRESH 且 Actor 独立才开工。
4. Developer 从最新 `origin/main` 创建普通 Git branch / worktree。
5. 只改 Contract 允许范围。
6. 运行 consumer repo 自己要求的 test / lint / build / security checks。
7. push 并开 PR；PR body 自己写 Why / What / Test / Unverified-Risks / `Fixes #N`。
8. 等 Required Check。
9. 停下。Review 与 merge 交给独立 Reviewer 与 GitHub。

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
- Developer ≠ Reviewer；
- main 必须走 PR；
- Required approvals >= 1；
- stale review dismissal 开启；
- 有稳定 Required Check；
- squash merge；
- 无常规 bypass；
- 平台支持时 Secret scanning / Push protection 开启；
- 没有 G-lite replacement CLI 或第二份 GitHub 状态。

consumer 的 Required Check 应检查自己的真实技术栈风险，不要求复用 canonical `pr-gate` 实现。

## Repo Reconciler

`tools/repo-reconciler/` 是 optional companion tool：

- `audit`：只读输出 PASS / DRIFT / PLATFORM_BLOCKER / PERMISSION_BLOCKER / UNVERIFIED。
- `plan`：只计算目标状态与当前状态的差异。
- `apply`：幂等修复确定性治理差异；破坏性或权限类操作必须显式选择。
- `upgrade`：只读比较 canonical baseline；不得静默覆盖 consumer README / AGENTS / CI。
- Genesis 首次接入先 bootstrap，真实 CI success 后再 active + Required Check。
- 工具不得创建业务 Issue、自动 dev/fix/review/merge、保存 GitHub live facts 或形成第二套 runtime。

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
