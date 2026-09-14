# Git Guard：本机 staging bare 与 worktree 接线。
# 由 0-meta/bin/new 加载。hooks 本体在 2-infra/git-guard/。

guard_src_dir() {
  printf '%s' "$ROOT/2-infra/git-guard"
}

guard_staging_git() {
  printf '%s/%s/git-guard/staging.git\n' \
    "${XDG_STATE_HOME:-$HOME/.local/state}" "$(metrics_identity_dir)"
}

guard_ref_oid() {
  local dir="$1" ref="$2"
  git --git-dir="$dir" rev-parse -q --verify "${ref}^{commit}" 2>/dev/null || true
}

guard_error() {
  if [ "$(type -t guard_err 2>/dev/null)" = function ]; then
    guard_err "$*"
  else
    c_err "git-guard: $*"
  fi
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

guard_transport_value_count() {
  local values="${1:-}" line count=0
  [ -n "$values" ] || { printf '0\n'; return 0; }
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    count=$((count + 1))
  done <<< "$values"
  printf '%s\n' "$count"
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

# 从一组 config 值中取且仅取一个值。返回失败时不猜测是缺失还是多值，
# 由调用方读取 GUARD_CONFIG_VALUE_COUNT 给出 fail-closed 诊断。
guard_config_one_value() {
  local values="${1:-}" line count=0 only=""
  GUARD_CONFIG_VALUE_COUNT=0
  GUARD_CONFIG_ONE_VALUE=""
  [ -n "$values" ] || return 1
  while IFS= read -r line; do
    count=$((count + 1))
    only="$line"
  done <<< "$values"
  GUARD_CONFIG_VALUE_COUNT="$count"
  if [ "$count" = 1 ] && [ -n "$only" ]; then
    GUARD_CONFIG_ONE_VALUE="$only"
    return 0
  fi
  return 1
}

# canonical repository identity：GitHub 的 SSH/HTTPS 等价地址归一化为
# owner/repo；本地 bare remote 归一化为 local:/absolute/path。无法解析的
# 地址不参与猜测，供 candidate/staging identity 校验直接拒绝。
guard_repo_identity() {
  local raw="${1:-}" value rest authority host path scheme owner repo
  local local_path local_dir local_base
  [ -n "$raw" ] || return 1
  case "$raw" in *[[:space:]]*|*\?*|*\#*) return 1 ;; esac
  value="$raw"

  case "$value" in
    file://*)
      local_path="${value#file://}"
      case "$local_path" in /*) ;; *) return 1 ;; esac
      ;;
    http://*|https://*|ssh://*|git://*)
      scheme="${value%%://*}"
      rest="${value#*://}"
      authority="${rest%%/*}"
      [ "$authority" != "$rest" ] || return 1
      path="${rest#*/}"
      authority="${authority##*@}"
      host="${authority%%:*}"
      [ -n "$host" ] && [ -n "$path" ] || return 1
      case "$scheme" in http|https|ssh|git) ;; *) return 1 ;; esac
      ;;
    git@*:*|*[!/:]@*:* )
      authority="${value#*@}"
      host="${authority%%:*}"
      path="${authority#*:}"
      [ -n "$host" ] && [ -n "$path" ] || return 1
      ;;
    /*)
      local_path="$value"
      ;;
    *)
      return 1
      ;;
  esac

  if [ -n "${local_path:-}" ]; then
    local_dir="${local_path%/*}"
    local_base="${local_path##*/}"
    [ -n "$local_dir" ] || local_dir=/
    local_dir="$(cd "$local_dir" 2>/dev/null && pwd -P)" || return 1
    local_base="${local_base%.git}"
    [ -n "$local_base" ] || return 1
    printf 'local:%s/%s\n' "$local_dir" "$local_base"
    return 0
  fi

  host="$(printf '%s' "$host" | tr '[:upper:]' '[:lower:]')"
  path="${path#/}"
  path="${path%/}"
  path="${path%.git}"
  [ -n "$path" ] || return 1
  if [ "$host" = github.com ] || [ "$host" = www.github.com ]; then
    case "$path" in */*/*|*/*/) return 1 ;; esac
    owner="${path%%/*}"
    repo="${path#*/}"
    [ "$owner" != "$path" ] && [ -n "$owner" ] && [ -n "$repo" ] || return 1
    [[ "$owner" =~ ^[A-Za-z0-9._-]+$ ]] || return 1
    [[ "$repo" =~ ^[A-Za-z0-9._-]+$ ]] || return 1
    printf '%s/%s\n' "$(printf '%s' "$owner" | tr '[:upper:]' '[:lower:]')" \
      "$(printf '%s' "$repo" | tr '[:upper:]' '[:lower:]')"
    return 0
  fi
  printf '%s/%s\n' "$host" "$path"
}

