# Framework freeze 与提取

操作说明。理由见 [`4-know/decision/framework-freeze.md`](../../4-know/decision/framework-freeze.md)。Allowlist 见 [`11-extract-allowlist.md`](11-extract-allowlist.md)。

## 本仓是什么

`qiaoen12/g-lite` 是 canonical G-lite framework source：development + Issue + PR + Release + Template。

`qiaoen12/g-lite-harness` 是外部测试 / E2E / 故障注入，不是生产依赖。

## Provenance

本仓初始内容从下面这个精确 Freeze SHA 按 allowlist 提取，不是从 Project-qiaoen 漂移后的 main：

```text
qiaoen12/Project-qiaoen
@ 988ba573c8bc8b841539223e547e82f70719f52c
Freeze UTC: 2026-09-09T10:55:57Z
```

```text
Project-qiaoen @ 988ba573c8bc8b841539223e547e82f70719f52c
        ↓
allowlist 提取 framework
        ↓
qiaoen12/g-lite
        ↓
v1.0.0   （人工 squash merge #1 之后，不由 candidate 自己打 tag）
```

## 三个仓库

| 仓库 | 角色 |
| --- | --- |
| `qiaoen12/g-lite` | Canonical framework source。正式 v1.0.0 在这里产生。 |
| `qiaoen12/g-lite-harness` | 外部测试仓。framework candidate 由这里控制。不是生产依赖。 |
| `qiaoen12/Project-qiaoen` | Prototype Freeze source。已停止作为 framework 开发上游。未来将成为 `qiaoen12/g-lite-personal`。现在不改名。 |

## 本仓还允许改什么

在 `v1.0.0` 发布之前，#1 只做提取、泛化、验证。发布后 canonical runtime 至少再冻 15 天。

P0：runtime 不可用、数据丢失、错误 merge / 错误删 ref、credential leak、保护边界失效、合法 business task 被完全堵死。

不是 P0：prompt 长短、CLI 步数、输出格式、Harness 泛化、rename、自动升级、PowerShell、GitLab、merge queue、强 actor 认证。只记录。

P0 也必须：g-lite-harness → vanilla worktree → Draft PR → 独立 Review → STOP → 人工 squash merge。候选 runtime 不得管理自己。

## 30-task 和 15 天

30 个 distinct 已完成 business Issue 是使用量 / 证据强度，不是解冻硬门槛。

`g-lite v1.0.0` 发布后至少再冻 15 天。那是人工 merge #1 并打 tag 之后的事。
