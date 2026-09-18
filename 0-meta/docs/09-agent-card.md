# agent-card 与工作台

本页说明根目录与 `0-meta/` 的 `AGENTS.md` 里 `<!-- BEGIN agent-card -->` 块。开工时读最近的 agent-card 和当前 GitHub Issue Contract，不要再调用已删除的 `new task claim` / `new z dev` start card。

## 为什么先给卡片

agent-card 只保留机器无法替代的硬边界、落点判断和交付步骤。权限、策略演进、Git 细节和历史取舍分别留在 06/07/08 与决策索引；需要时按链接读取。

GitHub Issue Contract 与 `approved` 是任务授权。卡片不复制 Contract，也不保存 Review / merge 状态。

## 为什么分层

根与 `0-meta/` 的 agent-card 必须短。`new check --tier commit` 按 `policy.yaml` 的 `prompt_budget` 测量 `AGENTS.md` 与 agent-card 块；超限指出对象并失败。

## 工作台可替换

Codex / Cursor / Claude Code / Grok / WorkBuddy 只是工作台。它们不构成第二套 runtime，也不替代 GitHub 上的 PR、Checks、Review 与 squash merge。

开发不需要安装旧 z* Skills 或 `new task`。

## 历史

R4 之前，`new task claim` 与 `new z` 会打印 canonical start card，并把 Skill 当作 `new z` 的 thin adapter。那条产品链已删除。不要重建 replacement start-card runtime。
