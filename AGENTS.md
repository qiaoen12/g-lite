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
- Main 是协调角色，不是第四个 GitHub Actor；可以主动调用当前 workspace / machine 中可用且已验证的 Developer / Reviewer role entry。缺少 `approved` 只阻止 Developer 开工，不阻止 Main 协调或 Reviewer 授权；Reviewer 只能在人重新确认当前 Contract 后独立添加 fresh `approved`。Main 仅在 Human Authority 对当前任务明确授权后，才可核对人类 Actor 并机械执行最终 merge，且不写 Developer 的 PR branch。
- 不把 consumer-specific CI 实现塞回 canonical G-lite。

## 生命周期与本机身份

Genesis 由 Human Authority 控制：创建仓库，安装/授权 Developer App 与 Reviewer App，建立初始协议基线、CI、Ruleset / governance / security，验证 ACTIVE。可由工具执行，但执行身份与授权必须属于 Human Authority。ACTIVE 日常工作由 Developer + Reviewer 处理，Human Authority 只在治理边界或最终 merge 再介入。

Local Bootstrap ≠ Repository Task：安装/轮换 GitHub App private key、建立 `~/.config/g-lite/` 凭据目录、本地 token helper / shell identity bootstrap、只读 identity preflight、新机器本地身份配置无需 Issue Contract；不因此授权修改任何 repository durable facts。

在使用本机凭据入口的每个 checkout 中，Local Bootstrap 先将 `.g-lite-local/` 加入该 checkout 的 Git 本地 exclude（可用 `git rev-parse --git-path info/exclude` 定位），再创建 `.g-lite-local/credentials` 软链接，指向实际机器凭据根目录。软链接及目标均不进入 Git；不要改仓库 `.gitignore`，也不要假定 Developer / Reviewer 私钥的固定文件布局。确认 `git check-ignore` 覆盖该入口；从干净 checkout 出发，创建后 `git status` 仍应干净。

Developer / Reviewer 使用 short-lived Installation Access Token；private key、JWT、Installation Access Token、PAT 不得写入 repo、Issue、PR、日志证据或 canonical state。私钥仅由外部本机安全机制管理，token 不持久化到状态文件。不创建 identity registry 或 credential runtime。

需要 Developer / Reviewer 身份时，先调用当前 workspace / machine 可用的 configured role entry；entry 必须实时验证预期 API Actor 与目标仓库访问。Credential path、环境变量存在或 Human `gh` 登录都不是身份凭据。Actor / access mismatch = BLOCK：停止该角色动作，不猜私钥布局、不尝试临时认证路径，也不回退到 Human 身份。只有没有可调用 role entry 时，才按本机约定检查 `.g-lite-local/credentials` 与 `~/.config/g-lite/` 的最小存在性、类型和可访问性元数据；不遍历或展示凭据内容，不记录私钥、JWT、token、PAT 或实际机器凭据绝对路径到 repo / Issue / PR / 日志。

核验 API Actor（Installation Token 可用 GraphQL viewer）、commit 作者和 transport identity。Developer clone / fetch / push 必须使用 App HTTPS credential；每次操作前确认有效 remote 为 HTTPS、无影响 GitHub HTTPS 的 insteadOf rewrite。优先进程级 Git config / credential isolation，检查 local 配置，不删除用户 global Git / SSH 配置；防止 HTTPS 静默改写成 SSH。

同一台 Mac 可存放 Human、Developer、Reviewer 三种凭据。每次关键 GitHub / Git 动作核对实际 API Actor、Git transport 与操作角色；Developer 不得实际以 Human Authority 身份 push / merge，Reviewer 不得实际以 Developer / Human Authority 身份 Review。发现串号即停止该动作并查明原因。物理凭据隔离是未来 hardening，不是 v3.4 Freeze 条件。

## Primary checkout 与 native Git worktree

- `primary checkout` 永远停留在 repository default branch（canonical 仓库为 `main`）。Main 可在此协调、fetch / fast-forward、只读检查和最终验证；Developer 不切换 primary 到 task branch，也不在 primary 修改 task files。
- 修改 task files 前，确认 primary clean 且位于 default branch；通过已验证的 Developer role entry fetch `origin`，再仅对 primary main 执行 fast-forward。不得 reset、rebase，或把 primary 切换到 task branch。primary dirty、分支错误或无法安全 fast-forward 时停止并报告。
- 用 native Git 从最新 `origin/main` 创建每个任务唯一的可写 branch/worktree：

  ```sh
  git fetch origin
  git merge --ff-only origin/main
  git worktree add -b <task-branch> <task-worktree> origin/main
  git worktree list --porcelain
  ```

