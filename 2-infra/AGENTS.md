# 2-infra — 基础设施声明

## 放什么

描述"机器和服务应该长什么样"的东西：ansible playbook、compose 文件、部署脚本、监控配置、本机环境配置、备份脚本。

## 不放什么

| 不放 | 放哪里 |
| --- | --- |
| **任何明文私钥、token、密码** | 1Password / Keychain。见 [密钥文档](../0-meta/docs/01-密钥.md) |
| 巡检输出、监控数据、日志 | 就地建 `_out/` |
| 历史快照 | 就地建 `_archive/` + `RETENTION.md` |
| 业务代码 | `1-code/` |

## 凭据只允许两种形态

```yaml
# ✗ 绝对不行
api_token: sk-abc123...

# ✓ 形态一：引用（运行时注入）
api_token: op://Private/cloudflare/api-token

# ✓ 形态二：密文（SOPS + age 加密，可安全进 git）
# 文件名必须是 *.enc.yaml
api_token: ENC[AES256_GCM,data:...,type:str]
```

加解密：

```bash
sops -e secrets.yaml > secrets.enc.yaml && rm -P secrets.yaml   # 加密
sops -d secrets.enc.yaml                                        # 查看
sops secrets.enc.yaml                                           # 直接编辑
```

age 私钥放 `~/.config/sops/age/keys.txt`，**不在工作区内**，另存一份到 1Password。

## SSH 怎么办

私钥不放这里，也不放任何地方的磁盘明文。

```bash
ssh-keygen -t ed25519 -C "vps-prod"          # 生成时一定设 passphrase
ssh-add --apple-use-keychain ~/.ssh/vps-prod # 存进 Keychain
```

工作区里只留 `~/.ssh/config` 的主机别名映射说明，和 `.pub` 公钥。

长期目标是改用 SSH CA 签发短期证书（`step-ca`），私钥根本不长期存在，泄露也会自动过期。

## 目录形状

```
2-infra/
├── <host-or-service>/
│   ├── README.md
│   ├── ansible/ | compose/ | scripts/
│   ├── secrets.enc.yaml      ← SOPS 密文
│   ├── _out/                 ← 巡检输出
│   └── _archive/             ← 历史快照 + RETENTION.md
```

## 策略

| 敏感度 | Git | 冷备 | 热同步 | 保留 |
| --- | --- | --- | --- | --- |
| 内部（含密文） | 根 monorepo 跟踪 | 是 | 是 | 永久 |

改基础设施时，如果同时要改对应的代码或数据契约，那本来就是一个逻辑变更——放在同一个分支、同一个提交里，别按目录拆。开工建议 `new worktree <task> --path 2-infra/<host> --path 1-code/<app>`。
