# 门禁一次性配置

把「文档化的纪律」变成「写入时的拦截」。全部做完约 15 分钟。

**换机 / 重新 clone 之后先跑这一条**，它会体检依赖、把 `new` 装进 PATH、装 hook、建立本机 state、报告适配器状态。核心 setup 不要求 Orca，也不要求仓库落在某个固定本机路径。

```bash
# macOS
brew install pre-commit gitleaks jq yq gh
# Linux/WSL：用发行版包或上游二进制装同一组命令
0-meta/bin/new setup
```

跑完之后，在工作区及其子目录里可以直接调用 `new`（`~/.local/bin` 需在 PATH）。它装的是 `~/.local/bin/new`——从当前目录逐级往上找所属工作区的转发脚本，而不是把某个 clone 的 `0-meta/bin` 写死进 PATH。理由见 [`new-shim.sh`](new-shim.sh) 抬头。下一步：读取 GitHub Issue Contract，确认 `approved`，从最新 main 开普通 branch / worktree。不要调用已删除的 `new task` / `new z`。

下面是它背后各部分的细节，以及它代劳不了的部分。

## 1　SOPS + age（加密必须落盘的配置）

```bash
brew install sops age
mkdir -p ~/.config/sops/age
age-keygen -o ~/.config/sops/age/keys.txt
# 输出的 public key 记下来，私钥另存一份到 1Password
echo 'export SOPS_AGE_KEY_FILE=~/.config/sops/age/keys.txt' >> ~/.zshrc
```

工作区根建 `.sops.yaml`：

```yaml
creation_rules:
  - path_regex: \.enc\.ya?ml$
    age: age1xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx
```

用法：`sops secrets.enc.yaml` 直接编辑，保存自动加密。

## 2　pre-commit（提交时拦截）

规则在仓库里的 `.pre-commit-config.yaml`（已跟踪），hook 装在本机。`new setup` 做的就是后半句：

```bash
pre-commit install --install-hooks
```

**为什么不手写 `.git/hooks/pre-commit`：**`.git/` 不进 git。写死在那里的门禁，换台 Mac 就消失，而「记得再装一次」是纪律，不是门禁。分开之后，规则随仓库走，每台机器只欠一条命令。

**为什么门禁设在 `git commit` 这个口子上：**Cursor、Codex、Claude Code、WorkBuddy、你自己、终端，最后都走同一条 `git commit`，也都指向同一个 `.git`。AI 可以换，编辑器可以换，提交口只有一个。相比之下 `.cursorignore` 只对 Cursor 生效——那是适配器，这是门禁。

**worktree：**hooks 挂在 git common dir 上，全部 worktree 共用同一份，不必逐个安装。

**档位：**hook 跑的是 `new check --tier commit`，只看暂存区。不要换成不带参数的 `new check`——那是 daily 档全树扫描，工作区长到 25 万文件之后每次提交要等十几秒，真实结局是 hook 被关掉。**被关掉的门禁比没有门禁更糟，因为它还在制造安全感。**

### 验一次

**没验证过能拦住的门禁，等于没装。**两条都应当被拒：

```bash
# a. git 卫生：5-record 的档案本体不许进 git
mkdir -p 5-record && echo x > 5-record/gate-test.txt
git add -f 5-record/gate-test.txt && git commit -m "chore(record): 应当被拒"
git reset -- 5-record/gate-test.txt && rm -f 5-record/gate-test.txt

# b. gitleaks：现场生成一把一次性真钥
openssl genrsa 2048 2>/dev/null > leak-test.txt
git add leak-test.txt && git commit -m "chore(repo): 应当被拒"
git reset -- leak-test.txt && rm -f leak-test.txt
```

**b 为什么必须用真钥。**手写一个短样本，比如

```text
-----BEGIN RSA PRIVATE KEY-----
MIIEow
-----END RSA PRIVATE KEY-----
```

gitleaks **不会**报。它的 `private-key` 规则连带熵阈值一起判定，几个字节的假 base64 达不到。同理 `AKIAIOSFODNN7EXAMPLE` 也不会报——那是 AWS 官方示例值，在默认 allowlist 里。

这类样本会让验证「通过」，于是你以为门禁没装好、或者更糟：以为装好了而其实测的是个空。**验证用例本身也要验证。**

### 已知缺口

`git commit --no-verify` 绕过以上全部，`SKIP=gitleaks git commit` 能单独跳过 gitleaks。这不是配置问题，本地补不了——第三道门在服务端：

```text
第一道  编辑器 / Agent   .cursorignore、.claude/settings.json    只对认它的工具生效
第二道  本地 git         pre-commit                              --no-verify 可绕
第三道  GitHub           CI + branch protection                  绕不过
```

第三道等有真实项目、需要 PR 流程时再上。个人单人阶段，前两道够用。

## 3　launchd（每天自动审计）

`~/Library/LaunchAgents/com.g-lite.workspace-audit.plist`：

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
  "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>com.g-lite.workspace-audit</string>
  <key>ProgramArguments</key>
  <array>
    <string>/ABS/PATH/TO/WORKSPACE/0-meta/bin/new</string>
    <string>check</string>
  </array>
  <key>StartCalendarInterval</key>
  <dict><key>Hour</key><integer>9</integer><key>Minute</key><integer>0</integer></dict>
  <key>StandardOutPath</key>
  <string>/ABS/PATH/TO/WORKSPACE/0-meta/audit/_out/daily.log</string>
  <key>StandardErrorPath</key>
  <string>/ABS/PATH/TO/WORKSPACE/0-meta/audit/_out/daily.err</string>
</dict>
</plist>
```

```bash
launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/com.g-lite.workspace-audit.plist
launchctl kickstart -k gui/$(id -u)/com.g-lite.workspace-audit    # 立即跑一次验证
```

## 4　每日冷备（launchd + Keychain）

Bitwarden CLI 在 launchd 里拿不到 session。机器取值走本机 Keychain，只存
restic 仓库口令，不存 Bitwarden 主密码。人恢复仍走离机口令库和纸质。

```bash
cd /path/to/workspace
export BW_SESSION="$(bw unlock --raw)"
2-infra/backup/scripts/install-unattended-password.sh
unset BW_SESSION

mkdir -p ~/Library/LaunchAgents
# edit absolute paths in the plist first
cp 2-infra/backup/launchd/com.g-lite.backup-cold.plist ~/Library/LaunchAgents/
launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/com.g-lite.backup-cold.plist
```

plist 每天 10:15 跑 `--apply`。先确认 `backup-cold.sh --snapshots` 不再问主密码。

## 检查清单

- [ ] `which new` 指向 `~/.local/bin/new`，任意目录可直接调用
- [ ] `sops secrets.enc.yaml` 能加解密
- [ ] age 私钥已另存 1Password
- [ ] pre-commit **实测拦住过一个假密钥**
- [ ] pre-commit **实测拦住过一次 5-record 提交**
- [ ] `.cursorignore` 已就位且被 git 跟踪（`new setup` 会报）
- [ ] launchd 已加载且日志有输出
- [ ] restic 口令在 Bitwarden + 本机 Keychain（仅此一口令）+ 纸质
- [ ] `install-unattended-password.sh` 已跑通，`backup-cold.sh --snapshots` 不再需要 `BW_SESSION`
- [ ] 冷备 launchd 已加载（`com.g-lite.backup-cold`）
- [ ] `0-meta/audit/offline-copy.attestation` 已填日期，文件里没有口令
- [ ] 做过一次异机恢复演练
