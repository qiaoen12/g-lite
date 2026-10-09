# g-lite

GitHub-native AI 协作协议：GitHub 管事实和门，Agent 干活，G-lite 只规定任务分级、确认点和结果汇报。

规则只写在 [AGENTS.md](AGENTS.md) 开头的 managed block 中；本文件只做简介和入口，不复述规则。

## 流程

- **常规**（采集、查询、诊断、调研、开发、分支与预览改动）：用户一句话 → Agent 完成 → 结果汇报，涉及开发时附改动摘要。
- **上线**（合入 default branch、生产部署、凭据、删数据、权限或治理）：Agent 在分支完成并开 PR → CI 通过 → 用户确认当前 HEAD → 中枢合并或部署 → 结果汇报另写合并、部署和回退。

删掉本仓库任何一个工具后，这条流程仍然完整。

## 内容

| 路径 | 作用 |
| --- | --- |
| `AGENTS.md` | 协议 managed block + 本仓库专有说明 |
| `.github/ISSUE_TEMPLATE/task.md`、`.github/pull_request_template.md` | 与 consumer 共用的模板 |
| `tools/machine-bootstrap/` | Developer role entry，部署见 [docs/machine-bootstrap.md](docs/machine-bootstrap.md) |
| `tools/repo-reconciler/` | 无状态治理工具：审计和收敛 Ruleset、仓库设置，同步协议文件 |
| `tests/run.sh` | 本仓库验证入口，CI `pr-gate` 只调用它 |

## 采用

1. 对 consumer checkout 运行 `tools/repo-reconciler/reconcile.sh protocol-sync --checkout DIR --write`，同步 `AGENTS.md` managed block 和两个模板；它只改本地文件。
2. 可用 Ruleset 的仓库，由 Human Authority 依次执行 `bootstrap`、等真实 CI 成功、`activate --required-check NAME --check-sha SHA`，之后用 `audit` 检查偏差。
3. 不可用 Ruleset 的仓库，按 `AGENTS.md`「GitHub 门」由中枢持有合并与部署凭据。

## 版本

协议版本以 managed block 第二行的版本声明和 Git tag 为准。旧版本的规则与证据见对应 tag，例如 `v3.7.4`。
