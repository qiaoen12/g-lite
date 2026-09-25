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
Main Agent（协调）
  ↓
Issue Contract
  ↓
fresh independent approved
  ↓
ordinary Git branch / worktree
  ↓
Developer Agent
  ↓
LOCAL GREEN
  ↓
PR
  ↓
CI GREEN
  ↓
REVIEW-READY
  ↓
independent Reviewer
  ↓
GitHub APPROVE / REQUEST_CHANGES
  ↓
Human Authority: Squash merge（可按任务级授权由 Main 机械执行）
```

实现先到达 LOCAL GREEN，再开 PR。
当前 HEAD 的 CI GREEN 之后才是 REVIEW-READY，然后进入独立 Reviewer。
CI 为红则回到 Developer。Reviewer 不是第二个 debugger。

对本 canonical 仓库，LOCAL GREEN 是 `tests/run.sh` 通过。
CI GREEN 是同一 runner 在当前 PR HEAD 上通过。
Required Check 名仍是 `pr-gate`。
`.github/workflows/pr-gate.yml` 是薄 GitHub wrapper，只调用 `bash tests/run.sh`。
consumer repo 不要求复制这条 canonical runner，继续使用自己的稳定 Required Check。

REVIEW-READY 由这些事实推出，不是 label、数据库字段、cache、文件或本地状态机。
中等及以上工作先在 Contract 写 Implementation & Verification Plan。
纯文档或琐碎工作可以写明完整计划不适用。
验证层级、Permanent / Stage / Pilot 的定义见 `AGENTS.md`。

删掉本仓库里任何一个非协议模块之后，这条闭环必须仍然完整。

Main 持续安排开发、CI、独立 Review 与范围内返工；它是协调角色，不是第四个 GitHub Actor。Main 可以主动调用当前 workspace / machine 中可用且已验证的 Developer / Reviewer role entry 来推进任务。缺少 `approved` 只阻止 Developer 开工，不阻止 Main 协调，也不阻止 Reviewer 在人重新确认当前 Contract 后独立添加 fresh `approved`。正常任务以结果报告结束，不要求人中途搬运上下文。

需要机器身份时先调用可用的 role entry；credential path 存在或 Human `gh` 已登录都不等于机器 Actor 已验证。entry 必须实时证明预期 Actor 与目标仓库访问；身份或权限不匹配即 BLOCK，绝不回退到 Human 身份。同一路径约三次失败且没有新证据时，请 Human Authority 介入。

## Actor

| 角色 | GitHub Actor | 做什么 | 不做什么 |
| --- | --- | --- | --- |
| Developer | 机器身份；当前 canonical `g-lite-developer[bot]` / App ID `5017695` | 创建/修改 Contract、验证 freshness、开发、push、开/更新 PR | 不批准自己写/改的 Contract，不给自己的 PR 做 Required Review，不 merge，不自行修改约束自身的 Ruleset / governance |
| Reviewer | 独立机器身份；当前 canonical `g-lite-reviewer[bot]` / App ID `5010632` | 独立添加 `approved`，重新核对 Contract、freshness、HEAD/diff、Checks，`APPROVE / REQUEST_CHANGES` | 不开发、不 push、不修改 repository governance、不 merge |
| Human Authority | 一个或多个对目标仓库具有适当 GitHub 权限的人类账号 | 控制 Genesis / governance；门禁满足后最终 Squash merge | 不绕过 GitHub 门禁 |

角色限制绑定到当前治理角色，不绑定到某个固定人类账号、工作台或所有工具入口。以上 App 名称/ID 只是 current canonical binding；consumer 可替换具体账号/App，必须保持机器身份及角色独立性。

Human Authority 可通过 GitHub UI、CLI、API 或受其明确指令控制的工具机械执行最终 Squash merge。Main 只有取得当前任务的明确合并授权后，才能核对人类 Actor 并使用其凭据执行；Main 本身不拥有合并权限。Developer 不 merge；Reviewer 不 merge。不新增 Merge Bot / Merge Executor。

Developer Actor ≠ Reviewer Actor。

写或实质修改当前 Contract 的 Actor，不得批准同一份 Contract version。

聊天里的「开始做」不替代 Issue 上独立、fresh 的 `approved` 开发授权。最终合并另由 Human Authority 对当前任务明确授权。

## Issue Contract

Human Authority 或 Developer 在 GitHub Issue 正文写契约。模板最小结构：

```text
Original Intent（用户原话或固定 PRD 引用）
Contract
├ Goal
├ Acceptance
├ Out of scope
└ Authorization
```

v3.4 新任务填写 Original Intent。现行 reconciler 仍只检查四个 Contract marker，不自动审计旧 consumer 是否补齐该字段。

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

Developer / Reviewer 使用 short-lived Installation Access Token。private key 仅由外部本机安全凭据机制管理；private key、JWT、Installation Access Token、PAT 不得写入 repo、Issue、PR、日志证据或 canonical state，token 不得持久化到状态文件。`tools/machine-bootstrap/` 提供独立、可选的薄参考 role entry 与[部署说明](docs/machine-bootstrap.md)：它调用机器本地 bootstrap 按需 mint token，实时验证 Actor 和目标仓库访问，再将 token 交给子进程；不规定 private-key 文件名/布局、不保存凭据或 token。它不改 Human `gh auth`，也不回退到 Human 身份。

GitHub API Actor、commit 作者和 Git transport identity 必须分别核验。Installation Token 若不能调用 REST `/user`，可用同一 token 的 GraphQL `viewer.login` 核验 Actor，不回退人类凭据。Developer clone / fetch / push 使用 App HTTPS credential：用户级/global Git `insteadOf` 可能将 HTTPS 静默改写为 SSH。每次 transport 前确认有效 remote 是 HTTPS、无影响它的 rewrite；优先任务进程级隔离（例如 `GIT_CONFIG_GLOBAL=/dev/null`、`GIT_CONFIG_NOSYSTEM=1`、`GIT_ALLOW_PROTOCOL=https`，同时检查 repo-local 配置与 credential helper）。不要要求删除用户全局 Git / SSH 配置。

GitHub 是 Issue authorization、PR、Checks、Review、Ruleset、merge eligibility、merge result 的 SSOT；不建立 identity registry、approval DB 或第二份 GitHub 状态。

## 开发

不需要安装 G-lite CLI。用普通 `git` / `gh` 或现成 Agent 工作台。

1. 读取当前 GitHub Issue 正文，不要用聊天摘要代替。
2. 确认 Issue 为 OPEN。
3. 读取当前 `approved` 及最新 label event、Contract 最近 body edit；确认 authorization FRESH 且批准 Actor 独立。
4. Developer 从最新 `origin/main` 创建普通 branch / worktree。
5. 只改 Contract 允许的范围。中等或更大的工作先有 Implementation & Verification Plan；纯文档或琐碎工作可以写明完整计划不适用。
6. 跑到 LOCAL GREEN。canonical 仓库跑 `tests/run.sh`。
7. push 并开 PR；PR 用 `Fixes #N` 关联 Issue。
8. 等待当前 HEAD 的 CI GREEN。失败则修本 PR 引入的问题，不绕过门。canonical 的 `pr-gate` 只跑同一入口。
9. 任务要求的本地验证、该 HEAD 的 `pr-gate` 都通过，且没有已知未解决的 Contract blocker 时，才是 REVIEW-READY。独立 Reviewer 再读取 Contract、fresh approval、当前 HEAD/diff、Checks。
10. Main 重新核对当前门禁；Human Authority 在满足门禁后执行最终 Squash merge，或按当前任务的明确授权由 Main 使用其身份机械执行。

