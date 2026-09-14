#!/usr/bin/env bash
# Git Guard 事实模型。
#
# refs/heads/*              staging 自己收到什么
# refs/guard/github/heads/* 最近一次确认的 GitHub 世界（wrapper 在 receive-pack 前刷新）
# pre/post-receive 的 old-oid  这次客户端声称基于什么
#
# GitHub 是 fetch / claim / lease / 删除的比较对象。staging 只是门。
# 不改 claim / derive / review / zmerge 业务语义。

GUARD_ZERO="0000000000000000000000000000000000000000"
GUARD_REMOTE="${GUARD_REMOTE:-github}"
GUARD_SNAP="refs/guard/github"

guard_is_zero() { [ "$1" = "$GUARD_ZERO" ]; }

guard_err() { printf 'git-guard: %s\n' "$*" >&2; }

guard_git_dir() {
  if [ -n "${GIT_DIR:-}" ]; then
    printf '%s' "$GIT_DIR"
    return 0
  fi
  git rev-parse --absolute-git-dir 2>/dev/null
}

guard_state_dir() {
  printf '%s/git-guard' "$(guard_git_dir)"
}

# receive-pack 不是一个可重入的单文件脚本：snapshot refs、远端 fetch 和
# receive hooks 都共享一个 bare repo。用 mkdir 的原子性做 POSIX/macOS/Linux
# 都可用的外层互斥，把一次 receive 的整个生命周期包起来。
guard_lock_acquire() {
  local state="$1" timeout="${2:-${GUARD_LOCK_TIMEOUT:-300}}"
  local lock="$state/receive.lock" started now owner
  mkdir -p "$state"
  started="$(date +%s)"
  while :; do
    if mkdir "$lock" 2>/dev/null; then
      printf '%s\n' "$$" > "$lock/pid"
      return 0
    fi
    owner="$(cat "$lock/pid" 2>/dev/null || true)"
    if [ -n "$owner" ] && ! kill -0 "$owner" 2>/dev/null; then
      rm -f "$lock/pid" 2>/dev/null || true
      rmdir "$lock" 2>/dev/null || true
      continue
    fi
    now="$(date +%s)"
    if [ "$timeout" -ge 0 ] && [ $((now - started)) -ge "$timeout" ]; then
      guard_err "receive 互斥等待超时（${lock}）"
      return 1
    fi
    sleep 0.05
  done
}

guard_lock_release() {
  local state="$1" lock
  lock="$state/receive.lock"
  rm -f "$lock/pid" 2>/dev/null || true
  rmdir "$lock" 2>/dev/null || true
}

guard_txn_root() {
  printf '%s/transactions' "$(guard_state_dir)"
}

guard_new_txn_id() {
  # 外层锁已保证同一 staging 同时只有一个生成者；秒级时间 + pid 足够可审计，
  # RANDOM 只用来避免测试中快速重入时复用目录名。
  printf '%s-%s-%s' "$$" "$(date +%s)" "${RANDOM:-0}"
}

guard_txn_file() {
  local tx="$1" name="$2"
  printf '%s/%s' "$tx" "$name"
}

guard_current_txn() {
  local tx="${GUARD_TXN_DIR:-}"
  [ -n "$tx" ] && [ -d "$tx" ] || return 1
  printf '%s' "$tx"
}

guard_rev() {
  local dir="$1" ref="$2" sha
  sha="$(git --git-dir="$dir" rev-parse -q --verify "${ref}^{commit}" 2>/dev/null || true)"
  printf '%s' "$sha"
}