guard_validate_staging_source_identity() {
  local wt="$1" staging="$2" candidate_values staging_values
  local candidate_url staging_url candidate_id staging_id remote
  remote="${GUARD_REMOTE:-github}"
  candidate_values="$(env -u GIT_DIR -u GIT_WORK_TREE git -C "$wt" \
    config --get-all remote.origin.url 2>/dev/null || true)"
  guard_config_one_value "$candidate_values" || {
    err_code guard.remote_identity "candidate origin.url 必须恰好一个可解析值（${GUARD_CONFIG_VALUE_COUNT:-0} 个），拒绝 refresh"
    return 1
  }
  candidate_url="$GUARD_CONFIG_ONE_VALUE"
  candidate_id="$(guard_repo_identity "$candidate_url" 2>/dev/null || true)"
  [ -n "$candidate_id" ] || {
    err_code guard.remote_identity "无法解析 candidate origin repository identity，拒绝 refresh"
    return 1
  }

  staging_values="$(env -u GIT_DIR -u GIT_WORK_TREE git --git-dir="$staging" \
    config --get-all "remote.${remote}.url" 2>/dev/null || true)"
  guard_config_one_value "$staging_values" || {
    err_code guard.remote_identity "staging ${remote}.url 必须恰好一个可解析值（${GUARD_CONFIG_VALUE_COUNT:-0} 个），拒绝 refresh"
    return 1
  }
  staging_url="$GUARD_CONFIG_ONE_VALUE"
  staging_id="$(guard_repo_identity "$staging_url" 2>/dev/null || true)"
  [ -n "$staging_id" ] || {
    err_code guard.remote_identity "无法解析 staging mirror source repository identity，拒绝 refresh"
    return 1
  }
  GUARD_CANDIDATE_REPO_IDENTITY="$candidate_id"
  GUARD_STAGING_REPO_IDENTITY="$staging_id"
  if [ "$candidate_id" != "$staging_id" ]; then
    err_code guard.remote_identity "candidate=${candidate_id} 与 staging=${staging_id} repository identity 不一致，拒绝 refresh"
    return 1
  fi
  return 0
}

