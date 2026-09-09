# 本机 setup：依赖、PATH 入口、hook、local state、适配器状态。
# 由 0-meta/bin/new 加载，不要单独执行。

# ─────────────────────────────────────────────── setup
#
# 一条命令把本机装成「能被门禁管住」的状态。存在的理由是可复现：
# .git/hooks/ 不进 git，所以规则可以随仓库走，hook 不行。
# 换机 / 重新 clone 之后必须再跑一次——这是 git 的固有限制，
# 能做的只是把「再跑一次」压缩成一条命令，而不是一页文档。
#
# 核心 setup 不要求 Orca，也不要求本机绝对路径。
# launchd / 冷备是本机 adapter，缺了只警告。

setup_install_hint() {
  case "$(uname -s)" in
    Darwin) printf '      brew install%s\n' "$1" ;;
    Linux)  printf '      安装%s（apt/dnf/pacman 或上游二进制）\n' "$1" ;;
    *)      printf '      安装%s\n' "$1" ;;
  esac
}

setup_ensure_state_dir() {
  local file dir
  file="$(metrics_file)"
  dir="$(dirname "$file")"
  mkdir -p "$dir" \
    || { c_err "    ✗ 无法创建本机 state ${dir}"; return 1; }
  c_ok "    ✓ 本机 state ${dir}"
}

