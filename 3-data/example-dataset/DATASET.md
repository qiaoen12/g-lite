---
dataset: example-dataset
producers:
  - pipeline: pipeline/fetch.py，Reddit 官方 API 增量拉取
consumers:
  - 4-know/research/example-topic
primary_consumer: 4-know/research/example-topic
---

# 数据集：example-dataset

> 这是填好的示例，展示每一栏该写到什么颗粒度。建自己的数据集时用 `new data <name>`。
> 名字不带归属前缀，是因为 `example-*` 是全工作区通用的示例约定，不受归属命名规则约束。
> 按 `AGENTS.md` 的规则，本例本该叫 `research-example-topic-reddit`。

## 这是什么

r/LocalLLaMA 板块 2026-03 起的帖子与一级评论，用于追踪开源模型的社区讨论热度。

## 采集

| 项 | 值 |
| --- | --- |
| 来源 | Reddit 官方 API（OAuth app-only） |
| 方式 | `pipeline/fetch.py`，按 `created_utc` 增量拉取 |
| 频率 | 每日 03:00，拉取前 24 小时 |
| 起始 | 2026-03-01 |
| 中断记录 | 2026-05-12 ~ 05-19 触发限流，缺 8 天；2026-07-04 API 变更导致字段缺失，当日已重拉 |

凭据走 `op://Private/reddit-api/client-secret`，不落盘。

## 字段

`_raw/posts/YYYY-MM-DD.jsonl`，一行一个帖子：

| 列名 | 类型 | 单位 | 说明 |
| --- | --- | --- | --- |
| `post_id` | string | — | Reddit 全局 ID，形如 `t3_abc123` |
| `created_utc` | int | 秒 | Unix 时间戳，**不是毫秒** |
| `title` | string | — | 原文，未做任何清洗 |
| `selftext` | string | — | 正文；已删除的帖子此处为 `[deleted]` |
| `score` | int | 票 | 采集当刻的净赞数，**会随时间变化，非最终值** |
| `num_comments` | int | 条 | 同上，采集快照值 |
| `author` | string | — | 用户名；账号注销后为 `[deleted]` |

唯一键：`post_id`

## 已知问题

- `score` 和 `num_comments` 是**采集时刻的快照**，不是最终值。做趋势分析时不能当成稳定量。
- 帖子被删除后 API 仍返回记录，但 `selftext` 变成 `[deleted]`，留下空壳。
- 作者可能改名，历史记录里的 `author` 不保证还能对应到现存账号。
- 2026-05 那 8 天的缺口无法补，见上。

## 可重采性

**不能。** Reddit API 只提供有限的历史窗口，且已删除的帖子无法找回。当前这份 `_raw/` 是唯一副本。

> 这一栏决定备份策略。不能重采 = 必须永久备份、必须只读。

## 保留期

| 目录 | 保留 | 依据 |
| --- | --- | --- |
| `_raw/` | 永久 | 不可重采 |
| `_out/` | 不备份 | `pipeline/build.py` 可从 `_raw/` 完整重建 |

## `_out/` 重建命令

```bash
python pipeline/build.py --from _raw --to _out
```

## 原始数据保护

`_raw/` 是**追加式**的：可以加新批次，不能改已有文件。

```bash
# ① 只锁文件，目录保持可写（否则追加新批次会失败）
find _raw -type f -exec chmod a-w {} +

# ② 每采完一批后固化哈希清单
new data --seal example-dataset
```

审计的 `raw_integrity` 会比对 `_raw/MANIFEST.sha256`：新增放行，已有文件哈希变动或消失即硬失败。

**任何清洗结果一律写 `_out/`，绝不回写 `_raw/`。**
