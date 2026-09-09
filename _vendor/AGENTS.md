# _vendor — 第三方代码

## 放什么

从别人那里 clone 来的、你没有做实质改造的代码。

## 判定规则

```bash
cd <repo> && git log --author="$(git config user.email)" --oneline | wc -l
```

| 自有提交数 | 归属 |
| --- | --- |
| 0 | `_vendor/`，可随时删除重 clone |
| ≥1，且改动有价值 | `1-code/`，**并且必须 fork 出自己的 remote** |

注意区分「未推送提交数」和「自有提交数」。前者可能只是 fetch 状态错位，全是上游作者的提交，不代表你做过任何事。

## 铁律：登记 VENDOR.md

```bash
new vendor https://github.com/foo/bar
```

会自动 clone 并追加一行到 `VENDOR.md`。手动加也行，但必须记录 **上游 URL + clone 命令 + 留着它的理由**。

有了这行记录，这个域才敢定为「零备份、随时可删」。

## 策略

| 敏感度 | Git | 冷备 | 热同步 | 保留 |
| --- | --- | --- | --- | --- |
| 公开 | 上游远端 | 否 | 否 | 随时可弃 |

**这个域完全不占备份空间。**依赖目录（`node_modules` `.venv`）也一并不备份。

## 定期清理

```bash
du -sh */ | sort -h | tail -10        # 看谁最占地方
```

超过半年没打开、`VENDOR.md` 里理由已经不成立的，直接删。需要时按记录重新 clone。
