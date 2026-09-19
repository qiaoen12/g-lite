# G-lite agent-card

## 开工

- 只读根目录 `README.md` 与本文件；不要泛读历史 Git 或已删除目录。
- 任务身份、Contract 与允许范围只信当前 GitHub Issue 正文。
- 开工前确认：Issue 为 OPEN，且有有效 `approved`。
- 仓库身份从当前 Git origin 推导，不依赖固定本机路径。
- GitHub 是 PR、Checks、Review、merge eligibility 与 merge result 的 SSOT。

## 硬边界

- 不写明文凭据；不把密钥、PAT、host inventory 写入仓库、日志或 Issue。
- 不安装、不调用、不重建 G-lite CLI。
- 不创建 `task_state`、`review_state`、`merge_state`、`ready_to_merge`、approval cache、Contract hash runtime。
- Developer Actor ≠ Reviewer Actor。当前 Developer = `qiaoen12`，Reviewer = `qiaoen-reviewer`。
- 写或实质修改 Contract 的 Actor 不得批准同一 Contract version。
- Developer 不给自己的 PR 做 Required Review，不 merge。
- 候选 runtime 不得管理、review 或 merge 自己。

## 交付

1. 读取当前 GitHub Issue Contract，不要用聊天摘要代替当前正文。
2. 确认 Issue 为 OPEN，且 `approved` 真实存在。
3. Developer 从最新 `origin/main` 创建普通 Git branch / worktree。
4. 只改 Contract 允许范围。
5. push 并开 PR；等待 `pr-gate`。
6. 停下。Review 与 merge 交给独立 Reviewer 与 GitHub。

Codex / Cursor / Claude Code / Grok 只是可替换工作台。

## Reviewer protocol

Issue 上的 `approved` 与 PR Review 的 `APPROVE` 是两种批准：

- `approved`：这件事、按这个范围，可以开始做。
- `APPROVE`：当前这一个 PR HEAD 的代码，可以合并。

GitHub `Dismiss stale reviews` 不会在 Issue 正文被编辑后自动摘掉 `approved`。正式 Review 前必须实时读取 GitHub 事实并计算授权 freshness。不要把结果写成仓库里的状态文件。

### 读取

- Issue author
- Issue `lastEditedAt`
- Issue editor / edit history（需要时）
- latest `approved` label event
- approved Actor
- approved timestamp（`approvedAt`）

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

INVALID 或 STALE 时：不得 APPROVE PR。必须让人重新确认当前 Contract，然后由未写该版本的独立 Actor 重新 `approved`。

写或实质修改当前 Contract 的 Actor，不得批准同一 Contract version。

### 最终报告至少包含

```text
Contract last edited:
Approved at:
Approved by:
Fresh authorization:
```

## 禁止重建

不要恢复或新写：

- `new task` / `new z` / `new check` / `new worktree` 或任何 replacement CLI
- workspace 八域引擎
- backup / restic 引擎
- Router / Controller / Worker / Reviewer App
- stack-specific CI framework