# claim remote 的唯一 effective transport 判定。输出状态：absent（待建立）、
# canonical、legacy、custom、mixed、ambiguous；GUARD_CLAIM_DETAIL 保留具体
# key/层级，便于拒绝时不覆盖用户配置。
guard_claim_transport_classify() {
  local wt="$1" common enabled worktree_cfg origin_values want
  local shared_url shared_push shared_receive local_url local_push local_receive
  local url_values push_values receive_values url_kind push_kind receive_kind
  local shared_url_kind shared_push_kind shared_receive_kind
  local has_shared=0 has_worktree=0 state=custom detail=""
  common="$(guard_common_config_file "$wt" 2>/dev/null || true)"
  [ -n "$common" ] || { GUARD_CLAIM_STATE=ambiguous; GUARD_CLAIM_DETAIL='shared config unreadable'; printf '%s\n' ambiguous; return 0; }
  origin_values="$(env -u GIT_DIR -u GIT_WORK_TREE git -C "$wt" \
    config --get-all remote.origin.url 2>/dev/null || true)"
  guard_config_one_value "$origin_values" || {
    GUARD_CLAIM_STATE=ambiguous
    GUARD_CLAIM_DETAIL="origin.url ${GUARD_CONFIG_VALUE_COUNT:-0}-value"
    printf '%s\n' ambiguous
    return 0
  }
  want="$GUARD_CONFIG_ONE_VALUE"

  shared_url="$(git config --file "$common" --get-all remote.claim.url 2>/dev/null || true)"
  shared_push="$(git config --file "$common" --get-all remote.claim.pushurl 2>/dev/null || true)"
  shared_receive="$(git config --file "$common" --get-all remote.claim.receivepack 2>/dev/null || true)"
  [ -z "$shared_url$shared_push$shared_receive" ] || has_shared=1

  enabled="$(git config --file "$common" --bool --get extensions.worktreeConfig 2>/dev/null || true)"
  worktree_cfg="$(guard_worktree_config_file "$wt" 2>/dev/null || true)"
  if [ -f "$worktree_cfg" ]; then
    local_url="$(git config --file "$worktree_cfg" --get-all remote.claim.url 2>/dev/null || true)"
    local_push="$(git config --file "$worktree_cfg" --get-all remote.claim.pushurl 2>/dev/null || true)"
    local_receive="$(git config --file "$worktree_cfg" --get-all remote.claim.receivepack 2>/dev/null || true)"
  else
    local_url=""; local_push=""; local_receive=""
  fi
  [ -z "$local_url$local_push$local_receive" ] || has_worktree=1

  # Keep layer provenance separate from the effective-value result.  A
  # same-value shared URL plus worktree pushurl is still two active writers;
  # enabling worktreeConfig later could change which value Git uses.  It is
  # therefore mixed/ambiguous and must never be normalized by claim.
  GUARD_CLAIM_SHARED_URL_VALUES="$shared_url"
  GUARD_CLAIM_SHARED_PUSHURL_VALUES="$shared_push"
  GUARD_CLAIM_SHARED_RECEIVEPACK_VALUES="$shared_receive"
  GUARD_CLAIM_WORKTREE_URL_VALUES="$local_url"
  GUARD_CLAIM_WORKTREE_PUSHURL_VALUES="$local_push"
  GUARD_CLAIM_WORKTREE_RECEIVEPACK_VALUES="$local_receive"
  GUARD_CLAIM_SHARED_URL_COUNT="$(guard_transport_value_count "$shared_url")"
  GUARD_CLAIM_SHARED_PUSHURL_COUNT="$(guard_transport_value_count "$shared_push")"
  GUARD_CLAIM_SHARED_RECEIVEPACK_COUNT="$(guard_transport_value_count "$shared_receive")"
  GUARD_CLAIM_WORKTREE_URL_COUNT="$(guard_transport_value_count "$local_url")"
  GUARD_CLAIM_WORKTREE_PUSHURL_COUNT="$(guard_transport_value_count "$local_push")"
  GUARD_CLAIM_WORKTREE_RECEIVEPACK_COUNT="$(guard_transport_value_count "$local_receive")"

  url_values="$(env -u GIT_DIR -u GIT_WORK_TREE git -C "$wt" config \
    --get-all remote.claim.url 2>/dev/null || true)"
  push_values="$(env -u GIT_DIR -u GIT_WORK_TREE git -C "$wt" config \
    --get-all remote.claim.pushurl 2>/dev/null || true)"
  receive_values="$(env -u GIT_DIR -u GIT_WORK_TREE git -C "$wt" config \
    --get-all remote.claim.receivepack 2>/dev/null || true)"
  url_kind="$(guard_transport_value_kind "$url_values" "$want")"
  push_kind="$(guard_transport_value_kind "$push_values" "$want")"
  receive_kind="$(guard_transport_value_kind "$receive_values" '__no_claim_receivepack__')"

  if [ "$has_shared" = 1 ] && [ "$has_worktree" = 1 ]; then
    state=mixed
    detail="claim transport 同时存在 shared 与 worktree-local 层（即使 value 相同也拒绝）"
  elif [ "$has_worktree" = 1 ] && [ "$enabled" != true ]; then
    state=ambiguous
    detail='worktree claim transport 存在但 extensions.worktreeConfig 未启用'
  elif [ "$url_kind" = absent ] && [ "$push_kind" = absent ] && [ "$receive_kind" = absent ]; then
    if [ "$has_shared" = 1 ]; then
      state=custom
      detail='shared claim transport 与 effective claim 不一致'
    else
      state=absent
      detail='claim transport absent'
    fi
  elif [ "$url_kind" = expected ] \
      && { [ "$push_kind" = absent ] || [ "$push_kind" = expected ]; } \
      && [ "$receive_kind" = absent ]; then
    state=canonical
    detail='effective claim url/pushurl/receivepack canonical'
  else
    case "$url_kind:$push_kind:$receive_kind" in
      *ambiguous*|*'expected:ambiguous'*|*'ambiguous:expected'*) state=ambiguous; detail='effective claim transport multi-value/ambiguous' ;;
      *expected*custom*|*custom*expected*|*expected*ambiguous*|*ambiguous*expected*) state=mixed; detail='effective claim transport mixed canonical/custom' ;;
      *) state=custom; detail='effective claim transport custom or missing url' ;;
    esac
  fi

  # linked worktree 的 shared claim.url 是 v1.0 遗留形态；不能把同值再写一份
  # 到 worktree 后假装安全。shared pushurl/receivepack 则仍按 custom/mixed 拒绝。
  shared_url_kind="$(guard_transport_value_kind "$shared_url" "$want")"
  shared_push_kind="$(guard_transport_value_kind "$shared_push" "$want")"
  shared_receive_kind="$(guard_transport_value_kind "$shared_receive" '__no_claim_receivepack__')"
  if [ "$state" != mixed ] && [ "$state" != ambiguous ] \
      && [ "$has_shared" = 1 ] && [ "$shared_url_kind" = expected ] \
      && [ "$shared_push_kind" = absent ] && [ "$shared_receive_kind" = absent ] \
      && [ -z "$local_url$local_push$local_receive" ]; then
    state=legacy
    detail='shared remote.claim.url legacy wiring'
  fi
  GUARD_CLAIM_STATE="$state"
  GUARD_CLAIM_DETAIL="$detail"
  printf '%s\n' "$state"
}