Codex / Cursor / Claude Code / Grok 等只是可替换工作台。

## Main 连续交付 SOP（v3.4）

同一台 Mac 可以存放 Human、Developer App、Reviewer App 三种凭据。每次关键 GitHub / Git 动作前核对 API Actor、有效 Git transport 和操作角色；Developer 不得以人类身份 push / merge，Reviewer 不得以 Developer 或人类身份 Review。物理隔离属于未来 hardening，不是本版 Freeze 条件。

Main 持续读取 CI 与 Review：CI 失败由 Developer 修本任务范围内的问题；`REQUEST_CHANGES` 交 Developer 修改并 push 新 HEAD，再等该 HEAD 的 Required Checks 和独立 Reviewer 重审。范围变化、身份或授权无法核实、治理/高影响动作、同一路径约三次失败且无新证据时，Main 询问 Human Authority。

合并前，Main 读取 GitHub live `main` SHA `B` 与当前 PR HEAD `H`，证明 `B` 是 `H` 的祖先（compare API 或 `git merge-base --is-ancestor`）。若不是，Main 不写 PR branch：Developer 以 App 身份更新 main / rebase / merge base 并 push 新 HEAD；`gh pr update-branch` 也只能由 Developer 执行。随后对新 HEAD 重跑 Checks、重新 Review，Main 从头 preflight。

