---
id: example-source
type: source
source: https://example.com/some-article
status: active
topic: [research-method, knowledge-management]
confidence: medium
created: 2026-08-26
review: 2027-02-26
---

# 外部资料摘录长这样

> 这是填好的示例。建自己的用 `new source <slug>`。

## 为什么每个字段都得填

| 字段 | 半年后它替你回答的问题 |
| --- | --- |
| `id` | 我在别处引用过这篇，链接还在吗（在，`id` 永不改） |
| `source` | 这段话到底是谁说的 |
| `confidence` | 我当时是验证过，还是只是看到有人这么说 |
| `topic` | 从「知识管理」这个角度找，能不能找到它（能，多值标签） |
| `review` | 这个结论现在还成立吗 |

## 摘录

> 原文引用放这里，用引用块和原文措辞，不要改写。改写会丢失后续核对的能力。

## 我的判断

摘录和判断要分开写。混在一起，三个月后你分不清哪句是作者说的、哪句是自己想的。

## confidence 怎么定

| 值 | 什么情况 |
| --- | --- |
| `high` | 一手材料，或自己动手验证过 |
| `medium` | 可信来源，但没亲自验证 |
| `low` | 道听途说、二手转述、待查证 |

`low` 的东西照样值得记——**记下来并标记为待查证，比不记好，也比记下来当成事实好。**
