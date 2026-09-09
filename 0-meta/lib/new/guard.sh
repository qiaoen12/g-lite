# Git Guard：本机 staging bare 与 worktree 接线。
# 由 0-meta/bin/new 加载。hooks 本体在 2-infra/git-guard/。

guard_src_dir() {
  printf '%s' "$ROOT/2-infra/git-guard"
}

guard_staging_git() {
  printf '%s/%s/git-guard/staging.git\n' \
    "${XDG_STATE_HOME:-$HOME/.local/state}" "$(metrics_identity_dir)"
}

guard_install_hooks() {
  local staging="$1" src
  src="$(guard_src_dir)"
  [ -f "$src/pre-receive.sh" ] && [ -f "$src/post-receive.sh" ] \
    && [ -f "$src/receive-pack.sh" ] && [ -f "$src/lib.sh" ] && [ -f "$src/validate.sh" ] \
    || { err_code guard.missing_src "    ✗ 缺 2-infra/git-guard 脚本"; return 1; }
  mkdir -p "$staging/hooks"
  cp "$src/lib.sh" "$staging/hooks/git-guard-lib.sh"
  cp "$src/pre-receive.sh" "$staging/hooks/pre-receive"
  cp "$src/post-receive.sh" "$staging/hooks/post-receive"
  cp "$src/receive-pack.sh" "$staging/hooks/guard-receive-pack"
  cp "$src/validate.sh" "$staging/hooks/guard-validate.sh"
  cp "$ROOT/0-meta/lib/new/task-paths.sh" "$staging/hooks/task-paths.sh"
  cp "$ROOT/0-meta/audit/scripts/check-commit-msg.sh" "$staging/hooks/check-commit-msg.sh"
  chmod 755 "$staging/hooks/pre-receive" "$staging/hooks/post-receive" \
    "$staging/hooks/guard-receive-pack"
}

cmd_guard_install() {
  local wt="${ROOT:-.}" staging fetch
  fetch="$(task_origin_fetch_url "$wt")"
  [ -n "$fetch" ] || die_code guard.no_origin "没有 origin fetch URL，无法建立 staging"
  staging="$(guard_staging_git)"
  mkdir -p "$(dirname "$staging")"
  if [ ! -d "$staging" ]; then
    git init --bare -b main "$staging" >/dev/null \
      || die_code guard.install_failed "无法创建 staging ${staging}"
  fi
  git --git-dir="$staging" config receive.denyNonFastForwards false
  git --git-dir="$staging" config receive.denyDeletes false
  git --git-dir="$staging" config git-guard.main "$(default_branch)"
  if git --git-dir="$staging" remote get-url github >/dev/null 2>&1; then
    git --git-dir="$staging" remote set-url github "$fetch" \
      || die_code guard.install_failed "无法设置 github remote"
  else
    git --git-dir="$staging" remote add github "$fetch" \
      || die_code guard.install_failed "无法添加 github remote"
  fi
  guard_install_hooks "$staging" || return 1
  if ! GIT_TERMINAL_PROMPT=0 git --git-dir="$staging" fetch --prune --no-tags --quiet \
      github '+refs/heads/*:refs/heads/*'; then
    die_code guard.mirror_failed "无法从 GitHub 做初始镜像"
  fi
  GIT_TERMINAL_PROMPT=0 git --git-dir="$staging" fetch --prune --no-tags --quiet \
    github '+refs/heads/*:refs/guard/github/heads/*' 2>/dev/null || true
  c_ok "    ✓ staging ${staging}"
  echo "      github ${fetch}"
  echo "      主工作区不接线。任务 worktree：new task bind 后 push 走 staging。"
}

cmd_guard_status() {
  local staging fetch github_url st
  staging="$(guard_staging_git)"
  if [ ! -d "$staging" ]; then
    echo "未安装。跑：new guard install"
    return 0
  fi
  github_url="$(git --git-dir="$staging" remote get-url github 2>/dev/null || true)"
  fetch="$(task_origin_fetch_url "${ROOT:-.}")"
  echo "staging  ${staging}"
  echo "github   ${github_url:-（无）}"
  echo "origin fetch ${fetch:-（无）}"
  st="$staging/git-guard"
  . "$staging/hooks/git-guard-lib.sh"
  GIT_DIR="$staging"
  export GIT_DIR
  if ! guard_lock_acquire "$st"; then
    c_warn "    ⚠ 无法取得 Guard 互斥，无法读取一致状态"
    return 0
  fi
  if guard_snapshot_github "$staging" \
       && guard_main_in_sync "$staging" "$(default_branch)"; then
    c_ok "    ✓ GitHub main 与 staging 同步"
  else
    c_warn "    ⚠ 未同步或镜像失败。跑：new guard sync"
  fi
  guard_report_forward_failures "$st" || true
  guard_lock_release "$st"
}