Human Authority 可在任务开始明确授权过门禁后合并。首次使用该能力时，Main 核对人类 API Actor，在其明确授权下创建并添加 `merge-authorized` label；这是一项 Genesis prerequisite，不由 reconciler bootstrap 创建。Main 在自动合并前核对 label 仍在 Issue 上、最新 LabeledEvent 的 Actor 是有权限的人类、`createdAt` 不早于当前 Contract 的 `lastEditedAt`，且授权未被撤销。缺少 fresh label 时，最终合并另请 Human Authority 确认。

最终 preflight 实时核对 OPEN Issue、当前 Contract 与独立 fresh `approved`、PR OPEN 且非 Draft、base=`main`、`B` 是 `H` 祖先、`H` 的 Required Checks PASS、独立 Reviewer 对 `H` 的 APPROVE，以及 GitHub merge eligibility。合并前紧邻操作重读 `B`、`H`、授权和门禁；核对人类 API Actor 后，以 Squash 和预期 HEAD SHA 执行（`gh pr merge --squash --match-head-commit H`）。再读 GitHub merged 状态、merge commit SHA 与 Issue 状态，报告 Checks、Review 和未验证项。

当前 Ruleset 的 `strict_required_status_checks_policy=false`，reconciler 默认值也是 `false`。上述最新 main 核对是 SOP，不是 GitHub 的原子 strict 门禁；main 在最后核对与 merge 之间仍可能前进，双 PR Pilot 需记录这一窗口。

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

Current governance baseline = v3.4

v3.4 Freeze evidence：

- Implementation：[Issue #47](https://github.com/qiaoen12/g-lite/issues/47) → [PR #48](https://github.com/qiaoen12/g-lite/pull/48)，Main continuous-delivery SOP。
- Regression protection：[Issue #50](https://github.com/qiaoen12/g-lite/issues/50) → [PR #52](https://github.com/qiaoen12/g-lite/pull/52)，确定性 `pr-gate` 断言。
- Pilot A：Actor / HTTPS transport separation PASS。
- Pilot B：[g-ci-catalog #10](https://github.com/qiaoen12/g-ci-catalog/issues/10) / [PR #12](https://github.com/qiaoen12/g-ci-catalog/pull/12)：CI failure → Developer fix → REQUEST_CHANGES → fix → new HEAD → CI → APPROVE，PASS。
- Pilot C：[g-ci-catalog #9](https://github.com/qiaoen12/g-ci-catalog/issues/9) / [PR #11](https://github.com/qiaoen12/g-ci-catalog/pull/11)：`merge-authorized` → 无二次人类确认 → Human Authority merge，PASS。
- Pilot D：并行 PR #11 合入后发现 PR #12 stale base → Developer refresh → new HEAD → CI + re-review，PASS。

四个 Pilot 已通过；v3.4 不依赖 Jev。已知限制：`strict_required_status_checks_policy=false`，latest-main 保护仍是 Main 的 SOP 祖先检查，不是 GitHub 平台的原子保证；最后核对与 merge 之间仍可能有竞态。

v3.4 Freeze 从 [Issue #53](https://github.com/qiaoen12/g-lite/issues/53) 对应 PR 的 squash merge commit 开始；合并前不预写未知 Freeze SHA。该 SHA 用于 annotated `v3.4.0` tag 与 GitHub Release。

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

当前 Freeze baseline 以上方 v3.4 为准。

v3.4 Freeze 生效后：

- P0 / security blocker 可以立即修复；
- 非 P0 friction / ergonomics 只记录，不立即扩 canonical core；
- Router / Controller / Reviewer App / Worker / CLI / stack-specific CI framework 不得借普通修复重新进入 core。

tag / Release 是 GitHub 上的人类发布动作，不由 G-lite runtime 自动生成。

## Provenance

最初从 `qiaoen12/Project-qiaoen` @ `988ba573c8bc8b841539223e547e82f70719f52c`（Freeze UTC `2026-09-09T10:55:57Z`）按 allowlist 抽出。

R0–R5 把 runtime 收缩为 GitHub-native 协议；R5.5 再删掉 workspace / scaffolding / backup / 本地治理；R6 只负责授权语义、adoption contract、最终 Pilot 与版本收口。

历史实现留在 Git history / tag / archived repositories，不留在当前产品树。