- 一个可写 task branch 只绑定一个 dedicated task worktree，一个 task worktree 只含一个可写 task branch。`git worktree list --porcelain` 是 branch/path binding 的唯一 source of truth；不创建 registry、数据库或其他持久 task state。Developer 只在自己的 task worktree 修改和提交。
- Reviewer 默认远程读取 GitHub live facts。确实需要本地执行时，仅创建独立临时 detached-HEAD worktree（例如 `git worktree add --detach <review-worktree> <reviewed-head>`）；不得复用或切换 primary / Developer worktree，Review 后移除临时 worktree。
- Human Authority 完成 Squash merge 后，先确认 GitHub 上目标 PR 已合并，再用 `git worktree remove <task-worktree>` 和 native Git 删除本地 branch；不删除 remote task branch。先用 `git branch -d <task-branch>`；如果它仅因 squash commit 不在 branch ancestry 而拒绝，确认 task worktree clean 且目标 PR 确为 merged 后，才可用 `git branch -D <task-branch>` 删除这个本地 ref。其他拒绝原因一律停止并调查，不得强制删除。
- 之后通过 Developer role entry fetch `origin`，在仍位于 main 的 primary 执行 `git merge --ff-only origin/main`，确认目标 worktree 已移除、primary main + clean。Main 不需要也不应把 primary checkout 切到 task branch。

## 交付

1. 读取当前 GitHub Issue Contract，不要用聊天摘要代替当前正文。
2. 确认 Issue OPEN。
3. 按本文件的 Developer authorization freshness 读取 GitHub 当前事实；只有 FRESH 且 Actor 独立才开工。
4. primary checkout 留在 default/main 且 clean；fast-forward 到最新 `origin/main`，再用 native Git 建立一个 task branch 对应一个 dedicated worktree，Developer 只在该 worktree 修改 task files。
5. 只改 Contract 允许范围。
6. 运行 consumer repo 自己要求的 test / lint / build / security checks。
7. push 并开 PR；PR body 自己写 Why / What / Test / Unverified-Risks / `Fixes #N`。
8. 等 Required Check；失败时 Developer 修复本任务范围内的问题并 push 新 HEAD。
9. Developer 停下。PR Review 交给独立 Reviewer；最终 Squash merge 交给 Human Authority，并服从 GitHub 门禁。

Codex / Cursor / Claude Code / Grok 等只是可替换工作台。

## 开发验证生命周期

开发验证是协议层生命周期，不是新的 runtime。
不创建 label、数据库字段、cache、文件或本地状态机来记录验证进度。
Git、GitHub 与测试结果仍是事实。

中等或更大的工作，在实现前把 Implementation & Verification Plan 写进当前 Contract。
计划至少写明：预期文件与责任边界、实现与测试的大致规模、主要复杂度或风险、本任务选用的验证层级、Local / CI / Pilot 放置、Permanent / Stage / Pilot、LOCAL GREEN、CI GREEN、REVIEW-READY，以及停止条件。
纯文档或琐碎工作可以写明完整计划不适用。

Contract 只选用能提供该任务证据的层级，不必填满每一级：

- **L0 Static** — 语法、必需文件、schema 或基本一致性，以及 `git diff --check`。
- **L1 Unit** — 单个函数或变换。
- **L2 Integration** — 组合后的模块，以及被模拟的边界。
- **L3 Acceptance / Contract** — Issue 承诺的行为；在相关时包括精确收敛与幂等。
- **L4 E2E / Pilot** — 真实环境的整链验证，仅当副作用或成本值得时使用。

测试有三种生命周期：

- **Permanent** — 长期回归，留在仓库测试与 CI。
- **Stage** — 任务或 worktree 上的临时验证。
- **Pilot** — 真实环境、昂贵或带副作用的验证。

每个 Stage 测试在任务完成前必须恰好结束为一种处置：`PROMOTE`（升为 Permanent）、`KEEP MANUAL`（明确的手工、发布或 nightly 步骤）或 `DELETE`（删掉一次性验证）。

canonical 仓库的验证入口是 `tests/run.sh`。
它检查必需文件、协议 marker 与 heading、shell 静态合法性、manifest JSON / schema。
它也检查禁用的 legacy 路径与遗留行为，并确认 workflow 调用这条入口。
然后运行 `tools/repo-reconciler/reconcile.sh` self-test 与 `tools/machine-bootstrap/tests/self-test.py`。
consumer repo 不要求复制这条 canonical runner。
它们用自己的 Required Check 覆盖真实技术栈风险。

对本 canonical 仓库：

```text
LOCAL GREEN = tests/run.sh PASS
CI GREEN    = 同一 runner 在当前 PR HEAD 上于 GitHub PASS
```

Required Check 名仍是 `pr-gate`。
`.github/workflows/pr-gate.yml` 是薄 GitHub wrapper，只执行 `bash tests/run.sh`。
这次 GitHub 运行是可审计的干净重跑，也是 CI 事实来源。

