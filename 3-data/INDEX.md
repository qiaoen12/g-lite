# 3-data 索引

由 `new data --index` 生成，**不要手改**。事实源是各个 `DATASET.md` 的 frontmatter。

`new check` 会重新渲染一遍并与本文件逐字节比较，改了声明没重算、或手改过本文件，都会报出来。

## 从项目找数据

「我在做 X，需要哪份数据」——绝大多数查询是这个方向，所以放在最前面。

| 应用端 | 数据集 |
| --- | --- |
| 4-know/research/example-topic | `example-dataset` |

## 从采集端找数据

同一个采集器产出多份数据时，这张表能看出它的全部产出。

| 采集端 | 类型 | 数据集 |
| --- | --- | --- |
| pipeline/fetch.py，Reddit 官方 API 增量拉取 | pipeline | `example-dataset` |

## 全部数据集

| 数据集 | 主应用端 | 采集端 | 应用端 |
| --- | --- | --: | --: |
| `example-dataset` | 4-know/research/example-topic | 1 | 1 |