guard_claim_transport_preflight() {
  local wt="$1" state
  guard_claim_transport_classify "$wt" >/dev/null || return 1
  state="$GUARD_CLAIM_STATE"
  case "$state" in
    absent|canonical) return 0 ;;
    legacy) err_code claim.legacy_transport "claim transport 是 shared v1.0 legacy wiring，拒绝覆盖；先核对 Guard recovery"; return 1 ;;
    mixed) err_code claim.mixed_transport "claim transport 含 canonical/custom 混合值，拒绝覆盖"; return 1 ;;
    ambiguous) err_code claim.transport_ambiguous "claim transport 多值或歧义，拒绝覆盖"; return 1 ;;
    *) err_code claim.custom_transport "claim transport 含用户自定义值，拒绝覆盖"; return 1 ;;
  esac
}

guard_claim_transport_validate() {
  local wt="$1" state
  guard_claim_transport_classify "$wt" >/dev/null || return 1
  state="$GUARD_CLAIM_STATE"
  [ "$state" = canonical ] || {
    err_code claim.transport_invalid "claim effective transport 未通过 canonical 校验（${state}: ${GUARD_CLAIM_DETAIL:-unknown}）"
    return 1
  }
  return 0
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
  local claim_state
  case "$mode" in preview|apply) ;; *) err_code guard.usage "用法：new guard recover [--preview]"; return 1 ;; esac
  main_wt="$(guard_find_main_worktree "$repo" 2>/dev/null || true)"
  [ -n "$main_wt" ] || { err_code guard.main_worktree "无法定位 main worktree，拒绝恢复"; return 1; }
  guard_common_transport_classify "$main_wt" >/dev/null || {
    err_code guard.config_unreadable "无法读取 shared transport config，拒绝恢复"; return 1;
  }
  if [ "$(type -t guard_claim_transport_classify 2>/dev/null)" = function ]; then
    claim_state="$(guard_claim_transport_classify "$main_wt")"
    case "$claim_state" in
      custom|mixed|ambiguous)
        err_code guard.claim_transport "claim effective transport 是 ${claim_state}，恢复不覆盖用户值；请先核对 remote.claim.url/pushurl/receivepack"; return 1 ;;
    esac
  fi
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