`REVIEW-READY` 是从事实推出的结论，不是 label、数据库字段、cache、文件或本地状态机。
普通实现工作至少要同时满足：该任务要求的本地验证已经通过，存在指向预定 HEAD 的 PR，该 HEAD 上的 `pr-gate` 通过，并且没有已知且未解决的 Contract blocker。
CI 失败就回到 Developer。Reviewer 不是第二个 debugger。
独立 Reviewer 在 REVIEW-READY 之后进入，核对 Contract 契合、范围、结构、测试可信度与语义正确性。
最终 Squash merge 仍由 Human Authority 执行。

## Main 连续交付 SOP

1. 新任务先记录 Original Intent（用户原话或固定 PRD 引用），再写当前 Issue Contract。
   现行 reconciler 不自动检查旧 consumer 是否已有 Original Intent。
2. Main 可主动调用已验证的 Developer / Reviewer role entry；缺少 `approved` 只挡 Developer，不挡 Main 协调。Reviewer 可在人重新确认当前 Contract 后独立补 fresh `approved`。Main 持续读 CI 和 Review。CI 失败交 Developer 在当前范围修复；
   `REQUEST_CHANGES` 交 Developer 修改并 push 新 HEAD。
   等待该 HEAD 的 Required Checks，独立 Reviewer 对新 HEAD 重审；Main 再读取当前事实。
3. Main 读取 GitHub live `main` SHA `B` 和当前 PR HEAD `H`，用 GitHub compare API
   或 `git merge-base --is-ancestor B H` 证明 `B` 是 `H` 祖先。
   失配时 Main 不写 PR branch；Developer 用 App 身份更新 main / rebase / merge base 并 push 新 HEAD。
   `gh pr update-branch` 若写 PR branch，也只由 Developer 执行。新 HEAD 必须重跑 Checks、重审并重新 preflight。
4. `merge-authorized` 只记录 Human Authority 对当前任务“过门禁后直接合并”的明确预授权。
   新仓库首次使用时，Main 核对有目标仓库权限的人类 API Actor，在其明确授权下创建并添加 label；
   reconciler bootstrap 不创建它。缺少 fresh label 时，最终 merge 另请 Human Authority 确认。
5. 自动合并前核对 Issue 上仍有 label、最新 `merge-authorized` LabeledEvent 的 Actor / `createdAt`、
   当前 Issue body `lastEditedAt`；Actor 必须是有权限的人类，`createdAt` 不早于 body 编辑，且授权未撤销。
   Developer 写的 Issue 文字不能授予合并权。
6. 最终 preflight 实时核对 OPEN Issue、当前 Contract、独立 fresh `approved`、PR OPEN 且非 Draft、
   base=`main`、当前 `B` 是 `H` 祖先、`H` 的 Required Checks PASS、独立 Reviewer 对 `H` APPROVE
   与 GitHub merge eligibility。合并前紧邻操作重读 `B`、`H`、授权与门禁，确认 Human Authority API Actor，
   再以 Squash 和预期 HEAD SHA 合并（`gh pr merge --squash --match-head-commit H`）。
7. 读取 GitHub 实际 merged 状态、merge commit SHA 和 Issue 状态；
   报告 Issue、PR、Checks、Review、merge SHA 与未验证项。
   当前 Ruleset strict latest-base=false；上述祖先检查是 SOP，main 在最后核对与 merge 间仍可能前进。
8. Contract / Original Intent / Out of scope 发生实质范围变化，身份、授权、transport 或门禁无法可靠核实，
   需要治理/高影响操作，或同一路径约三次失败且无新证据时，请 Human Authority 介入；
   当前范围内的普通 CI / Review 返工继续执行。

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
- `protocol-sync` 对一个本地 checkout 做确定性协议同步：精确替换声明的 owned exact，只替换 managed block 内部，不改 consumer 自有内容；不写 GitHub，不创建 branch、commit 或 PR。
- 工具只检查 required protocol markers，作为 deterministic mechanical baseline；成熟仓的实际语义判断与补丁由 Agent 负责，工具不整文件覆盖。
- 工具不保存 GitHub durable facts，不管理凭据，不创建 consumer CI。
- `--developer-app-verified` / `--reviewer-app-verified` 是外部 identity / installation preflight，分别断言 Developer 与 Reviewer App 的当前身份、独立性和目标仓库 installation access。
- `bootstrap` / `activate` / `apply` 还必须带 invocation-only `--human-authority-verified`，表示调用者已外部确认本次治理写入由 Human Authority 明确授权并使用适当身份。
- 三项断言均只对当前 invocation 有效；统一 write preflight 在 `bootstrap_file`、`ensure_label`、`ensure_ruleset` 之前执行，缺失任一项即 `UNVERIFIED` / exit 3 并在任何 durable write 前停止。`audit` / `plan` / `upgrade` / `self-test` 不要求 Human Authority assertion。
- 工具不持久化 assertion，不读取 private key、不生成 JWT/token、不保存 credential、不建立 allowlist / identity registry，也不形成第二份 GitHub 状态；App assertion 不向 Developer / Reviewer 授予 governance write 权限。

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
