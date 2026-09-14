# Git Guard：本机 staging bare 与 worktree 接线。
# 由 0-meta/bin/new 加载。hooks 本体在 2-infra/git-guard/。

guard_src_dir() {
  printf '%s' "$ROOT/2-infra/git-guard"
}

guard_staging_git() {
  printf '%s/%s/git-guard/staging.git\n' \
    "${XDG_STATE_HOME:-$HOME/.local/state}" "$(metrics_identity_dir)"
}

# ─────────────────────────────────────────────── transport facts
#
# A linked worktree has two config layers: the repository-wide config in the
# common git dir, and (when extensions.worktreeConfig=true) its own
# config.worktree.  Guard transport is a property of the task worktree, never
# of the repository.  Keep all reads/writes here so bind, recovery, and the
# merge adapter use the same effective-value rules.

guard_git_common_dir() {
  local wt="${1:-${ROOT:-.}}" common top
  common="$(git -C "$wt" rev-parse --path-format=absolute --git-common-dir 2>/dev/null || true)"
  if [ -z "$common" ] || [ "$common" = "--git-common-dir" ]; then
    common="$(git -C "$wt" rev-parse --git-common-dir 2>/dev/null || true)"
    case "$common" in
      /*) ;;
      '') return 1 ;;
      *)
        top="$(git -C "$wt" rev-parse --show-toplevel 2>/dev/null || true)"
        [ -n "$top" ] || return 1
        common="$(cd "$top/$common" 2>/dev/null && pwd -P)" || return 1
        ;;
    esac
  fi
  [ -n "$common" ] || return 1
  printf '%s\n' "$common"
}

guard_common_config_file() {
  local common
  common="$(guard_git_common_dir "${1:-${ROOT:-.}}")" || return 1
  printf '%s/config\n' "$common"
}

guard_worktree_config_file() {
  local wt="${1:-${ROOT:-.}}" gd
  gd="$(git -C "$wt" rev-parse --path-format=absolute --git-dir 2>/dev/null || true)"
  if [ -z "$gd" ] || [ "$gd" = "--git-dir" ]; then
    gd="$(git -C "$wt" rev-parse --git-dir 2>/dev/null || true)"
    case "$gd" in
      /*) ;;
      '') return 1 ;;
      *) gd="$(cd "$wt/$gd" 2>/dev/null && pwd -P)" || return 1 ;;
    esac
  fi
  printf '%s/config.worktree\n' "$gd"
}

guard_enable_worktree_config() {
  local wt="$1" common_cfg enabled
  common_cfg="$(guard_common_config_file "$wt")" || {
    err_code guard.worktree_config "    ✗ 无法解析 shared git config，拒绝写 task transport"
    return 1
  }
  enabled="$(git config --file "$common_cfg" --bool --get extensions.worktreeConfig 2>/dev/null || true)"
  if [ "$enabled" != true ]; then
    git config --file "$common_cfg" extensions.worktreeConfig true \
      || { err_code guard.worktree_config "    ✗ 无法启用 extensions.worktreeConfig，拒绝写 task transport"; return 1; }
  fi
  return 0
}

guard_transport_value_matches() {
  local value="$1" expected="$2"
  [ "$value" = "$expected" ] || [ "$value" = "file://$expected" ]
}

# stdout: absent|expected|custom|ambiguous.  `expected` must be exactly one
# value; duplicates and mixtures are deliberately ambiguous.
guard_transport_value_kind() {
  local values="${1:-}" expected="$2" line any=0 expected_n=0 other_n=0
  if [ -z "$values" ]; then
    printf 'absent\n'
    return 0
  fi
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    any=1
    if guard_transport_value_matches "$line" "$expected"; then
      expected_n=$((expected_n + 1))
    else
      other_n=$((other_n + 1))
    fi
  done <<< "$values"
  if [ "$any" = 0 ]; then
    printf 'absent\n'
  elif [ "$other_n" = 0 ] && [ "$expected_n" = 1 ]; then
    printf 'expected\n'
  elif [ "$other_n" = 0 ]; then
    printf 'ambiguous\n'
  elif [ "$expected_n" != 0 ]; then
    printf 'ambiguous\n'
  else
    printf 'custom\n'
  fi
}

# origin.url 的正常值就是 fetch URL，不能拿 staging path 当 expected
# 直接复用上面的 kind：这里额外把「一个普通 URL」与「多值/指向 staging」
# 区分开，避免 ambiguous remote 被误当成 clean。
guard_origin_value_kind() {
  local values="${1:-}" staging="$2" line count=0 staging_n=0
  [ -n "$values" ] || { printf 'absent\n'; return 0; }
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    count=$((count + 1))
    guard_transport_value_matches "$line" "$staging" && staging_n=$((staging_n + 1))
  done <<< "$values"
  if [ "$count" = 1 ] && [ "$staging_n" = 1 ]; then
    printf 'expected\n'
  elif [ "$count" = 1 ]; then
    printf 'normal\n'
  else
    printf 'ambiguous\n'
  fi
}

guard_common_transport_classify() {
  local wt="$1" common staging fetch
  local push_values receive_values claim_values fetch_values
  local push_kind receive_kind claim_kind fetch_kind state
  common="$(guard_common_config_file "$wt")" || return 1
  staging="$(guard_staging_git)"
  fetch="$(task_origin_fetch_url "$wt")"
  push_values="$(git config --file "$common" --get-all remote.origin.pushurl 2>/dev/null || true)"
  receive_values="$(git config --file "$common" --get-all remote.origin.receivepack 2>/dev/null || true)"
  claim_values="$(git config --file "$common" --get-all remote.claim.url 2>/dev/null || true)"
  fetch_values="$(git config --file "$common" --get-all remote.origin.url 2>/dev/null || true)"

  push_kind="$(guard_transport_value_kind "$push_values" "$staging")"
  receive_kind="$(guard_transport_value_kind "$receive_values" "$staging/hooks/guard-receive-pack")"
  claim_kind="$(guard_transport_value_kind "$claim_values" "$fetch")"
  fetch_kind="$(guard_origin_value_kind "$fetch_values" "$staging")"

  GUARD_SHARED_CONFIG="$common"
  GUARD_SHARED_PUSH_VALUES="$push_values"
  GUARD_SHARED_RECEIVE_VALUES="$receive_values"
  GUARD_SHARED_CLAIM_VALUES="$claim_values"
  GUARD_SHARED_FETCH_VALUES="$fetch_values"
  GUARD_SHARED_PUSH_KIND="$push_kind"
  GUARD_SHARED_RECEIVE_KIND="$receive_kind"
  GUARD_SHARED_CLAIM_KIND="$claim_kind"
  GUARD_SHARED_FETCH_KIND="$fetch_kind"

  if [ "$push_kind" = absent ] && [ "$receive_kind" = absent ] \
      && [ "$claim_kind" = absent ] \
      && { [ "$fetch_kind" = absent ] || [ "$fetch_kind" = normal ]; }; then
    state=clean
  elif [ "$fetch_kind" = expected ]; then
    state=ambiguous
  elif { [ "$push_kind" = expected ] || [ "$push_kind" = absent ]; } \
      && { [ "$receive_kind" = expected ] || [ "$receive_kind" = absent ]; } \
      && { [ "$claim_kind" = expected ] || [ "$claim_kind" = absent ]; }; then
    # One or both old Guard keys may be missing after a partial manual fix;
    # removing only the remaining exact values is still scoped and safe.
    state=legacy
  elif [ "$push_kind" = ambiguous ] || [ "$receive_kind" = ambiguous ] \
      || [ "$claim_kind" = ambiguous ] || [ "$fetch_kind" = ambiguous ] \
      || [ "$push_kind" = expected ] || [ "$receive_kind" = expected ] \
      || [ "$claim_kind" = expected ]; then
    state=ambiguous
  else
    state=custom
  fi
  GUARD_SHARED_STATE="$state"
  printf '%s\n' "$state"
}

guard_effective_guard_route() {
  local wt="$1" staging="$2" push rp line
  push="$(git -C "$wt" remote get-url --push origin 2>/dev/null || true)"
  if guard_transport_value_matches "$push" "$staging"; then
    return 0
  fi
  rp="$(git -C "$wt" config --get-all remote.origin.receivepack 2>/dev/null || true)"
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    [ "$line" = "$staging/hooks/guard-receive-pack" ] && return 0
  done <<< "$rp"
  return 1
}

guard_effective_custom_transport() {
  local wt="$1" staging="$2" fetch push rp line
  fetch="$(task_origin_fetch_url "$wt")"
  staging="${staging:-$(guard_staging_git)}"
  push="$(git -C "$wt" remote get-url --push origin 2>/dev/null || true)"
  if [ -n "$push" ] && [ "$push" != "$fetch" ] \
      && ! guard_transport_value_matches "$push" "$staging"; then
    return 0
  fi
  rp="$(git -C "$wt" config --get-all remote.origin.receivepack 2>/dev/null || true)"
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    [ "$line" != "$staging/hooks/guard-receive-pack" ] && return 0
  done <<< "$rp"
  return 1
}

guard_redact_transport() {
  sed -E 's#(https?://)[^/@[:space:]]+@#\1<redacted>@#g'
}

guard_print_transport_config() {
  local wt="$1" common worktree_cfg enabled
  common="$(guard_common_config_file "$wt" 2>/dev/null || true)"
  worktree_cfg="$(guard_worktree_config_file "$wt" 2>/dev/null || true)"
  echo "shared config   ${common:-（未知）}"
  if [ -n "$common" ]; then
    git config --show-origin --file "$common" --get-regexp \
      '^remote\..*\.(url|pushurl|receivepack)$' 2>/dev/null \
      | guard_redact_transport || true
  fi
  enabled="$(git config --file "${common:-/dev/null}" --bool --get extensions.worktreeConfig 2>/dev/null || true)"
  echo "worktree config ${worktree_cfg:-（未解析）} (enabled=${enabled:-false})"
  if [ "$enabled" = true ]; then
    git -C "$wt" config --show-origin --worktree --get-regexp \
      '^remote\..*\.(url|pushurl|receivepack)$' 2>/dev/null \
      | guard_redact_transport || true
  fi
  echo "effective fetch $(git -C "$wt" remote get-url origin 2>/dev/null | guard_redact_transport || true)"
  echo "effective push  $(git -C "$wt" remote get-url --push origin 2>/dev/null | guard_redact_transport || true)"
  echo "effective receivepack $(git -C "$wt" config --get-all remote.origin.receivepack 2>/dev/null | guard_redact_transport || true)"
}

guard_find_main_worktree() {
  local repo="$1" path="" line
  while IFS= read -r line; do
    case "$line" in
      worktree\ *) path="${line#worktree }" ;;
      branch\ refs/heads/main)
        [ -n "$path" ] && { printf '%s\n' "$path"; return 0; } ;;
    esac
  done < <(git -C "$repo" worktree list --porcelain 2>/dev/null)
  if [ "$(git -C "$repo" symbolic-ref --short HEAD 2>/dev/null || true)" = "$(default_branch)" ]; then
    printf '%s\n' "$repo"
    return 0
  fi
  return 1
}

# v1.0 的 ordinary `git remote set-url --push` / `git config` 会把 linked
# worktree 的值写进 shared config。这里只解除「全是 Guard 生成值」的旧接线；
# custom、混合、多值或 fetch=staging 都必须由人核对，绝不覆盖。
guard_recover_legacy_wiring() {
  local repo="$1" mode="${2:-apply}" main_wt common state key values
  case "$mode" in preview|apply) ;; *) err_code guard.usage "用法：new guard recover [--preview]"; return 1 ;; esac
  main_wt="$(guard_find_main_worktree "$repo" 2>/dev/null || true)"
  [ -n "$main_wt" ] || { err_code guard.main_worktree "无法定位 main worktree，拒绝恢复"; return 1; }
  guard_common_transport_classify "$main_wt" >/dev/null || {
    err_code guard.config_unreadable "无法读取 shared transport config，拒绝恢复"; return 1;
  }
  state="$GUARD_SHARED_STATE"
  common="$GUARD_SHARED_CONFIG"
  echo "Guard legacy wiring ${mode}"
  echo "main worktree   ${main_wt}"
  guard_print_transport_config "$main_wt"
  echo "classification   ${state}"
  case "$state" in
    clean)
      echo "no-op：没有可解除的 v1.0 Guard shared wiring"
      return 0
      ;;
    custom)
      err_code guard.custom_transport "shared transport 含用户自定义值；不覆盖。请核对 remote.origin.pushurl/receivepack 后再处理。"
      return 1
      ;;
    ambiguous)
      err_code guard.transport_ambiguous "shared transport 存在混合、多值或 fetch=staging 配置；fail-closed，不自动恢复。"
      return 1
      ;;
    legacy)
      if [ "$mode" = preview ]; then
        echo "preview：仅解除 shared config 中精确匹配的 v1.0 Guard pushurl/receivepack/claim；不改用户值"
        return 0
      fi
      for key in remote.origin.pushurl remote.origin.receivepack remote.claim.url; do
        values="$(git config --file "$common" --get-all "$key" 2>/dev/null || true)"
        [ -n "$values" ] || continue
        git config --file "$common" --unset-all "$key" \
          || { err_code guard.recover_failed "无法解除 shared config 的 ${key}"; return 1; }
      done
      guard_common_transport_classify "$main_wt" >/dev/null || return 1
      state="$GUARD_SHARED_STATE"
      [ "$state" = clean ] || {
        err_code guard.recover_failed "恢复后 shared transport 仍不是 clean（${state}），停止"; return 1;
      }
      c_ok "    ✓ 已 scoped 恢复 v1.0 legacy wiring；shared/main 不再依赖 task staging"
      return 0
      ;;
  esac
}

guard_main_transport_preflight() {
  local wt="$1" state staging
  task_is_main_worktree "$wt" || return 0
  staging="$(guard_staging_git)"
  if guard_effective_guard_route "$wt" "$staging"; then
    err_code guard.route "main 的 effective transport 仍指向 Guard staging/wrapper；先执行 new guard recover --preview 并核对后恢复。"
    return 1
  fi
  state="$(guard_common_transport_classify "$wt")" || return 1
  case "$state" in
    legacy)
      err_code guard.legacy_wiring "检测到 v1.0 legacy shared Guard wiring；approve 不走 task binding。先执行 new guard recover --preview。"
      return 1
      ;;
    ambiguous)
      err_code guard.transport_ambiguous "main shared transport 配置有歧义，approve fail-closed；先执行 new guard recover --preview 核对。"
      return 1
      ;;
  esac
  return 0
}

# R3：merge 前只修复「同一 staging 的 main mirror 落后」这一种可证明场景。
# 这是一个 refresh，不是 guard sync：不调用 guard_forward_plan，不读取或
# 重放任何旧 transaction 的 lease，也不碰 unrelated refs。
guard_refresh_staging_for_merge() (
  local wt="$1" main="${2:-main}" staging state snapshot_main staging_main tx
  local receive_status forward_status marker lease_status
  local -a blocked=()
  local GUARD_REFRESH_LOCK_STATE

  staging="$(guard_staging_git)"
  [ -d "$staging" ] || { guard_err "merge refresh blocked: staging 不存在"; return 1; }
  [ -f "$staging/hooks/git-guard-lib.sh" ] || {
    guard_err "merge refresh blocked: staging hook library 不存在"; return 1;
  }
  state="$staging/git-guard"
  mkdir -p "$state/transactions"

  # 隔离 hook 定义与 GIT_DIR；调用者（zmerge）后续仍在 task worktree。
  local GIT_DIR="$staging"
  export GIT_DIR
  # shellcheck source=/dev/null
  . "$staging/hooks/git-guard-lib.sh"
  GUARD_REFRESH_LOCK_STATE="$state"
  guard_lock_acquire "$state" || {
    guard_err "merge refresh blocked: 无法取得 Guard 互斥"; return 1;
  }
  trap 'guard_lock_release "$GUARD_REFRESH_LOCK_STATE"' EXIT

  # 先核对 durable transaction/lease facts；pending/failed/unknown 不能连
  # snapshot 都盲目刷新，防止把这次 merge 的无关 refresh 变成隐式 replay。
  for tx in "$state/transactions"/*; do
    [ -d "$tx" ] || continue
    receive_status="$(cat "$tx/receive-status" 2>/dev/null || true)"
    forward_status="$(cat "$tx/forward-status" 2>/dev/null || true)"
    case "$receive_status" in
      rejected)
        # pre-receive reject 没有 staged incoming/forward plan，可作为本次
        # stale-main 证据；任何写入痕迹都不再是安全 refresh。
        [ ! -e "$tx/incoming" ] || blocked+=("$(basename "$tx"):incoming")
        [ ! -e "$tx/forward-plan" ] || blocked+=("$(basename "$tx"):forward-plan")
        [ -z "$forward_status" ] || blocked+=("$(basename "$tx"):forward=${forward_status}")
        ;;
      noop)
        [ "$forward_status" = noop ] || blocked+=("$(basename "$tx"):noop-status")
        [ ! -e "$tx/incoming" ] || blocked+=("$(basename "$tx"):incoming")
        [ ! -e "$tx/forward-plan" ] || blocked+=("$(basename "$tx"):forward-plan")
        ;;
      accepted)
        case "$forward_status" in
          ok|noop) ;;
          *) blocked+=("$(basename "$tx"):forward=${forward_status:-unknown}") ;;
        esac
        ;;
      pending|mirror-failed|'')
        blocked+=("$(basename "$tx"):receive=${receive_status:-unknown}")
        ;;
      *)
        blocked+=("$(basename "$tx"):receive=${receive_status}")
        ;;
    esac
    for marker in "$tx/lease-ambiguity" "$tx/lease-ambiguous" "$tx/lease-unknown"; do
      [ ! -e "$marker" ] || blocked+=("$(basename "$tx"):$(basename "$marker")")
    done
    [ ! -e "$tx/forward-failure" ] || blocked+=("$(basename "$tx"):forward-failure")
    if [ -e "$tx/lease-status" ]; then
      lease_status="$(cat "$tx/lease-status" 2>/dev/null || true)"
      case "$lease_status" in known|none|not-applicable) ;; *)
        blocked+=("$(basename "$tx"):lease=${lease_status:-unknown}") ;;
      esac
    fi
  done
  if [ "${#blocked[@]}" -ne 0 ]; then
    guard_err "merge refresh blocked: transaction/lease facts 不明确（${blocked[*]}）；请显式 new guard sync 核对"
    return 1
  fi

  # durable facts 已明确后，只更新 snapshot namespace，不重放任何 transaction。
  if ! guard_snapshot_github "$staging"; then
    guard_err "merge refresh blocked: GitHub snapshot 刷新失败"; return 1
  fi

  snapshot_main="$(guard_rev "$staging" "${GUARD_SNAP}/heads/${main}")"
  staging_main="$(guard_rev "$staging" "refs/heads/${main}")"
  [ -n "$snapshot_main" ] || { guard_err "merge refresh blocked: GitHub snapshot 没有 ${main}"; return 1; }
  [ -n "$staging_main" ] || { guard_err "merge refresh blocked: staging 没有 ${main}"; return 1; }

  # 除 main 外所有 staging heads 都必须已与同一 snapshot 相等；这使得
  # update-ref 的影响域可证明只有 main，不会夹带 unrelated write。
  if ! diff -u \
      <(git --git-dir="$staging" for-each-ref --format='%(refname) %(objectname)' refs/heads |
          awk -v main="refs/heads/${main}" '$1 != main { sub("^refs/heads/", "refs/guard/github/heads/", $1); print }' |
          LC_ALL=C sort) \
      <(git --git-dir="$staging" for-each-ref --format='%(refname) %(objectname)' "${GUARD_SNAP}/heads" |
          awk -v main="${GUARD_SNAP}/heads/${main}" '$1 != main { print }' |
          LC_ALL=C sort) >/dev/null 2>&1; then
    guard_err "merge refresh blocked: unrelated staging refs 与 snapshot 不一致"; return 1
  fi
  if [ "$staging_main" = "$snapshot_main" ]; then
    printf 'noop\n'
    return 0
  fi
  git --git-dir="$staging" merge-base --is-ancestor "$staging_main" "$snapshot_main" || {
    guard_err "merge refresh blocked: staging ${main} 不是 snapshot 的祖先（非单向 stale）"; return 1;
  }
  git --git-dir="$staging" update-ref "refs/heads/${main}" "$snapshot_main" "$staging_main" || {
    guard_err "merge refresh blocked: scoped update-ref ${main} 失败"; return 1;
  }
  [ "$(guard_rev "$staging" "refs/heads/${main}")" = "$snapshot_main" ] || {
    guard_err "merge refresh blocked: refresh 后 ${main} 仍未与 snapshot 对齐"; return 1;
  }
  printf 'refreshed\n'
)

# push/receivepack 失败的唯一归因入口。输出只报告故障域，不回显可能含凭据
# 的完整 Git transport 日志。调用方可据此决定是否允许 R3 的一次内部刷新。
guard_classify_push_failure() {
  local wt="$1" output="${2:-}" rc="${3:-1}" staging domain
  staging="$(guard_staging_git)"
  domain=unknown
  if printf '%s\n' "$output" | grep -Eiq 'non-fast-forward|fetch first|rejected[^[:alnum:]]'; then
    domain=non-fast-forward
  elif printf '%s\n' "$output" | grep -Eiq 'authentication failed|could not read Username|permission denied|access denied|permission to .* denied|repository not found|could not read from remote repository|invalid username|bad credentials|403|401'; then
    domain=authentication
  elif printf '%s\n' "$output" | grep -Eiq 'could not resolve host|name or service not known|network is unreachable|connection timed out|connection refused|connection reset|failed to connect|unable to access'; then
    domain=network
  elif printf '%s\n' "$output" | grep -Eiq '陈旧 contract|staging.*(陈旧|未同步)|GitHub main 已前进|main 已前进.*staging'; then
    domain=guard-staging
  elif guard_effective_guard_route "$wt" "$staging" \
      || printf '%s\n' "$output" | grep -Eiq 'git-guard|Guard.*(Binding|wrapper|staging)'; then
    domain=guard-route
  elif guard_effective_custom_transport "$wt" "$staging"; then
    domain=user-custom-transport
  elif [ "$rc" -ne 0 ]; then
    domain=unknown
  fi
  GUARD_PUSH_FAILURE_DOMAIN="$domain"
  printf '%s\n' "$domain"
}

guard_report_push_failure() {
  local wt="$1" output="${2:-}" rc="${3:-1}" domain
  domain="$(guard_classify_push_failure "$wt" "$output" "$rc")"
  GUARD_PUSH_FAILURE_DOMAIN="$domain"
  case "$domain" in
    non-fast-forward)
      err_code guard.non_fast_forward "远端分支已前进，属于 non-fast-forward，不是 Guard route；先核对远端状态后再显式同步。" ;;
    guard-staging)
      err_code guard.staging_stale "Guard staging/mirror 陈旧；这是 Guard staging 故障域，不要求 zsync 或 pull/rebase。" ;;
    guard-route)
      err_code guard.route "Guard transport/receive-pack route 失败；不把它误报成 git pull/rebase。" ;;
    network)
      err_code transport.network "网络 transport 失败；先恢复网络/镜像可达性，不建议用 pull/rebase 掩盖。" ;;
    authentication)
      err_code transport.authentication "认证或权限失败；先核对认证，不建议用 pull/rebase 掩盖。" ;;
    user-custom-transport)
      err_code transport.user_custom "检测到用户自定义 remote transport；不覆盖、不自动恢复，请人工核对。" ;;
    *)
      err_code transport.push_failed "push transport 失败（故障域未知，fail-closed）；请核对有效 transport 与原始错误。" ;;
  esac
  return 1
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
# 所有 task transport 都写入 config.worktree；shared config 里已有 Guard
# 或用户自定义值时 fail-closed，必须先走显式 recovery/人工核对。
guard_wire_worktree() {
  local wt="$1" staging fetch push now_claim local_push local_receive kind
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

  guard_common_transport_classify "$wt" >/dev/null || {
    err_code guard.config_unreadable "    ✗ 无法读取 shared transport config，拒绝接线"; return 1;
  }
  case "$GUARD_SHARED_STATE" in
    legacy)
      err_code guard.legacy_wiring "    ✗ shared config 仍有 v1.0 legacy Guard wiring；先 new guard recover --preview"; return 1 ;;
    ambiguous)
      err_code guard.transport_ambiguous "    ✗ shared transport 有歧义或混合值，拒绝覆盖；先 new guard recover --preview"; return 1 ;;
    custom)
      err_code guard.custom_transport "    ✗ shared transport 含用户自定义值，拒绝覆盖"; return 1 ;;
  esac

  guard_enable_worktree_config "$wt" || return 1
  local_push="$(git -C "$wt" config --worktree --get-all remote.origin.pushurl 2>/dev/null || true)"
  kind="$(guard_transport_value_kind "$local_push" "$staging")"
  case "$kind" in
    absent)
      git -C "$wt" config --worktree remote.origin.pushurl "$staging" \
        || { err_code guard.wire_push "    ✗ 无法写入 task-local origin push URL"; return 1; } ;;
    expected) ;;
    *) err_code guard.custom_transport "    ✗ task-local origin pushurl 有自定义或多值，拒绝覆盖"; return 1 ;;
  esac
  local_receive="$(git -C "$wt" config --worktree --get-all remote.origin.receivepack 2>/dev/null || true)"
  kind="$(guard_transport_value_kind "$local_receive" "$staging/hooks/guard-receive-pack")"
  case "$kind" in
    absent)
      git -C "$wt" config --worktree remote.origin.receivepack "$staging/hooks/guard-receive-pack" \
        || { err_code guard.wire_push "    ✗ 无法写入 task-local origin receivepack"; return 1; } ;;
    expected) ;;
    *) err_code guard.custom_transport "    ✗ task-local origin receivepack 有自定义或多值，拒绝覆盖"; return 1 ;;
  esac
  task_ensure_claim_remote "$wt" || return 1
  push="$(git -C "$wt" remote get-url --push origin 2>/dev/null || true)"
  now_claim="$(git -C "$wt" remote get-url claim 2>/dev/null || true)"
  if [ "$push" != "$staging" ]; then
    err_code guard.wire_push "    ✗ origin push URL 不是 staging"; return 1
  fi
  if [ "$now_claim" != "$fetch" ]; then
    err_code guard.wire_claim "    ✗ claim remote 必须等于 origin fetch URL"; return 1
  fi
  if ! guard_effective_guard_route "$wt" "$staging"; then
    err_code guard.wire_push "    ✗ task effective origin transport 不是 Guard staging/wrapper"; return 1
  fi
  return 0
}

guard_require_wired() {
  local wt="$1" staging fetch push now_claim rp shared_state enabled common_cfg
  if task_is_main_worktree "$wt"; then
    return 0
  fi
  staging="$(guard_staging_git)"
  [ -d "$staging" ] || return 0
  guard_common_transport_classify "$wt" >/dev/null || {
    err_code guard.config_unreadable "    ✗ 无法读取 shared transport config，fail-closed"; return 1;
  }
  shared_state="$GUARD_SHARED_STATE"
  case "$shared_state" in
    legacy)
      err_code guard.legacy_wiring "    ✗ shared config 仍是 v1.0 legacy wiring；先 new guard recover --preview"; return 1 ;;
    ambiguous)
      err_code guard.transport_ambiguous "    ✗ shared transport 有歧义，拒绝把 task 视为已接线"; return 1 ;;
    custom)
      err_code guard.custom_transport "    ✗ shared transport 含用户自定义值，拒绝把 task 视为已接线"; return 1 ;;
  esac
  common_cfg="$GUARD_SHARED_CONFIG"
  enabled="$(git config --file "$common_cfg" --bool --get extensions.worktreeConfig 2>/dev/null || true)"
  [ "$enabled" = true ] || {
    err_code guard.not_worktree_local "    ✗ task transport 未启用 worktree-local config，fail-closed；请重新 new task bind <n>"; return 1;
  }
  fetch="$(task_origin_fetch_url "$wt")"
  push="$(git -C "$wt" remote get-url --push origin 2>/dev/null || true)"
  now_claim="$(git -C "$wt" remote get-url claim 2>/dev/null || true)"
  if [ "$push" != "$staging" ]; then
    err_code guard.not_wired "    ✗ origin push URL 必须是 staging，不得直达 GitHub"
    echo "      修复：new task bind <n>"
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
    recover)
      case "${2:-}" in
        '') [ $# -eq 1 ] || die_code task.usage "用法：new guard recover [--preview]"; guard_recover_legacy_wiring "${ROOT:-.}" apply ;;
        --preview) [ $# -eq 2 ] || die_code task.usage "用法：new guard recover [--preview]"; guard_recover_legacy_wiring "${ROOT:-.}" preview ;;
        *) die_code task.usage "用法：new guard recover [--preview]" ;;
      esac
      ;;
    -h|--help|help|"")
      cat <<'EOF'
用法：new guard install|status|sync|recover

  new guard install   按 origin 身份建立本机 staging bare 与 receive-pack wrapper
  new guard status    查看 staging / GitHub 同步及每条 forwarding failure
  new guard sync      按原 lease 重试失败转发，再镜像 GitHub refs
  new guard recover   预览并解除固定 v1.0 Guard shared wiring（默认 apply）
  new guard recover --preview 只核对，不改 shared config
EOF
      ;;
    *) die_code task.usage "用法：new guard install|status|sync|recover" ;;
  esac
}
