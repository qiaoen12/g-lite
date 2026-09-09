---
id: research-example-topic
type: note
status: draft
topic: [research-method]
created: 2026-08-26
review: 2027-02-26
---

# 调研：example-topic

> 这是填好的示例，展示 PRISMA 轻量版怎么用。建自己的专题用 `new research <topic>`。

## 要回答的问题

开源 LLM 的评测基准中，哪些在 2025 年后仍被广泛引用且未被污染？

问题要具体到**能判断"答完了没有"**。「了解一下 LLM 评测」不是一个可结束的问题，上面这个是。

## 纳入标准

**先写标准再检索。事后定标准 = 给已有结论找理由。**

- 2024-01 之后发表或有重大修订
- 明确说明了数据来源与去污染方法
- 有至少 3 个独立团队的复现结果
- 英文或中文

## 排除标准

- 只有单一机构自评、无第三方复现
- 测试集完全公开且未做污染检测
- 纯综述、无原始评测数据
- 预印本超过 18 个月仍未同行评议

## 检索计划

| 库 / 源 | 检索式 |
| --- | --- |
| Semantic Scholar API | `("LLM benchmark" OR "evaluation suite") AND contamination` |
| OpenAlex | 同上，限 2024- |
| arXiv cs.CL | `benchmark contamination` |
| 引文图谱 | 以 3 篇种子文献做 Connected Papers 展开 |

> 关键词检索会漏。**引文图谱的召回率高得多**——先用关键词找 2~3 篇确定相关的种子，再顺着引用网络扩展。

## 筛选记录

见 `screening.csv`。每次检索都要记一行，包括命中数和排除数——这是「覆盖面可复核」的全部依据。

## 结论

<调研完成后回填。写清：最终纳入几篇、主要发现、置信度、还有哪些没覆盖到>