# refs/heads/foo → refs/guard/github/heads/foo
guard_snapshot_ref() {
  local ref="$1"
  case "$ref" in
    refs/heads/*) printf '%s/heads/%s' "$GUARD_SNAP" "${ref#refs/heads/}" ;;
    *) return 1 ;;
  esac
}

guard_snapshot_tip() {
  local dir="$1" ref="$2" sref
  sref="$(guard_snapshot_ref "$ref")" || return 1
  guard_rev "$dir" "$sref"
}

guard_write_forward_status() {
  local status="$1" tx="${2:-${GUARD_TXN_DIR:-}}"
  [ -n "$tx" ] || return 1
  mkdir -p "$tx"
  printf '%s\n' "$status" > "$(guard_txn_file "$tx" forward-status)"
}

guard_write_txn_file() {
  local tx="$1" name="$2" value="$3" tmp
  tmp="$(guard_txn_file "$tx" ".${name}.tmp.$$")"
  printf '%s\n' "$value" > "$tmp"
  mv -f "$tmp" "$(guard_txn_file "$tx" "$name")"
}

# receive-pack 开始前调用。无 ref 参数时维护完整 snapshot namespace（旧的
# receive-pack 责任域）；有 ref 参数时只更新一个目标 snapshot ref，不 prune
# 或更新其它 branch mirror，供 R3 scoped recovery 使用。
guard_snapshot_github() {
  local dir="$1" target_ref="${2:-}" remote target_snapshot
  remote="$(git --git-dir="$dir" remote get-url "$GUARD_REMOTE" 2>/dev/null || true)"
  [ -n "$remote" ] || { guard_err "staging 没有 ${GUARD_REMOTE} remote，无法镜像 GitHub"; return 1; }
  if [ -n "$target_ref" ]; then
    target_snapshot="$(guard_snapshot_ref "$target_ref")" || {
      guard_err "不支持的 scoped snapshot ref：${target_ref}"; return 1;
    }
    if ! GIT_TERMINAL_PROMPT=0 git --git-dir="$dir" fetch --no-prune --no-tags \
        --no-write-fetch-head --quiet "$GUARD_REMOTE" \
        "${target_ref}:${target_snapshot}"; then
      guard_err "无法镜像目标 GitHub ref ${target_ref}，fail-closed"; return 1
    fi
    return 0
  fi
  if ! GIT_TERMINAL_PROMPT=0 git --git-dir="$dir" fetch --prune --no-tags --quiet \
      "$GUARD_REMOTE" "+refs/heads/*:${GUARD_SNAP}/heads/*"; then
    guard_err "无法镜像 GitHub refs，fail-closed（不用陈旧 staging 副本）"
    return 1
  fi
  return 0
}

# A3：GitHub snapshot main 必须与 staging 已存 main 一致，否则拒绝读陈旧 contract。
# Contract 的树以 snapshot 为准；main 分叉时拒绝整次 push。
guard_main_in_sync() {
  local dir="$1" main="${2:-main}"
  local staging_main github_main
  staging_main="$(guard_rev "$dir" "refs/heads/${main}")"
  github_main="$(guard_rev "$dir" "${GUARD_SNAP}/heads/${main}")"
  if [ -z "$github_main" ]; then
    guard_err "GitHub 没有 ${main}，fail-closed"
    return 1
  fi
  if [ -z "$staging_main" ] || [ "$staging_main" != "$github_main" ]; then
    guard_err "GitHub ${main} 已前进，staging 未同步，拒绝使用陈旧 contract"
    return 1
  fi
  return 0
}

# A6：snapshot tip 必须等于客户端 old。不得拿 staging refs/heads 当比较对象。
guard_cas_ok() {
  local dir="$1" old="$2" new="$3" ref="$4"
  local github_tip
  github_tip="$(guard_snapshot_tip "$dir" "$ref")"
  if guard_is_zero "$old"; then
    if [ -n "$github_tip" ]; then
      guard_err "GitHub ${ref} 已存在（${github_tip:0:12}），拒绝按新建推送"
      return 1
    fi
    return 0
  fi
  if guard_is_zero "$new"; then
    if [ -z "$github_tip" ]; then
      return 0
    fi
    if [ "$github_tip" != "$old" ]; then
      guard_err "GitHub ${ref} tip 已变（${github_tip:0:12}），拒绝基于陈旧 tip 删除"
      return 1
    fi
    return 0
  fi
  if [ "$github_tip" != "$old" ]; then
    guard_err "GitHub ${ref} tip 已变${github_tip:+（${github_tip:0:12}）}，拒绝基于陈旧 tip 更新"
    return 1
  fi
  return 0
}

guard_porcelain_atomic() {
  local line field seen=0
  while IFS= read -r line; do
    case "$line" in
      To\ *|Done|'') continue ;;
    esac
    field="${line%%	*}"
    case "$field" in
      '!') printf 'fail\n'; return 0 ;;
      ' '|'+'|'*'|'='|'-') seen=1 ;;
    esac
  done
  if [ "$seen" = 1 ]; then
    printf 'ok\n'
  else
    printf 'fail\n'
  fi
}

# 为一个 receive transaction 固化转发计划。删除一个在 snapshot 中本来就不
# 存在的 ref 是幂等成功，因此不加入计划；其余每一条都保留客户端 old-oid。
guard_write_forward_plan() {
  local dir="$1" tx="$2" tmp line old new ref github_tip rest
  tmp="$(guard_txn_file "$tx" .forward-plan.tmp.$$)"
  : > "$tmp"
  for line in "${@:3}"; do
    old="${line%% *}"
    rest="${line#* }"
    new="${rest%% *}"
    ref="${rest#* }"
    [ -n "$old" ] && [ -n "$new" ] && [ -n "$ref" ] || continue
    if guard_is_zero "$new"; then
      github_tip="$(guard_snapshot_tip "$dir" "$ref")"
      [ -n "$github_tip" ] || continue
    fi
    printf '%s\t%s\t%s\n' "$old" "$new" "$ref" >> "$tmp"
  done
  mv -f "$tmp" "$(guard_txn_file "$tx" forward-plan)"
}

guard_forward_reason() {
  local out="$1" ref="$2" rc="$3" line reason
  # 只保存 porcelain 的 ref 结果，不把 remote URL 或 remote hook 输出落盘。
  line="$(printf '%s\n' "$out" | awk -v ref="$ref" \
    '$1 == "!" && index($0, ref) > 0 { print; exit }' || true)"
  if [ -n "$line" ]; then
    reason="${line#*! }"
    reason="${reason//$'\t'/ }"
    reason="${reason//$'\r'/ }"
    reason="${reason//$'\n'/ }"
    printf '%s' "$reason"
  else
    printf 'atomic push failed (rc=%s)' "$rc"
  fi
}

# 执行已固化的计划。每一条 spec 都带显式 lease，包括新建 ref 的
# --force-with-lease=<ref>:；因此 status/sync 重试时不会退化成无 lease。
guard_forward_plan() {
  local dir="$1" tx="$2" plan old new ref out rc=0 verdict reason tmp
  local -a leases=() specs=() refs=()
  plan="$(guard_txn_file "$tx" forward-plan)"
  [ -f "$plan" ] || { guard_err "缺少转发计划（txn=$(basename "$tx")）"; return 1; }

  while IFS=$'\t' read -r old new ref; do
    [ -n "${ref:-}" ] || continue
    leases+=("--force-with-lease=${ref}:${old}")
    if guard_is_zero "$new"; then
      specs+=(":${ref}")
    else
      specs+=("${new}:${ref}")
    fi
    refs+=("$ref")
  done < "$plan"

  if [ "${#specs[@]}" -eq 0 ]; then
    guard_write_forward_status ok "$tx"
    rm -f "$(guard_txn_file "$tx" forward-failure)"
    return 0
  fi

  out="$(GIT_TERMINAL_PROMPT=0 git --git-dir="$dir" push --atomic --porcelain \
    "${leases[@]}" "$GUARD_REMOTE" "${specs[@]}" 2>&1)" || rc=$?
  verdict="$(printf '%s\n' "$out" | guard_porcelain_atomic)"
  if [ "$verdict" = ok ] && [ "$rc" -eq 0 ]; then
    guard_write_forward_status ok "$tx"
    guard_write_txn_file "$tx" forward-recovered "$(date +%s)"
    rm -f "$(guard_txn_file "$tx" forward-failure)"
    return 0
  fi

  guard_write_forward_status fail "$tx"
  tmp="$(guard_txn_file "$tx" .forward-failure.tmp.$$)"
  : > "$tmp"
  while IFS=$'\t' read -r old new ref; do
    [ -n "${ref:-}" ] || continue
    reason="$(guard_forward_reason "$out" "$ref" "$rc")"
    printf '%s\t%s\t%s\t%s\n' "$ref" "$old" "$new" "$reason" >> "$tmp"
  done < "$plan"
  mv -f "$tmp" "$(guard_txn_file "$tx" forward-failure)"
  guard_err "转发 GitHub 失败（txn=$(basename "$tx") porcelain=${verdict} rc=${rc}），保留原 lease 待 sync 重试"
  printf '%s\n' "$out" >&2
  return 1
}

# 初次 post-receive 固化计划后执行；retry 只调用 guard_forward_plan。
guard_forward_atomic() {
  local dir="$1" tx="$2"
  shift 2
  guard_write_forward_plan "$dir" "$tx" "$@"
  guard_forward_plan "$dir" "$tx"
}

guard_report_forward_failures() {
  local state="$1" root tx status ref old new reason count=0
  root="$state/transactions"
  [ -d "$root" ] || { printf '    forwarding failure：无\n'; return 0; }
  for tx in "$root"/*; do
    [ -d "$tx" ] || continue
    status="$(cat "$(guard_txn_file "$tx" forward-status)" 2>/dev/null || true)"
    [ "$status" = fail ] || continue
    while IFS=$'\t' read -r ref old new reason; do
      [ -n "${ref:-}" ] || continue
      count=$((count + 1))
      printf '    ✗ txn=%s ref=%s old=%s new=%s reason=%s\n' \
        "$(basename "$tx")" "$ref" "$old" "$new" "$reason"
    done < "$(guard_txn_file "$tx" forward-failure)"
  done
  if [ "$count" -eq 0 ]; then
    printf '    forwarding failure：无\n'
  else
    printf '    共 %s 条 forwarding failure；重试：new guard sync\n' "$count"
  fi
  return 0
}

# 只有在本次 receive 没有触发 post-receive、历史 transaction 都已明确收敛，
# 且 staging 的全部 heads 与本次 GitHub snapshot 一致时，才把缺少 status
# 解释为安全 no-op。否则缺失/未知状态一律不能让 wrapper 返回成功。
guard_heads_in_sync() {
  local dir="$1"
  if diff -u \
      <(git --git-dir="$dir" for-each-ref \
          --format='%(refname) %(objectname)' refs/heads |
        sed 's#^refs/heads/#refs/guard/github/heads/#' | LC_ALL=C sort) \
      <(git --git-dir="$dir" for-each-ref \
          --format='%(refname) %(objectname)' "${GUARD_SNAP}/heads" |
        LC_ALL=C sort) >/dev/null 2>&1; then
    return 0
  fi
  return 1
}

guard_transactions_resolved() {
  local dir="$1" state="$2" current="$3" root tx status
  root="$state/transactions"
  [ -d "$root" ] || return 0
  for tx in "$root"/*; do
    [ -d "$tx" ] || continue
    [ "$tx" = "$current" ] && continue
    status="$(cat "$(guard_txn_file "$tx" forward-status)" 2>/dev/null || true)"
    case "$status" in
      ok|noop) ;;
      '')
        # A no-op receive may have no post-receive status at all. It is only
        # recoverable after the whole staging namespace is back in sync; an
        # incoming file would prove that a hook ran and must stay blocked.
        [ ! -e "$(guard_txn_file "$tx" incoming)" ] || return 1
        guard_heads_in_sync "$dir" || return 1
        ;;
      *) return 1 ;;
    esac
  done
  return 0
}

guard_safe_noop() {
  local dir="$1" state="$2" tx="$3"
  # post-receive writes incoming before it attempts forwarding. Its absence is
  # the only local evidence that receive-pack did not update any ref.
  [ ! -e "$(guard_txn_file "$tx" incoming)" ] || return 1
  guard_transactions_resolved "$dir" "$state" "$tx" || return 1
  guard_heads_in_sync "$dir" || return 1
  return 0
}

# 只验证。不向 GitHub 写。snapshot 必须已由 wrapper 刷新。
guard_pre_receive() {
  local dir main old new ref st snapshot tx
  local -a lines=()
  dir="$(guard_git_dir)"
  [ -n "$dir" ] || { guard_err "无法解析 staging git dir"; return 1; }
  st="$(guard_state_dir)"
  tx="$(guard_current_txn 2>/dev/null || true)"
  if [ -z "$tx" ] || [ ! -f "$(guard_txn_file "$tx" snapshot-nonce)" ]; then
    guard_err "缺少本次 receive 的 GitHub snapshot（必须经 guard receive-pack），fail-closed"
    return 1
  fi
  main="$(git --git-dir="$dir" config --get git-guard.main 2>/dev/null || true)"
  main="${main:-main}"

  while read -r old new ref; do
    [ -n "${ref:-}" ] || continue
    lines+=("${old} ${new} ${ref}")
  done

  if ! guard_main_in_sync "$dir" "$main"; then
    return 1
  fi
  snapshot="$(cat "$(guard_txn_file "$tx" snapshot-main)" 2>/dev/null || true)"
  [ -n "$snapshot" ] || {
    guard_err "本次 receive 缺少 snapshot main，fail-closed"
    return 1
  }

  for line in "${lines[@]+"${lines[@]}"}"; do
    old="${line%% *}"
    rest="${line#* }"
    new="${rest%% *}"
    ref="${rest#* }"
    case "$ref" in
      "refs/heads/${main}")
        guard_err "拒绝更新 ${ref}（task worktree 不得 push main）"
        return 1
        ;;
      refs/heads/*) ;;
      *)
        guard_err "拒绝非 heads 引用 ${ref}"
        return 1
        ;;
    esac
    if ! guard_cas_ok "$dir" "$old" "$new" "$ref"; then
      return 1
    fi
    if ! guard_is_zero "$new"; then
      bash "$dir/hooks/guard-validate.sh" "$dir" "$snapshot" "$new" \
        "${ref#refs/heads/}" "${GUARD_TASK_ISSUE:-}" || return 1
    fi
  done
  return 0
}

# staging refs 已更新之后：带 lease 原子转发 GitHub。失败只记状态，由 wrapper 变成客户端非 0。
guard_post_receive() {
  local dir old new ref tx
  local -a lines=()
  dir="$(guard_git_dir)"
  tx="$(guard_current_txn 2>/dev/null || true)"
  [ -n "$dir" ] && [ -n "$tx" ] || {
    guard_err "无法解析本次 receive transaction"; return 1;
  }

  while read -r old new ref; do
    [ -n "${ref:-}" ] || continue
    lines+=("${old} ${new} ${ref}")
  done

  {
    for line in "${lines[@]+${lines[@]}}"; do
      printf '%s\n' "$line"
    done
  } > "$(guard_txn_file "$tx" incoming)"

  if [ ${#lines[@]} -eq 0 ]; then
    guard_write_forward_status ok "$tx"
    return 0
  fi

  if guard_forward_atomic "$dir" "$tx" "${lines[@]}"; then
    return 0
  fi
  guard_write_forward_status fail "$tx"
  return 0
}

# 客户端 remote.origin.receivepack 指向本函数对应脚本。
guard_receive_pack() {
  local staging rc=0 fwd st client_git_dir tx txid
  # local transport 此时仍在发起 push 的 worktree；进 receive-pack 后 cwd 才是 bare。
  # 每次重读显式 Binding，不使用目录/分支猜号，也不信调用方预设的同名环境变量。
  client_git_dir="$(git rev-parse --absolute-git-dir 2>/dev/null)" || {
    guard_err '无法读取发起 push 的 Task Binding'; return 1;
  }
  GUARD_TASK_ISSUE="$(cat "$client_git_dir/new.task.issue" 2>/dev/null || true)"
  [[ "$GUARD_TASK_ISSUE" =~ ^[1-9][0-9]*$ ]] || {
    guard_err '缺少显式 Task Binding，先 new task bind <n>'; return 1;
  }
  export GUARD_TASK_ISSUE
  staging="${!#}"
  case "$staging" in
    ''|-*) guard_err "receive-pack 缺少 git-dir"; return 1 ;;
  esac
  [ -d "$staging" ] || { guard_err "receive-pack 目录不存在：$staging"; return 1; }
  staging="$(cd "$staging" && pwd)"
  st="$staging/git-guard"
  mkdir -p "$st/transactions"
  guard_lock_acquire "$st" || return 1
  # wrapper 是一次独立进程，EXIT trap 覆盖 snapshot / receive / hook 任一路径。
  GUARD_LOCK_STATE="$st"
  trap 'guard_lock_release "$GUARD_LOCK_STATE"' EXIT
  txid="$(guard_new_txn_id)"
  tx="$st/transactions/$txid"
  mkdir -p "$tx"
  export GUARD_TXN_ID="$txid" GUARD_TXN_DIR="$tx"
  guard_write_txn_file "$tx" receive-status pending

  if ! guard_snapshot_github "$staging"; then
    guard_write_txn_file "$tx" receive-status mirror-failed
    return 1
  fi
  printf '%s\n' "$$-$txid" > "$(guard_txn_file "$tx" snapshot-nonce)"
  guard_snapshot_tip "$staging" "refs/heads/$(git --git-dir="$staging" config --get git-guard.main 2>/dev/null || printf main)" \
    > "$(guard_txn_file "$tx" snapshot-main)"

  set +e
  git receive-pack "$@"
  rc=$?
  set -e

  if [ "$rc" -ne 0 ]; then
    guard_write_txn_file "$tx" receive-status rejected
    return "$rc"
  fi
  guard_write_txn_file "$tx" receive-status accepted
  fwd="$(cat "$(guard_txn_file "$tx" forward-status)" 2>/dev/null || echo none)"
  case "$fwd" in
    ok)
      return 0
      ;;
    none|"")
      if guard_safe_noop "$staging" "$st" "$tx"; then
        guard_write_forward_status noop "$tx"
        guard_write_txn_file "$tx" receive-status noop
        return 0
      fi
      guard_err "GitHub forwarding status 缺失或无法证明是安全 no-op，客户端非 0"
      return 1
      ;;
    fail)
      guard_err "GitHub 转发失败，客户端非 0（staging 可能已更新）"
      return 1
      ;;
    *)
      guard_err "GitHub forwarding status 未知（${fwd}），客户端非 0"
      return 1
      ;;
  esac
}
