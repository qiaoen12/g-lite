# Machine Bootstrap

Machine Bootstrap 为一台机器准备 Developer 和 Reviewer role entry，通常每台机器配置一次。两个角色必须使用彼此独立的 GitHub App identity，并分别拥有目标仓库的 installation access。它属于机器级前置条件，不属于 repository task 或 repository Genesis/Upgrade。

canonical reference entry 是 `tools/machine-bootstrap/role-exec`。每次调用都会通过机器本地 bootstrap 按需 mint short-lived Installation Access Token，再实时验证 GraphQL Actor 和目标仓库访问。默认 bridge 是 `$HOME/.config/g-lite/bin/app-env.sh`；其他机器可以通过本机环境变量 `G_LITE_APP_ENV` 指向兼容的 bootstrap entry。helper 以 `developer` 或 `reviewer` 作为 bridge 参数；成功时 bridge 必须导出匹配的 `GITHUB_APP_ROLE` 和短期 `GH_TOKEN`（或 `GITHUB_TOKEN`），失败时返回非零。bridge 自己管理本地凭据，可以采用任意 private-key 布局；G-lite 不复制或读取这些凭据。

## 核验角色访问

从包含 helper 的 checkout 执行：

```sh
tools/machine-bootstrap/role-exec developer check --repo OWNER/REPO
tools/machine-bootstrap/role-exec reviewer check --repo OWNER/REPO
```

命令只报告已验证的 role、live Actor、repository 和 access 结果。需要同时使用两个角色时，分别核验并确认 Actor 不同。Actor 或 repository 不匹配时 entry 会停止，也不会回退到 Human Authority 的 `gh` 登录。

## 以角色执行命令

在 `--` 后提供命令。可以明确给出 repository，也可以让 entry 从当前 checkout 的 GitHub HTTPS origin 推导：

```sh
tools/machine-bootstrap/role-exec developer --repo OWNER/REPO -- gh api graphql -f query='query { viewer { login } }' --jq .data.viewer.login
tools/machine-bootstrap/role-exec reviewer --repo OWNER/REPO -- gh pr view 123
```

helper 通过子进程环境中的 `GH_TOKEN` 提供短期 token，不保存 token。调用者应只传入可信命令，因为命令可以使用所选 App 的权限。Installation Access Token 可能不能访问 REST `/user`；helper 用 GraphQL `viewer.login` 验证 Actor。

Developer Git 命令会禁用 system/global Git 配置，只允许 HTTPS，并使用隔离的临时 credential 环境。entry 会拒绝被 local rewrite 改成其他传输方式的 origin。它不修改全局 Git 配置或 Human Authority 的 `gh auth`。Reviewer 命令不会收到 Git HTTPS askpass 凭据。

## 在另一台机器部署或更新

1. 由 Human Authority 按目标仓库的治理流程安装或授权独立的 Developer、Reviewer App。
2. 机器所有者使用本机安全机制分别配置两个角色的 bootstrap entry。它应按需 mint token，只将角色和短期 token 提供给调用者，不把 token 写入磁盘或日志。
3. 直接使用 canonical checkout 中的 `tools/machine-bootstrap/role-exec`；无需预先安装同名 CLI，也无需复制现有机器的秘密。
4. 对两个 App 都已安装的仓库分别执行 `check`，确认预期 Actor 与角色独立后再使用。
5. App 轮换或重新配置后重新执行检查。不得在机器间复制 private key、JWT、Installation Access Token 或 PAT。

机器 bootstrap 实现和凭据布局留在本机。不要把秘密、机器专属凭据路径、token cache、daemon、identity registry 或 repository task state 加入 G-lite。`tools/repo-reconciler/` 不 mint 或消费凭据。
