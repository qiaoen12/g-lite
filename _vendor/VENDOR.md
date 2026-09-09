# 第三方代码登记

这个域**零备份、零同步、随时可删**——前提是每一项都能靠下表**精确**重新获取。

`new vendor <git-url>` 会自动 clone、记录当前 commit 并追加一行。**「留存理由」必须手工补**，否则半年后你不敢删它。

| 目录 | 上游 | commit | tag | 获取日期 | 许可证 | 留存理由 |
| --- | --- | --- | --- | --- | --- | --- |
| `_example` | https://github.com/foo/bar | `9c2ad83` | `v1.4.0` | 2026-08-26 | MIT | 示例行，可删 |

## 为什么必须记 commit

`git clone <url>` 今天和两年后拿到的可能是完全不同的代码。**「重新下载一个同名的新版本」不等于「恢复同一个依赖」。**

恢复时：

```bash
git clone https://github.com/foo/bar && cd bar && git checkout 9c2ad83
```

## 但记了 commit 也不够

SHA 解决的是「拿到的是不是同一份」，解决不了「还拿不拿得到」——上游删库、转私有、force push 之后，SHA 同样失效。

所以判定标准是一句话：

> **如果上游消失会让你痛，它就不属于 `_vendor`。**

| 情况 | 落点 |
| --- | --- |
| 只是 clone 下来读读源码 | `_vendor/` ✓ |
| 你的项目构建时依赖它 | fork 到 `1-code/`，或用包管理器 + 锁文件 |
| 冷门项目、作者已弃坑、上游随时可能消失 | `3-data/<name>/_raw/` 存一份 tarball |
| 你已经改出了有价值的东西 | fork 后搬 `1-code/`（见下） |

`_vendor` 的零备份策略，只对「丢了再下一个就行」的东西成立。给不出这个判断的，就不该放这里。

## 什么时候该搬去 1-code

```bash
cd _vendor/<repo>
git log --author="$(git config user.email)" --oneline | wc -l
```

结果 > 0 且改动有价值 → fork 出自己的 remote，搬到 `1-code/`。

**注意区分「未推送提交数」和「自有提交数」。**前者可能只是 fetch 状态错位，全是上游作者的提交，不代表你做过任何事。

## 定期清理

```bash
du -sh */ | sort -h | tail -10
```

超过半年没打开、理由已不成立的直接删，需要时按上表 clone + checkout 还原。