# 单个 transaction 的 durable facts 一致性。除了状态文件与 snapshot/lease
# 事实外，任何未知文件都按 write intent/evidence 处理；noop 只有在没有
# 任何写入证据时才是 noop。accepted 也必须和正常 forwarding evidence 配对。
guard_transaction_validate_one() {
  local tx="$1" receive_status forward_status lease_status name entry
  local has_incoming=0 has_plan=0 has_recovered=0 has_failure=0 unknown=""

  receive_status="$(cat "$tx/receive-status" 2>/dev/null || true)"
  forward_status="$(cat "$tx/forward-status" 2>/dev/null || true)"
  for entry in "$tx"/* "$tx"/.[!.]*; do
    [ -e "$entry" ] || continue
    [ -f "$entry" ] || { unknown="$(basename "$entry")"; break; }
    name="$(basename "$entry")"
    case "$name" in
      receive-status|forward-status|snapshot-nonce|snapshot-main|lease-status) ;;
      incoming) has_incoming=1 ;;
      forward-plan) has_plan=1 ;;
      forward-recovered) has_recovered=1 ;;
      forward-failure) has_failure=1 ;;
      *) unknown="$name"; break ;;
    esac
  done
  if [ -n "$unknown" ]; then
    GUARD_TXN_ERROR="unknown write evidence ${unknown}"
    return 1
  fi
  if [ -e "$tx/lease-status" ]; then
    lease_status="$(cat "$tx/lease-status" 2>/dev/null || true)"
    case "$lease_status" in
      known|none|not-applicable) ;;
      *) GUARD_TXN_ERROR="lease=${lease_status:-unknown}"; return 1 ;;
    esac
  fi

  case "$receive_status" in
    noop)
      if [ "$forward_status" != noop ]; then
        GUARD_TXN_ERROR="noop with forward=${forward_status:-unknown}"; return 1
      fi
      if [ "$has_incoming" = 1 ] || [ "$has_plan" = 1 ] \
          || [ "$has_recovered" = 1 ] || [ "$has_failure" = 1 ]; then
        GUARD_TXN_ERROR="noop with write evidence"
        return 1
      fi
      ;;
    rejected)
      if [ -n "$forward_status" ] || [ "$has_incoming" = 1 ] \
          || [ "$has_plan" = 1 ] || [ "$has_recovered" = 1 ] \
          || [ "$has_failure" = 1 ]; then
        GUARD_TXN_ERROR="rejected with forwarding/write evidence"
        return 1
      fi
      ;;
    accepted)
      # 正常 accepted transaction 必须已有 post-receive incoming、forward-plan
      # 与 forward-status=ok；accepted+noop 是自相矛盾，不能借此放行 refresh。
      if [ "$forward_status" != ok ] || [ "$has_incoming" != 1 ] \
          || [ "$has_plan" != 1 ] || [ "$has_failure" = 1 ]; then
        GUARD_TXN_ERROR="accepted with contradictory forwarding/write facts"
        return 1
      fi
      ;;
    pending|mirror-failed|'')
      GUARD_TXN_ERROR="receive=${receive_status:-unknown}"
      return 1
      ;;
    *)
      GUARD_TXN_ERROR="receive=${receive_status}"
      return 1
      ;;
  esac
  return 0
}

guard_transaction_consistency() {
  local state="$1" root tx errors=""
  root="$state/transactions"
  GUARD_TRANSACTION_ERROR=""
  [ -d "$root" ] || return 0
  for tx in "$root"/*; do
    [ -d "$tx" ] || continue
    if ! guard_transaction_validate_one "$tx"; then
      errors="${errors}${errors:+; }$(basename "$tx"): ${GUARD_TXN_ERROR:-inconsistent}"
    fi
  done
  GUARD_TRANSACTION_ERROR="$errors"
  [ -z "$errors" ]
}

guard_transaction_fingerprint() {
  local state="$1" root file rel
  root="$state/transactions"
  [ -d "$root" ] || { printf 'none\n'; return 0; }
  {
    find "$root" -type f -print | LC_ALL=C sort | while IFS= read -r file; do
      rel="${file#"$root"/}"
      printf 'path=%s\n' "$rel"
      cat "$file"
      printf '\0\n'
    done
  } | if command -v shasum >/dev/null 2>&1; then
    shasum -a 256 | awk '{print $1}'
  else
    sha256sum | awk '{print $1}'
  fi
}

# merge gate 只验证当前 task 与同一 staging 的关系，不更新任何 ref。
# relation=stale-ok 仅供 refresh 前使用；synced 是 retry/final merge 的门槛。
guard_merge_gate_validate() {
  local wt="$1" main="${2:-main}" relation="${3:-synced}"
  local staging snapshot_main staging_main tx_fingerprint stable_refs push rp claim snap
  staging="$(guard_staging_git)"
  if [ ! -d "$staging" ]; then
    GUARD_MERGE_GATE_FINGERPRINT=none
    return 0
  fi
  guard_require_wired "$wt" || return 1
  guard_validate_staging_source_identity "$wt" "$staging" || return 1
  snap="${GUARD_SNAP:-refs/guard/github}"
  guard_transaction_consistency "$staging/git-guard" || {
    guard_error "merge gate blocked: transaction/lease facts 不一致（${GUARD_TRANSACTION_ERROR:-unknown}）"
    return 1
  }
  snapshot_main="$(guard_ref_oid "$staging" "${snap}/heads/${main}")"
  staging_main="$(guard_ref_oid "$staging" "refs/heads/${main}")"
  [ -n "$snapshot_main" ] && [ -n "$staging_main" ] || {
    guard_error "merge gate blocked: staging/snapshot 缺少 ${main}，拒绝猜测 mirror relation"
    return 1
  }
  if [ "$relation" = synced ]; then
    [ "$staging_main" = "$snapshot_main" ] || {
      guard_error "merge gate blocked: staging ${main} 仍未与 Guard snapshot 对齐"
      return 1
    }
  else
    git --git-dir="$staging" merge-base --is-ancestor "$staging_main" "$snapshot_main" || {
      guard_error "merge gate blocked: staging ${main} 不是 Guard snapshot 的祖先"
      return 1
    }
  fi
  tx_fingerprint="$(guard_transaction_fingerprint "$staging/git-guard")" || {
    guard_error "merge gate blocked: 无法读取 transaction fingerprint"
    return 1
  }
  stable_refs="$({
    git --git-dir="$staging" for-each-ref --format='%(refname) %(objectname)' refs/heads |
      awk -v main="refs/heads/${main}" '$1 != main { print }'
    git --git-dir="$staging" for-each-ref --format='%(refname) %(objectname)' "${snap}/heads" |
      awk -v main="${snap}/heads/${main}" '$1 != main { print }'
  } | LC_ALL=C sort)"
  push="$(git -C "$wt" remote get-url --push origin 2>/dev/null || true)"
  rp="$(git -C "$wt" config --get-all remote.origin.receivepack 2>/dev/null || true)"
  claim="$(git -C "$wt" remote get-url claim 2>/dev/null || true)"
  GUARD_MERGE_GATE_FINGERPRINT="$({
    printf 'identity=%s/%s\n' "$GUARD_CANDIDATE_REPO_IDENTITY" "$GUARD_STAGING_REPO_IDENTITY"
    printf 'transaction=%s\n' "$tx_fingerprint"
    printf 'stable-refs=%s\n' "$stable_refs"
    printf 'push=%s\nreceivepack=%s\nclaim=%s\n' "$push" "$rp" "$claim"
  } | if command -v shasum >/dev/null 2>&1; then
    shasum -a 256 | awk '{print $1}'
  else
    sha256sum | awk '{print $1}'
  fi)"
  return 0
}

# R3：merge 前只修复「同一 staging 的 main mirror 落后」这一种可证明场景。
# 这是一个 refresh，不是 guard sync：不调用 guard_forward_plan，不读取或
# 重放任何旧 transaction 的 lease，也不碰 unrelated refs。
guard_refresh_staging_for_merge() (
  local wt="$1" main="${2:-main}" staging state snapshot_main staging_main tx
  local GUARD_REFRESH_LOCK_STATE

  staging="$(guard_staging_git)"
  [ -d "$staging" ] || { guard_error "merge refresh blocked: staging 不存在"; return 1; }
  [ -f "$staging/hooks/git-guard-lib.sh" ] || {
    guard_error "merge refresh blocked: staging hook library 不存在"; return 1;
  }
  guard_merge_gate_validate "$wt" "$main" stale-ok || return 1
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

  # 互斥内再次核对 durable facts；pending/failed/unknown 不能连 snapshot
  # 都盲目刷新，防止把这次 merge 的无关 refresh 变成隐式 replay。
  if ! guard_transaction_consistency "$state"; then
    guard_err "merge refresh blocked: transaction/lease facts 不明确（${GUARD_TRANSACTION_ERROR:-unknown}）；请显式 new guard sync 核对"
    return 1
  fi

  # durable facts 已明确后，只更新目标 main snapshot，不重放任何 transaction。
  if ! guard_snapshot_github "$staging" "refs/heads/${main}"; then
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
  # 只接受明确的 NFF 语义；`remote rejected` / `pre-receive hook declined`
  # 是 hook/Guard 结果，不能因共享单词 rejected 被误判为 NFF。
  if printf '%s\n' "$output" | grep -Eiq \
      'non-fast-forward|fetch first|tip of your current branch is behind|updates were rejected because the remote contains work'; then
    domain=non-fast-forward
  elif printf '%s\n' "$output" | grep -Eiq 'pre-receive hook declined|update hook declined|remote rejected.*(hook|declined)|hook declined'; then
    domain=guard-route
  elif printf '%s\n' "$output" | grep -Eiq 'could not resolve host|name or service not known|network is unreachable|connection timed out|operation timed out|connection refused|connection reset|failed to connect|unable to access'; then
    domain=network
  elif printf '%s\n' "$output" | grep -Eiq 'authentication failed|could not read Username|permission denied \(publickey\)|access denied|permission to .* denied|repository not found|invalid username|bad credentials|(^|[^0-9])(403|401)([^0-9]|$)'; then
    domain=authentication
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

  guard_claim_transport_preflight "$wt" || return 1

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
  guard_claim_transport_validate "$wt" || return 1
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