cmd_setup() {
  local fail=0

  echo "── 1. 依赖 ──────────────────────────────"
  local missing=""
  local t
  for t in git jq gh pre-commit gitleaks; do
    if command -v "$t" >/dev/null 2>&1; then c_ok "    ✓ $t"
    else c_err "    ✗ 缺 $t"; missing="$missing $t"; fi
  done
  if command -v yq >/dev/null 2>&1 || command -v ruby >/dev/null 2>&1 \
     || python3 -c 'import yaml' >/dev/null 2>&1; then
    c_ok "    ✓ YAML 解析器"
  else
    c_err "    ✗ 缺 YAML 解析器（derive-paths.sh 要用）"; missing="$missing yq"
  fi
  if [ -n "$missing" ]; then setup_install_hint "$missing"; fail=1; fi

  echo "── 2. new 的 PATH 入口 ──────────────────"
  # PATH 是机器本地的，进不了 git。换机或重新 clone 之后一定要再装一次，
  # 所以这里既装也查漂移——装的是一个转发脚本而不是把 0-meta/bin 塞进 PATH，
  # 理由写在 templates/new-shim.sh 的抬头。
  local shim_src="$ROOT/0-meta/templates/new-shim.sh"
  local shim_dst="$HOME/.local/bin/new"
  mkdir -p "$(dirname "$shim_dst")"
  if [ ! -f "$shim_src" ]; then
    c_err "    ✗ 缺 $shim_src"; fail=1
  elif [ ! -e "$shim_dst" ] || ! cmp -s "$shim_src" "$shim_dst"; then
    if install -m 755 "$shim_src" "$shim_dst" 2>/dev/null; then
      c_ok "    ✓ 已装/更新 $shim_dst"
    else
      c_err "    ✗ 写不了 $shim_dst"; fail=1
    fi
  else
    c_ok "    ✓ $shim_dst 就位且与仓库一致"
  fi
  local resolved; resolved="$(command -v new 2>/dev/null || true)"
  if [ -z "$resolved" ]; then
    c_warn "      ⚠ 但 shell 里还找不到 new —— ~/.local/bin 不在 PATH。加进 shell rc："
    echo '          export PATH="$HOME/.local/bin:$PATH"'
  elif [ "$resolved" != "$shim_dst" ]; then
    c_warn "      ⚠ 但 PATH 里先命中的是 ${resolved}"
  fi

  echo "── 3. pre-commit hook ───────────────────"
  if ! in_repo; then
    c_err "    ✗ 还不是 git 仓库，无处安装"; fail=1
  elif [ ! -f "$ROOT/.pre-commit-config.yaml" ]; then
    c_err "    ✗ 缺 .pre-commit-config.yaml —— 规则本身应该进 git"; fail=1
  elif ! command -v pre-commit >/dev/null 2>&1; then
    c_err "    ✗ pre-commit 未安装，跳过"; fail=1
  else
    if (cd "$ROOT" && pre-commit install --install-hooks) >/dev/null 2>&1; then
      # 只看 install 的退出码是不够的：它对「配置里没声明的钩子类型」
      # 同样返回 0，于是 commit-msg 会「装了但根本没这个文件」。
      local hd; hd="$(git -C "$ROOT" rev-parse --git-common-dir)"
      case "$hd" in /*) ;; *) hd="$ROOT/${hd#./}" ;; esac
      local miss="" h
      for h in pre-commit commit-msg; do
        [ -x "$hd/hooks/$h" ] || miss="$miss $h"
      done
      if [ -n "$miss" ]; then
        c_err "    ✗ install 返回成功，但这些钩子没落地：${miss# }"
        c_err "      检查 .pre-commit-config.yaml 的 default_install_hook_types"
        fail=1
      else
        c_ok "    ✓ pre-commit 与 commit-msg 都已装到 ${hd}/hooks/"
        echo "      全部 worktree 共用这一份，不用逐个装。"
      fi
    else
      c_err "    ✗ pre-commit install 失败，手动跑一次看报错"; fail=1
    fi
  fi

  echo "── 4. 本机 state ────────────────────────"
  setup_ensure_state_dir || fail=1

  echo "── 5. 适配器状态 ────────────────────────"
  if command -v orca >/dev/null 2>&1; then
    c_ok "    ✓ orca 在 PATH（可选 adapter，核心路径不依赖）"
  else
    c_ok "    ✓ 未安装 orca（核心 setup 不要求）"
  fi
  if [ -f "$ROOT/.cursorignore" ]; then
    c_ok "    ✓ .cursorignore 已就位"
    git -C "$ROOT" ls-files --error-unmatch .cursorignore >/dev/null 2>&1 \
      || c_warn "      ⚠ 但未被 git 跟踪 —— worktree 里不会出现它。跑：git add .cursorignore"
  else
    # 这一条 setup 帮不上忙：Cursor 禁止 agent 写自己的访问控制文件。
    c_warn "    ⚠ 缺 .cursorignore —— Cursor 不允许 agent 写它，只能你自己跑："
    echo "        cp 0-meta/templates/cursorignore.tpl .cursorignore"
    echo "        git check-ignore -v .cursorignore   # 无输出就直接 git add，不需要 -f"
  fi
  # 固定 Agent 配置是 adapter：缺了只警告。装了某 Agent 但配置坏了的
  # strict fail 属于 adapter-specific doctor，不进 canonical setup 成功条件。
  local f
  for f in .aiignore .claude/settings.json; do
    if [ -f "$ROOT/$f" ]; then
      c_ok "    ✓ ${f}（可选 adapter）"
    else
      c_warn "    ⚠ 缺 ${f}（可选 adapter，核心 setup 不要求）"
    fi
  done

  echo "── 6. 本机调度（可选 adapter）───────────"
  case "$(uname -s)" in
    Darwin)
      local plist="$HOME/Library/LaunchAgents/com.qiaoen.workspace-audit.plist"
      if launchctl list 2>/dev/null | grep -q workspace-audit; then
        c_ok "    ✓ 每日审计已加载"
      elif [ -f "$plist" ]; then
        c_warn "    ⚠ plist 存在但未加载：launchctl bootstrap gui/$(id -u) $plist"
      else
        c_warn "    ⚠ 未配置每日审计 —— 见 0-meta/templates/setup-guardrails.md 第 3 节"
      fi
      local bplist="$HOME/Library/LaunchAgents/com.g-lite.backup-cold.plist"
      local srcplist="$ROOT/2-infra/backup/launchd/com.g-lite.backup-cold.plist"
      if [ ! -f "$srcplist" ]; then
        c_ok "    ✓ 本 clone 无冷备脚本，跳过（非核心 setup）"
      elif launchctl list 2>/dev/null | grep -q g-lite.backup-cold; then
        c_ok "    ✓ 冷备调度已加载"
      elif [ -f "$bplist" ]; then
        c_warn "    ⚠ plist 在 LaunchAgents 但未加载："
        echo "        launchctl bootstrap gui/$(id -u) $bplist"
      else
        c_warn "    ⚠ 冷备调度未安装。先装 Keychain 口令，再："
        echo "        2-infra/backup/scripts/install-unattended-password.sh"
        echo "        cp $srcplist $bplist"
        echo "        launchctl bootstrap gui/$(id -u) $bplist"
      fi
      ;;
    *)
      c_ok "    ✓ 非 Darwin：跳过 launchd（核心 setup 不要求）"
      ;;
  esac

  echo
  echo "── 验一次 ───────────────────────────────"
  echo "  没验证过能拦住的门禁，等于没装。这两条都应该被拒："
  echo
  echo "    mkdir -p 5-record && echo x > 5-record/gate-test.txt"
  echo "    git add -f 5-record/gate-test.txt && git commit -m 'chore(record): 应当被拒'"
  echo "    git reset -- 5-record/gate-test.txt && rm -f 5-record/gate-test.txt"
  echo
  # 必须现场生成真钥。手写的短样本达不到 gitleaks 的熵阈值，会假装通过；
  # AKIAIOSFODNN7EXAMPLE 同理，它在默认 allowlist 里。
  echo "    openssl genrsa 2048 2>/dev/null > leak-test.txt"
  echo "    git add leak-test.txt && git commit -m 'chore(repo): 应当被拒'"
  echo "    git reset -- leak-test.txt && rm -f leak-test.txt"
  echo
  echo "  提交语言这层单独验，不用真的提交："
  echo
  echo "    echo 'update: 随便改改' > /tmp/m && 0-meta/audit/scripts/check-commit-msg.sh /tmp/m"
  echo
  echo "  核心入口：在任务 worktree 里"
  echo "    new task bind <n> && new task && new z dev"
  echo
  c_warn "  已知缺口：git commit --no-verify 绕过以上全部。"
  echo "  本地补不了这个洞。提交语言那层由 daily 档回扫事后发现（自查 commit_convention），"
  echo "  密钥与 git 卫生那层只能靠服务端（GitHub branch protection + CI）。"

  [ "$fail" = 0 ] || return 1
}