cmd_guard_sync() {
  local staging st tx status failed=0 had_failure=0
  staging="$(guard_staging_git)"
  [ -d "$staging" ] || die_code guard.not_installed "未安装 staging。先 new guard install"
  st="$staging/git-guard"
  . "$staging/hooks/git-guard-lib.sh"
  GIT_DIR="$staging"
  export GIT_DIR
  guard_lock_acquire "$st" || die_code guard.locked "无法取得 Guard 互斥"

  # 先只刷新 snapshot namespace；失败 transaction 的 plan 已固化 old-oid，
  # 不因本次刷新而改 lease，也不覆盖 staging 中尚待重试的 tip。
  if ! GIT_TERMINAL_PROMPT=0 git --git-dir="$staging" fetch --prune --no-tags --quiet \
      github '+refs/heads/*:refs/guard/github/heads/*'; then
    guard_lock_release "$st"
    die_code guard.mirror_failed "同步 GitHub snapshot 失败"
  fi

  for tx in "$st/transactions"/*; do
    [ -d "$tx" ] || continue
    status="$(cat "$(guard_txn_file "$tx" forward-status)" 2>/dev/null || true)"
    [ "$status" = fail ] || continue
    had_failure=1
    if guard_forward_plan "$staging" "$tx"; then
      c_ok "    ✓ 已按原 lease 重试 txn=$(basename "$tx")"
    else
      failed=1
      c_warn "    ⚠ txn=$(basename "$tx") 重试仍失败；保留原 lease"
    fi
  done

  if [ "$failed" -ne 0 ]; then
    guard_report_forward_failures "$st"
    guard_lock_release "$st"
    return 1
  fi

  # 没有失败项，或失败项已全部恢复，才把 GitHub 世界镜像到 staging refs。
  if ! GIT_TERMINAL_PROMPT=0 git --git-dir="$staging" fetch --prune --no-tags --quiet \
      github '+refs/heads/*:refs/heads/*'; then
    guard_lock_release "$st"
    die_code guard.mirror_failed "同步 GitHub → staging 失败"
  fi
  guard_lock_release "$st"
  if [ "$had_failure" -ne 0 ]; then
    c_ok "    ✓ forwarding failure 已按原 lease 恢复，并同步 GitHub refs"
  else
    c_ok "    ✓ 已把 GitHub refs/heads 镜像进 staging（不改 GitHub）"
  fi
}

# 任务 worktree 接线。主工作区 no-op。未 install 则跳过（不破坏未装 Guard 的夹具）。
guard_wire_worktree() {
  local wt="$1" staging fetch push now_claim
  [ -n "$wt" ] || return 1
  if task_is_main_worktree "$wt"; then
    return 0
  fi
  staging="$(guard_staging_git)"
  [ -d "$staging" ] || return 0
  fetch="$(task_origin_fetch_url "$wt")"
  [ -n "$fetch" ] || { err_code guard.no_origin "    ✗ 没有 origin fetch URL"; return 1; }
  case "$fetch" in
    "$staging"|file://"$staging")
      err_code guard.fetch_is_staging "    ✗ origin fetch URL 已经是 staging，拒绝"; return 1 ;;
  esac
  git -C "$wt" remote set-url --push origin "$staging" \
    || { err_code guard.wire_push "    ✗ 无法把 origin push URL 设为 staging"; return 1; }
  git -C "$wt" config remote.origin.receivepack "$staging/hooks/guard-receive-pack" \
    || { err_code guard.wire_push "    ✗ 无法设置 origin receivepack wrapper"; return 1; }
  task_ensure_claim_remote "$wt" || return 1
  push="$(git -C "$wt" remote get-url --push origin 2>/dev/null || true)"
  now_claim="$(git -C "$wt" remote get-url claim 2>/dev/null || true)"
  if [ "$push" != "$staging" ]; then
    err_code guard.wire_push "    ✗ origin push URL 不是 staging"; return 1
  fi
  if [ "$now_claim" != "$fetch" ]; then
    err_code guard.wire_claim "    ✗ claim remote 必须等于 origin fetch URL"; return 1
  fi
  return 0
}

guard_require_wired() {
  local wt="$1" staging fetch push now_claim rp
  if task_is_main_worktree "$wt"; then
    return 0
  fi
  staging="$(guard_staging_git)"
  [ -d "$staging" ] || return 0
  fetch="$(task_origin_fetch_url "$wt")"
  push="$(git -C "$wt" remote get-url --push origin 2>/dev/null || true)"
  now_claim="$(git -C "$wt" remote get-url claim 2>/dev/null || true)"
  if [ "$push" != "$staging" ]; then
    err_code guard.not_wired "    ✗ origin push URL 必须是 staging，不得直达 GitHub"
    echo "      修复：new task bind <n>   # 或 git remote set-url --push origin ${staging}"
    return 1
  fi
  if [ -z "$fetch" ] || [ "$fetch" = "$staging" ]; then
    err_code guard.fetch_is_staging "    ✗ origin fetch URL 必须是 GitHub"
    return 1
  fi
  if [ "$now_claim" != "$fetch" ]; then
    err_code guard.wire_claim "    ✗ claim remote 必须等于 origin fetch URL"
    return 1
  fi
  rp="$(git -C "$wt" config --get remote.origin.receivepack 2>/dev/null || true)"
  if [ "$rp" != "$staging/hooks/guard-receive-pack" ]; then
    err_code guard.not_wired "    ✗ origin receivepack 必须是 guard wrapper"
    return 1
  fi
  return 0
}

cmd_guard() {
  case "${1:-}" in
    install) [ $# -eq 1 ] || die_code task.usage "用法：new guard install"; cmd_guard_install ;;
    status)  [ $# -eq 1 ] || die_code task.usage "用法：new guard status"; cmd_guard_status ;;
    sync)    [ $# -eq 1 ] || die_code task.usage "用法：new guard sync"; cmd_guard_sync ;;
    -h|--help|help|"")
      cat <<'EOF'
用法：new guard install|status|sync

  new guard install   按 origin 身份建立本机 staging bare 与 receive-pack wrapper
  new guard status    查看 staging / GitHub 同步及每条 forwarding failure
  new guard sync      按原 lease 重试失败转发，再镜像 GitHub refs
EOF
      ;;
    *) die_code task.usage "用法：new guard install|status|sync" ;;
  esac
}
