# agent-card 与 canonical start card

本页保留设计 rationale；开工时只需使用任务输出的 canonical start card 和目标目录的 agent-card。

## 为什么先给卡片

`new task claim` 与 `new z dev` 直接输出同一结构的 start card：Issue、`origin/main` 上的 Contract blob、worktree、branch、derived state、允许范围、HEAD 和下一条 canonical 命令。卡片是产品无关的事实包，Grok、Codex 等 adapter 只在卡片外追加自己的机械 trigger。它不要求 Agent 先完整阅读 07/08 或全部 policy；机器可判定的规则仍由 canonical CLI 执行。

`Next canonical command` 按阶段取值：开工门禁刚通过、#13 `changed` completion 尚未成立时是 `continue development`，不是 Review。干净且 ahead=0 的树是尚未开发，不是已声明的 no-change。明确 no-change 是 #13 Checkpoint / completion 结论，start card 不会从 ahead=0 推断。只有 `changed` completion 成立时，下一步才是 `new z review <review-input>`。launcher / start card / Agent 退出码 0 都不表示开发完成。`new task grok|codex` 在卡片外追加 Developer execution handoff，要求 Agent 读取 Contract 并实际开发。

`loaded_bytes` 只量卡片本体，以及卡片明确要求强制加载的文件。后续按需阅读的 docs、Review 输入和实现文件不进入这个指标。这样指标回答的是「开工最低加载量」，而不是「整个任务最终读了多少」。

## 为什么分层

根与 `0-meta/` 的 `agent-card` 只保留机器无法替代的硬边界、落点判断和交付命令。权限、策略演进、Git 细节、Contract 格式和历史取舍分别留在 06/07/08 与决策索引；需要时按链接读取，不把 rationale 伪装成开工门禁。

## 为什么 Skill 要薄

Skill 是入口说明，不是第二套 runtime。每张核心 Skill 只说明何时用、调用哪个 `new z` canonical CLI、如何把结果返回用户；claim、scope、Review、validator、merge 和 actor 语义只在共享实现中维护。普通 shell 即使不读取 Skill，也可直接调用同一 canonical CLI。

## 预算门禁

`prompt_budget` 在 `policy.yaml` 声明根/局部 AGENTS、agent-card、start card、Skill 字节与行数、`z-workflow` 的上限；`new plan --apply` 将规则写入 `derived.lock`，`new check --tier commit` 实测并在超限时指出对象。预算是防回归门禁，不以删除必要安全边界为代价。

本任务不改变 Contract、claim、derive、Review、merge、Guard 或 #42 metrics 的业务语义。

## Developer/Fixer 完成态

开发与修复共用 canonical completion gate。只有最终待审实现已经进入明确 Git HEAD，且 `untracked=0`、`unstaged=0`、`staged=0`，才能报告「开发完成」「修复完成」或 `review-ready`。`git add`、index.lock、宿主权限或 `git commit` 等持久化步骤失败时必须报告「未完成 / BLOCKED」，不得以 working tree 内容或 commit-tier PASS 代替；合法 no-change 必须明确写出 `no-change` 并保持 clean。Reviewer 只读固定 clean HEAD。
