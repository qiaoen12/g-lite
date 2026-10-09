<!-- g-lite:managed protocol start -->
G-lite Protocol-Version: v4.0.0

# G-lite 协议

本仓库使用 G-lite：GitHub 管事实和门，Agent 干活，G-lite 只规定任务分级、确认点和结果汇报。其余交给 Git / GitHub、本仓库自己的 CI 和 Agent 自身设置。

## 任务分级

- **常规**：除“上线”外的一切，包括采集、查询、诊断、调研、开发，以及分支和预览环境上的改动。用户指令即授权，不需要 Issue 或 label。
- **上线**：合入 default branch、生产部署、凭据变更、数据删除、权限或治理变更。动作前取得用户明确确认。确认针对具体对象（如提交 SHA、部署版本），对象变化后须重新确认。协议只规定需要确认，确认的呈现形式由 Agent 自身设置决定。

需要跨会话追踪的任务可以建 Issue：整个正文就是任务说明，`Background` 写请求、目标、完成条件和边界，`Execution` 可选。评论只放讨论和证据。

## 完成证据

- **结果汇报**（必有）：结论、可查看的位置（链接、路径等）、已执行的验证、未验证项。
- **改动摘要**（涉及开发时）：改了什么、为什么。

上线的结果汇报另写明合并结果（PR、merge SHA）、部署结果（适用时：环境、版本、访问地址、检查结果）和回退方式。G-lite 不规定部署方式。

## 角色

- **Human Authority**：对本仓库有相应权限的人类账号。给出上线确认，控制 Ruleset 等治理设置。
- **Main**：与用户对话的协调 Agent（中枢）。派发任务、汇总结果、向用户取得确认；合并与部署凭据只由中枢持有，并只在用户确认后使用。
- **Developer**：执行开发的 Agent，以机器身份（GitHub App）commit、push、开 / 更新 PR。不合并，不修改约束自身的治理设置。

## 工作区

- primary checkout 留在 default branch 且 clean，只做协调、fast-forward 和只读检查。
- 每个开发任务从最新 `origin/<default>` 用 native Git 建一个专用 worktree 和一个分支：`git worktree add -b <branch> <path> origin/<default>`。`git worktree list --porcelain` 是绑定关系的唯一来源。
- 合并后先确认 PR 已 merged，再 `git worktree remove <path>`，用 `git branch -d <branch>` 删除本地分支；仅因 squash 提交不在分支祖先中而被拒时，确认 worktree clean 且 PR 已 merged 后可用 `git branch -D`。保留 remote 分支，最后 fast-forward primary。

## 合入 default branch

1. Developer push 分支并开 PR，本仓库的 Required Check 在当前 HEAD `H` 上通过。
2. Main 把结果汇报和改动摘要交给用户，取得对 `H` 的确认，再以 Human 账号对 PR 提交 Approve 留痕。
3. 合并前读取最新一条 Human Approve 所针对的提交 SHA，确认它等于当前 `H`；不相等就重新确认。不依赖 dismiss stale reviews 判断批准是否有效。
4. 合入前基于最新 default branch：Ruleset 的 strict 已实际生效时由 GitHub 保证；未生效时，Main 读取 live default branch SHA `B`，用 GitHub compare 或 `git merge-base --is-ancestor B H` 确认 `B` 是 `H` 的祖先。不是祖先时，Main 不写 PR 分支，由 Developer 更新分支并 push 新 HEAD，重新走 1–3。
5. 以 Human 账号执行 `gh pr merge --squash --match-head-commit H`，读回 merged 状态和 merge SHA，写入结果汇报。

## GitHub 门

- 可用 Ruleset 的仓库：default branch 要求 PR、approvals = 1、dismiss stale reviews、squash only、strict、稳定的 Required Check（检查本仓库自己的技术栈），无常规 bypass；平台支持时开启 Secret scanning / Push protection。
- 不可用 Ruleset 的仓库（例如 GitHub Free 的私有仓）：门由凭据把守。合并与部署凭据只由中枢持有，执行端 Agent 不持有。

## 身份与凭据

- Developer 使用 short-lived Installation Access Token，经 canonical G-lite checkout 中的 role entry `tools/machine-bootstrap/role-exec` 按需取得；它调用机器本地 bridge（默认 `~/.config/g-lite/bin/app-env.sh`，可由已有的 `G_LITE_APP_ENV` 覆盖），并实时核验 API Actor 与仓库访问。entry 不可用、Actor 或访问不符时停止，不回退到 Human 身份，不寻找替代认证路径。
- 分别核验 API Actor、commit 作者和 Git transport。Developer 的 Git 走 App HTTPS 凭据：操作前确认有效 remote 为 HTTPS 且没有 insteadOf 改写，优先进程级隔离，不修改用户全局 Git / SSH 配置。
- private key、JWT、token、PAT 不写入仓库、Issue、PR 或日志；不展示凭据内容，不记录机器专属凭据路径。
- 本机凭据的安装、轮换和身份配置（Machine Bootstrap）不需要 Issue，也不授权改变仓库内容。

## 不做

不建本地 task / review / merge / approval 状态、第二份 GitHub 数据库、identity registry 或 G-lite 专用 CLI。GitHub 是 PR、Checks、Review、Ruleset 和合并结果的事实来源。

<!-- g-lite:managed protocol end -->

# 本仓库（canonical G-lite）

- 本仓库是 G-lite 协议源。上方 managed block 与 `tools/repo-reconciler/templates/minimal-consumer-AGENTS.md` 逐字一致（`tests/run.sh` 检查）；修改协议时两处同步修改。
- 开工只读根目录 `README.md` 与本文件，不泛读历史 Git 或已删除目录。
- 当前绑定：Developer = `g-lite-developer[bot]` / App ID `5017695`；Human Authority = 对本仓库有相应权限的人类账号。
- 验证：本地 `bash tests/run.sh` 通过；同一 runner 在 PR HEAD 上以 Required Check `pr-gate` 运行，`.github/workflows/pr-gate.yml` 只调用它。
- 版本：协议版本以 managed block 第二行的版本声明与 Git tag 为准；旧版本的规则与证据见对应 tag。

## 工具

- `tools/machine-bootstrap/role-exec`：Developer role entry，部署见 `docs/machine-bootstrap.md`。
- `tools/repo-reconciler/`：可删除的无状态治理工具，只处理稳定、机械的 GitHub 治理事实。
  - `audit` / `plan` / `upgrade` 只读。
  - `bootstrap` / `activate` / `apply` 写治理设置，必须带本次调用有效的 `--human-authority-verified` 与 `--developer-app-verified`；缺任一项即在任何写入前以 `UNVERIFIED` / exit 3 停止。断言不持久化。
  - `activate --required-check NAME --check-sha SHA` 只绑定在该提交上真实成功的 Check，不从 workflow 推断。
  - `protocol-sync --checkout DIR` 只同步本地 checkout 的 `AGENTS.md` managed block 与两个模板，不写 GitHub，不建 branch、commit 或 PR。
  - 工具不读私钥、不生成 token、不保存凭据、不生成 consumer CI。

## 不恢复

G-lite 专用 CLI（`new` / `z*` 及任何替代品）、workspace 八域引擎、backup / restic 引擎、Router / Controller / Worker runtime、PR generator / poll-and-merge、本地 task / review / merge / approval 状态、Contract hash / cache runtime、stack-specific CI framework。
